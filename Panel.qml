import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

/*
 * Odisplay: pick a monitor input from the bar.
 *
 * The panel never talks to the monitor itself. It runs ddcutil as an argv array
 * and reads one bounded chunk of output per call.
 *
 * ddcutil output is untrusted input. A Text without textFormat sits on
 * Text.AutoText, which renders a string that looks like markup as rich text, and
 * rich text can load an image from a URL the string chooses.
 */
Panel {
    id: root

    moduleName: "h1st0ry3d.odisplay"
    ipcTarget: "h1st0ry3d.odisplay"
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    // Absolute so a PATH this panel does not control cannot supply a different
    // binary. The VCP code is fixed: 0x60 is Input Source.
    readonly property string ddcutil: "/usr/bin/ddcutil"
    readonly property var commandEnvironment: ({ "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C" })

    // An oversized reply is cut off rather than collected whole. ddcutil prints a
    // few lines or nothing, so this is a backstop, not a budget to fill.
    readonly property int outputLimit: 4096
    readonly property int watchdogMs: 8000

    /*
     * The three inputs, as a closed list of constants.
     *
     * These are the VCP 0x60 values for a Dell S2725DC. They are typed here rather
     * than read from anywhere, so nothing needs validating on the way to the
     * command. Other monitors number these differently: run `ddcutil capabilities`
     * and read the values under "Feature: 60".
     */
    readonly property var inputs: [
        { key: "usbc", label: "USB-C",       value: "0x1b" },
        { key: "dp",   label: "DisplayPort", value: "0x0f" },
        { key: "hdmi", label: "HDMI",        value: "0x11" }
    ]

    // -- custom names
    /*
     * Names the user gave the inputs, keyed by the same key as `inputs`.
     *
     * Display only. The VCP value a row sends still comes from the closed list
     * above and there is no way to edit it here, so a name cannot change what
     * the command does.
     *
     * Held in ~/.local/state/odisplay/names.json, so a name outlives the shell
     * and stays until it is renamed again.
     */
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
    readonly property string stateDir: root.stateHome + "/odisplay"
    readonly property string namesPath: root.stateDir + "/names.json"
    readonly property int maxNameLength: 32

    property var names: ({})

    // The key of the row that is currently a text field, or "" for none. One
    // at a time, so there is only ever one field to focus.
    property string renamingKey: ""
    readonly property bool renaming: root.renamingKey !== ""

    // A save asked for before the state directory existed. The write goes out
    // once mkdir has, rather than being lost.
    property bool namesPending: false

    // ddcutil's display numbers come from `ddcutil detect` and are not stable
    // across reboots, so the index is editable rather than hard-coded.
    property int displayIndex: 1
    property string displayIndexText: "1"

    // Outcome of the last switch, shown in the hero line. Session only: the
    // monitor's own OSD is the source of truth for what it is showing, so nothing
    // here is stored and later re-read as if it were.
    property string statusText: "Set input source"
    property bool statusIsError: false
    property string lastSelected: ""

    // The input the in-flight switch is for, so the result is reported against the
    // right label.
    property var pendingEntry: null

    // Only a switch disables the buttons, so the panel stays responsive.
    readonly property bool busy: switchProcess.running

    // -- untrusted input
    /*
     * Strip what a rich-text renderer could act on, then cap the length, for the
     * components the shell renders itself and where textFormat cannot be set.
     */
    function plain(value, limit) {
        var source = String(value === undefined || value === null ? "" : value)
        var cleaned = ""
        for (var index = 0; index < source.length && cleaned.length < limit; index++) {
            var character = source[index]
            var code = source.charCodeAt(index)
            var printable = code >= 0x20 && code !== 0x7f && code < 0xa0
            var notSurrogate = !(code >= 0xd800 && code <= 0xdfff)
            if (printable && notSurrogate && character !== "<" && character !== ">" && character !== "&")
                cleaned += character
        }
        return cleaned
    }

    /*
     * The display number only ever becomes a decimal integer, which is what the
     * argv array then carries. Anything else is refused rather than repaired, so a
     * value that is not a number can never become an argument.
     */
    function validDisplayIndex(value) {
        var text = String(value).trim()
        if (!/^[0-9]{1,3}$/.test(text)) return false
        var number = Number(text)
        return isFinite(number) && number >= 1 && number <= 999
    }

    function commitDisplayIndex(text) {
        root.displayIndexText = text
        if (!root.validDisplayIndex(text)) {
            root.statusIsError = true
            root.statusText = "Display must be a number, 1 to 999"
            return
        }
        root.displayIndex = Number(text)
    }

    // -- custom names
    /*
     * A name is typed by the user but read back off disk, where it could have
     * been edited by anything, so it goes through this rather than straight to
     * a label. Control characters go because a name occupies one line of one
     * button; the length cap is because the file could hold anything at all.
     *
     * Unlike `plain`, this keeps `<`, `>` and `&`: the button renders its own
     * text as Text.PlainText, and the only shell-rendered label a name reaches
     * is the hero line, which is already run through `plain` on the way out.
     */
    function cleanName(value) {
        var source = String(value === undefined || value === null ? "" : value)
        var cleaned = ""
        for (var index = 0; index < source.length && cleaned.length < root.maxNameLength; index++) {
            var code = source.charCodeAt(index)
            var control = code < 0x20 || code === 0x7f
            var surrogate = code >= 0xd800 && code <= 0xdfff
            if (!control && !surrogate) cleaned += source[index]
        }
        return cleaned.trim()
    }

    // The name to show for an input: the user's if there is one, the built-in
    // label otherwise.
    function labelFor(key) {
        var custom = root.names[key]
        if (typeof custom === "string" && custom !== "") return custom
        for (var index = 0; index < root.inputs.length; index++) {
            if (root.inputs[index].key === key) return root.inputs[index].label
        }
        return ""
    }

    /*
     * Only the three keys this panel knows about are kept, and only a name
     * that survives `cleanName`. A stale file naming an input that no longer
     * exists, or carrying a value of the wrong type, is dropped rather than
     * refused: the file is a convenience, and the built-in labels are a
     * working panel without it.
     */
    function applyNames(raw) {
        var parsed = null
        try { parsed = JSON.parse(String(raw).trim() || "{}") } catch (e) { parsed = null }
        var kept = ({})
        if (Util.isPlainObject(parsed) && Util.isPlainObject(parsed.names)) {
            for (var index = 0; index < root.inputs.length; index++) {
                var key = root.inputs[index].key
                var value = parsed.names[key]
                if (typeof value !== "string") continue
                var name = root.cleanName(value)
                if (name !== "") kept[key] = name
            }
        }
        root.names = kept
    }

    function saveNames() {
        // `names` only ever holds known keys with a non-empty cleaned name —
        // applyNames and commitName between them guarantee it — so this is the
        // whole file and needs no second pass over `inputs`.
        if (ensureStateDir.running) {
            // First run: the folder is not there yet. The write goes out once
            // mkdir has made it rather than failing into a name that is not
            // there next time.
            root.namesPending = true
            return
        }
        namesFile.setText(JSON.stringify({ version: 1, names: root.names }, null, 2) + "\n")
    }

    // Right-click on a row. One field is open at a time, so right-clicking a
    // second row moves the field and abandons whatever was typed in the first.
    function renameInput(key) {
        if (root.busy) return
        root.renamingKey = key
    }

    // Enter commits (also on focus loss, which is what editingFinished reports),
    // and Escape puts the row back. Both end the rename, and both are reachable
    // twice for one keystroke: Enter fires accepted and editingFinished, and
    // hiding the field fires editingFinished again. The guard on renamingKey is
    // what makes the second one a no-op, so a cancelled rename cannot land.
    function commitName(key, text) {
        if (root.renamingKey !== key) return
        var name = root.cleanName(text)
        // A copy, because binding invalidation needs a new object: mutating
        // `names` in place would leave the buttons showing the old name.
        var next = Object.assign({}, root.names)
        // An empty name is a rename back to the built-in label, so the entry is
        // removed rather than stored as an empty string.
        if (name === "") delete next[key]
        else next[key] = name
        root.names = next
        root.endRename()
        root.saveNames()
    }

    function cancelRename() {
        if (root.renaming) root.endRename()
    }

    function endRename() {
        root.renamingKey = ""
        // Deferred, because the field that had the focus is on its way out and
        // cannot hold it. The caller's next key press goes to the catcher.
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }

    /*
     * Closing must not leave a field open on a hidden window. Watching the open
     * state covers every way out — outside click, Escape, the bar button, IPC —
     * without this panel having to shadow the base class's close().
     */
    onOpenedChanged: if (!root.opened) root.cancelRename()

    // -- input switching
    function setInput(entry) {
        if (root.busy || !entry) return

        if (!root.validDisplayIndex(root.displayIndexText)) {
            root.statusIsError = true
            root.statusText = "Fix the display number first"
            return
        }

        root.send(entry)
    }

    function send(entry) {
        if (root.busy || !entry) return
        root.pendingEntry = entry
        root.lastSelected = entry.key
        root.statusIsError = false
        // The name the user gave this input, not the built-in one.
        root.statusText = "Switching to " + root.labelFor(entry.key) + " ..."
        switchProcess.buffer = ""
        switchProcess.failure = ""
        // Every element is its own argument. No shell, so nothing is parsed twice.
        switchProcess.command = [
            root.ddcutil, "setvcp", "60", entry.value, "--display", String(root.displayIndex)
        ]
        switchProcess.running = true
        switchWatchdog.restart()
    }

    /*
     * An empty split marker hands over raw chunks, so an oversized reply can be cut
     * off. A line-buffered parser has to hold the whole line first.
     */
    Process {
        id: switchProcess
        running: false
        property string buffer: ""
        property string failure: ""

        stdout: SplitParser {
            splitMarker: ""
            onRead: function(chunk) { switchProcess.collect(chunk) }
        }
        stderr: SplitParser {
            splitMarker: ""
            onRead: function(chunk) {
                if (switchProcess.failure.length <= root.outputLimit)
                    switchProcess.failure += chunk
            }
        }
        environment: root.commandEnvironment
        clearEnvironment: true

        function collect(chunk) {
            buffer += chunk
            if (buffer.length > root.outputLimit) {
                buffer = ""
                signal(15)
                overflowTimer.start()
            }
        }

        onExited: function(code) {
            // Reported against the entry this call was actually for, not against
            // whatever the panel most recently selected.
            var label = root.pendingEntry ? root.labelFor(root.pendingEntry.key) : "the input"
            var text = root.plain((failure !== "" ? failure : buffer).trim(), 200)
            if (code === 0) {
                root.statusIsError = false
                root.statusText = "Sent " + label
            } else {
                root.statusIsError = true
                root.statusText = text !== "" ? text : "ddcutil exited with " + code
            }
            buffer = ""
            failure = ""
            root.pendingEntry = null
        }
    }

    /*
     * ddcutil answers a setvcp in well under a second. This is the backstop for a
     * call that does not come back at all, which an I2C bus can do when the adapter
     * is taken away underneath it.
     */
    Timer {
        id: switchWatchdog
        interval: root.watchdogMs
        onTriggered: if (switchProcess.running) switchProcess.signal(15)
    }

    Timer {
        id: overflowTimer
        interval: 2000
        onTriggered: switchProcess.signal(9)
    }

    // Nothing started here may outlive the panel.
    Component.onDestruction: if (switchProcess.running) switchProcess.signal(15)

    // -- name storage
    /*
     * ~/.local/state/odisplay/names.json.
     *
     * atomicWrites, so a shell killed mid-rename cannot leave a half-written
     * file that parses as no names at all.
     *
     * watchChanges, so a name edited or deleted by hand shows up without a
     * restart. That also fires on this panel's own write, which is harmless:
     * it reads back the same names that were just committed.
     */
    FileView {
        id: namesFile
        path: root.namesPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: root.applyNames(text())
        // First run: the folder does not exist yet, so there is nothing to read.
        onLoadFailed: root.applyNames("")
    }

    /*
     * mkdir for the folder above, as an argv array with a fixed PATH. -p so it
     * is a no-op once the folder is there, which is every run after the first.
     */
    Process {
        id: ensureStateDir
        command: ["/usr/bin/mkdir", "-p", root.stateDir]
        environment: root.commandEnvironment
        clearEnvironment: true
        onExited: function(code) {
            if (code !== 0) return
            // Only the deferred write needs the folder. The initial read cannot:
            // a names.json that exists means the folder already did.
            if (root.namesPending) {
                root.namesPending = false
                root.saveNames()
            }
        }
    }

    Component.onCompleted: ensureStateDir.running = true

    // -- bar button
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        // U+F26C is fa-tv in the bar font (JetBrainsMono Nerd Font). Written as an
        // escape: the glyph is in the private use area and does not survive being
        // pasted into a source file as a literal character.
        text: "\uf26c"
        onPressed: root.toggle()
    }

    // -- panel
    KeyboardPanel {
        id: dropdown
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: dropdown.fittedContentWidth(Style.space(340))
        contentHeight: dropdown.fittedContentHeight(col.implicitHeight, Style.space(320))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            // A rename owns the keyboard while it is open: the catcher's Return,
            // Escape and letter keys would otherwise fire instead of the field's.
            blocked: root.renaming
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction) }

            Flickable {
                anchors.fill: parent
                contentWidth: width
                contentHeight: col.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: col
                    width: parent.width
                    spacing: Style.space(10)
                    topPadding: Style.space(12)
                    bottomPadding: Style.space(12)

                    PanelHero {
                        id: hero
                        width: parent.width
                        title: "Odisplay"
                        // Rendered by the shell itself, so strip and cap first.
                        meta: root.plain(root.statusText, 80)
                        foreground: Color.foreground
                        fontFamily: Style.font.family
                        iconComponent: Component {
                            Text {
                                text: button.text
                                textFormat: Text.PlainText
                                color: root.statusIsError ? "#f44" : hero.foreground
                                font.family: hero.fontFamily
                                font.pixelSize: Style.font.displayLarge
                            }
                        }
                    }

                    // The hero has no room for a colour cue, so an error is repeated
                    // here in text that can actually be read.
                    Text {
                        width: parent.width
                        visible: root.statusIsError
                        text: root.plain(root.statusText, 120)
                        textFormat: Text.PlainText
                        color: "#f44"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }

                    PanelSeparator { foreground: Color.foreground }

                    /*
                     * One row per input: a button, which is a text field while it is
                     * being renamed.
                     *
                     * qs.Ui.Button renders its own `text` with Text.PlainText, so the
                     * label is a plain string here rather than a contentItem. Only the
                     * name is shown; the VCP value each one sends is in the source.
                     *
                     * Right-click renames. The field replaces the button rather than
                     * opening next to it, so the row does not change height and the
                     * panel does not move under the pointer.
                     */
                    Repeater {
                        model: root.inputs

                        Item {
                            id: inputRow
                            required property var modelData

                            // Named apart from root.renaming, which means "a rename is open
                            // somewhere", not "this row is the one".
                            readonly property bool isRenaming: root.renamingKey === modelData.key

                            width: parent.width
                            height: 34

                            Button {
                                anchors.fill: parent
                                visible: !inputRow.isRenaming
                                enabled: !root.busy
                                text: root.labelFor(modelData.key)
                                // Marks the input sent last. There is no confirmation
                                // step, so this is the only feedback the panel gives.
                                selected: root.lastSelected === modelData.key

                                onClicked: root.setInput(modelData)
                                onRightClicked: root.renameInput(modelData.key)
                            }

                            TextField {
                                anchors.fill: parent
                                visible: inputRow.isRenaming
                                enabled: inputRow.isRenaming
                                // Bound to nothing: the text is whatever the user
                                // typed, and a binding to `names` would overwrite it
                                // on the first keystroke. It is set when the field
                                // opens and read on the way out.
                                maximumLength: root.maxNameLength
                                font.family: Style.font.family
                                placeholderText: modelData.label

                                onVisibleChanged: {
                                    if (!visible) return
                                    text = root.labelFor(modelData.key)
                                    forceActiveFocus()
                                    selectAll()
                                }

                                // Enter, and focus loss, both commit; Escape puts the
                                // row back untouched. The catcher is blocked while a
                                // rename is open, so these keys reach the field.
                                onAccepted: root.commitName(modelData.key, text)
                                onEditingFinished: root.commitName(modelData.key, text)
                                Keys.onEscapePressed: {
                                    root.cancelRename()
                                    event.accepted = true
                                }
                            }
                        }
                    }

                    /*
                     * Only shown while a rename is open, so the panel says how to get
                     * out of the field rather than leaving it to be guessed.
                     */
                    Text {
                        width: parent.width
                        visible: root.renaming
                        text: "Enter to save, Escape to cancel. Empty restores the default name."
                        textFormat: Text.PlainText
                        color: Util.alpha(Color.foreground, 0.7)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                    PanelSeparator { foreground: Color.foreground }

                    // The display number is ddcutil's index from `ddcutil detect`, not
                    // the connector name Hyprland uses. It is the one thing here that
                    // can need changing after a reboot.
                    Row {
                        width: parent.width
                        spacing: Style.space(8)

                        Text {
                            width: parent.width - displayField.width - Style.space(8)
                            height: 30
                            verticalAlignment: Text.AlignVCenter
                            text: "ddcutil display"
                            textFormat: Text.PlainText
                            color: Util.alpha(Color.foreground, 0.7)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                        }

                        TextField {
                            id: displayField
                            width: Style.space(70)
                            height: 30
                            text: root.displayIndexText
                            // at most three digits, which is what the validator allows
                            maximumLength: 3
                            font.family: Style.font.family
                            validator: IntValidator { bottom: 1; top: 999 }
                            onEditingFinished: root.commitDisplayIndex(text)
                            onAccepted: root.commitDisplayIndex(text)
                        }
                    }
                }
            }
        }
    }
}