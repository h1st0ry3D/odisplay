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

    /*
     * ddcutil keeps a cache of display timings, and with no HOME in this
     * deliberately bare environment it prints two "Unable to determine dynamic
     * sleep cache file name" lines after every failure that say nothing about the
     * failure. Pointing it at a folder under the state directory silences them,
     * so a failed switch reports the one thing that went wrong. ddcutil creates
     * the folder itself on first use.
     */
    readonly property string ddcutilCacheHome: root.stateDir + "/cache"
    readonly property var commandEnvironment: ({
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "XDG_CACHE_HOME": root.ddcutilCacheHome
    })

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
     * Held in ~/.local/state/odisplay/names.json, alongside the picked ddcutil
     * display number, so both outlive the shell: a name stays until it is
     * renamed again, a display stays until another one is picked.
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

    // A save asked for before the state directory existed, or before the file had
    // been read once. The write goes out once mkdir has and the read has landed,
    // rather than being lost or landing over state this panel has not seen yet.
    property bool statePending: false

    // The state file has been read, or found to be missing, at least once.
    property bool stateReady: false

    /*
     * ddcutil's display numbers come from `ddcutil detect` and are not stable
     * across reboots, so the index is picked rather than typed: right-clicking
     * the bar icon offers the numbers ddcutil actually prints, and nothing
     * outside this list can reach a command.
     */
    readonly property var displayChoices: [1, 2, 3, 4]

    // The ddcutil display every switch is sent to. Always one of displayChoices:
    // a stored value outside the list is ignored, so this keeps whatever it
    // already held (the default on first load).
    property int displayIndex: 1

    // A number was picked from the menu since this panel loaded. A read of the
    // file that lands after that carries the older value and must not undo the
    // pick, which is what would otherwise happen in the moment between the panel
    // opening and its state file being read.
    property bool displayPicked: false

    // Outcome of the last switch, shown in the hero line. Session only: the
    // monitor's own OSD is the source of truth for what it is showing, so nothing
    // here is stored and later re-read as if it were.
    property string statusText: "Set input source"
    property bool statusIsError: false
    // What ddcutil actually said about a failed switch, under the sentence the
    // hero line carries. Empty while nothing has failed.
    property string statusDetail: ""
    property string lastSelected: ""

    /*
     * ddcutil's most common failure on this panel is a display number that has
     * moved since the last reboot. That one gets the way out spelled out, because
     * "Display not found" on its own says nothing about what to do.
     */
    readonly property bool displayMissing: root.statusIsError
        && /\bdisplay\b/i.test(root.statusDetail)
        && /\bnot found\b|\bno such\b|\bunknown display\b|\bfailed to find\b/i.test(root.statusDetail)

    // The input the in-flight switch is for, so the result is reported against the
    // right label.
    property var pendingEntry: null

    // Only a switch disables the buttons, so the panel stays responsive.
    readonly property bool busy: switchProcess.running

    // -- untrusted input
    /*
     * Strip what a rich-text renderer could act on, then cap the length, for the
     * components the shell renders itself and where textFormat cannot be set.
     *
     * A line break becomes a space rather than being dropped: dropping it glues
     * the last word of one line to the first of the next into a word nobody
     * wrote, and keeping it would break the single-line hero. Runs of
     * whitespace collapse, so ddcutil's wrapped output reads as sentences.
     */
    function plain(value, limit) {
        var source = String(value === undefined || value === null ? "" : value)
        var cleaned = ""
        for (var index = 0; index < source.length && cleaned.length < limit; index++) {
            var character = source[index]
            var code = source.charCodeAt(index)
            var notSurrogate = !(code >= 0xd800 && code <= 0xdfff)
            var printable = code >= 0x20 && code !== 0x7f && code < 0xa0
            if (notSurrogate && (character === " " || character === "\n" || character === "\r" || character === "\t")) {
                if (cleaned === "" || /\s$/.test(cleaned)) continue
                cleaned += " "
            } else if (printable && notSurrogate && character !== "<" && character !== ">" && character !== "&") {
                cleaned += character
            }
        }
        return cleaned.trim()
    }

    /*
     * ddcutil's own words as one sentence. Its first line says what failed and
     * the rest says why, so the first is followed by a colon instead of running
     * straight into the next one. Each line is stripped and capped on its own,
     * and output already ending in punctuation is left alone.
     */
    function sentence(value) {
        var lines = String(value === undefined || value === null ? "" : value).split(/\r?\n/)
        var parts = []
        for (var index = 0; index < lines.length; index++) {
            var line = root.plain(lines[index], 200)
            if (line !== "") parts.push(line)
        }
        if (parts.length === 0) return ""
        var head = parts[0]
        var tail = parts.slice(1).join(" ")
        var text = tail === "" ? head : head + (/[.!?]$/.test(head) ? " " : ": ") + tail
        return /[.!?]$/.test(text) ? text : text + "."
    }

    /*
     * The pickable displays, as a closed list. A value outside it is refused
     * rather than repaired, so the number that reaches the command is always one
     * of the four the menu offers and the tick always marks the number in use. A
     * stored value outside the list is ignored, leaving the default.
     */
    function listedDisplay(value) {
        return typeof value === "number" && root.displayChoices.indexOf(value) !== -1
    }

    /*
     * One entry picked from the display menu. The choice is stored so the tick
     * comes back after a shell restart, and the menu folds away either way — a
     * value that is not on the list leaves the stored number alone, so the menu
     * stays open on it.
     */
    function chooseDisplay(value) {
        if (!root.listedDisplay(value)) return
        if (value !== root.displayIndex) {
            root.displayIndex = value
            root.displayPicked = true
            // A failed switch is the panel's way of pointing at this menu, so
            // picking from it takes that hint away rather than leaving it next to
            // the number the user just changed.
            root.statusIsError = false
            root.statusDetail = ""
            root.statusText = "Using display " + value
            root.saveState()
        }
        displayMenu.close()
    }

    // Right-click on the bar icon. The panel does not need closing here: the
    // bar's popout coordinator hands ownership to whichever popup opened last.
    function toggleDisplayMenu() {
        displayMenu.open = !displayMenu.open
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
     *
     * The stored display number is read the same way: used when it is one of the
     * numbers on the list, ignored otherwise.
     */
    function applyState(raw) {
        var parsed = null
        try { parsed = JSON.parse(String(raw).trim() || "{}") } catch (e) { parsed = null }
        var kept = ({})
        if (Util.isPlainObject(parsed)) {
            if (Util.isPlainObject(parsed.names)) {
                for (var index = 0; index < root.inputs.length; index++) {
                    var key = root.inputs[index].key
                    var value = parsed.names[key]
                    if (typeof value !== "string") continue
                    var name = root.cleanName(value)
                    if (name !== "") kept[key] = name
                }
            }
            // Straight assignment, not chooseDisplay: reading the file must not
            // write it straight back out.
            if (!root.displayPicked && root.listedDisplay(parsed.display)) root.displayIndex = parsed.display
        }
        root.names = kept
    }

    function saveState() {
        // `names` only ever holds known keys with a non-empty cleaned name —
        // applyState and commitName between them guarantee it — so this is the
        // whole file and needs no second pass over `inputs`.
        //
        // Writing before the file has been read once would save this panel's
        // empty starting state over whatever is on disk, so an early save waits
        // for the read. A missing folder waits for mkdir instead.
        if (!root.stateReady || ensureStateDir.running) {
            root.statePending = true
            return
        }
        namesFile.setText(JSON.stringify({ version: 1, names: root.names, display: root.displayIndex }, null, 2) + "\n")
    }

    // The waiting write, once whatever it was waiting for has finished. Called
    // from both of those, and either can be the second one to arrive, so the
    // flag is cleared before the retry: the retry re-arms it if it is still not
    // ready, which ends when both have happened.
    function flushState() {
        if (!root.statePending) return
        root.statePending = false
        root.saveState()
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
        root.saveState()
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
    /*
     * No display check here: displayIndex only changes through listedDisplay, so
     * by the time a command is built it is one of the four numbers in the list.
     */
    function setInput(entry) {
        if (root.busy || !entry) return
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
            if (code === 0) {
                root.statusIsError = false
                root.statusText = "Sent " + label
                root.statusDetail = ""
            } else {
                root.statusIsError = true
                // The hero line carries the part a reader can act on, and ddcutil's
                // own words go underneath in full. An exit code on its own says
                // nothing about which of the four displays was tried.
                root.statusText = "Could not switch to " + label + "."
                var detail = root.sentence(failure !== "" ? failure : buffer)
                root.statusDetail = detail !== "" ? detail : "ddcutil exited with code " + code + "."
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

    // -- state file
    /*
     * ~/.local/state/odisplay/names.json: the input names and the picked
     * display number.
     *
     * atomicWrites, so a shell killed mid-write cannot leave a half-written
     * file that parses as no state at all.
     *
     * watchChanges, so a change edited or deleted by hand shows up without a
     * restart. That also fires on this panel's own write, which is harmless:
     * it reads back the same state that was just committed.
     */
    FileView {
        id: namesFile
        path: root.namesPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: {
            root.stateReady = true
            root.applyState(text())
            root.flushState()
        }
        // First run: the folder does not exist yet, so there is nothing to read.
        onLoadFailed: {
            root.stateReady = true
            root.applyState("")
            root.flushState()
        }
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
            // Only a deferred write needs the folder. The initial read cannot:
            // a names.json that exists means the folder already did.
            root.flushState()
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
        // The bar renders this on hover, which is the only place the right-click
        // picker is advertised.
        tooltipText: "Odisplay — right-click for the display number"
        // Left opens the panel, right the display picker. The button reports which
        // button was pressed, so one widget can carry both without a second target.
        onPressed: function(button) {
            if (button === Qt.RightButton) root.toggleDisplayMenu()
            else root.toggle()
        }
    }

    /*
     * The display picker, on right-click of the bar icon.
     *
     * Four fixed numbers rather than a field: a typed value is a value to be
     * validated, and this list is what ddcutil prints in practice. The tick marks
     * the stored number, so which one is live is readable without switching.
     *
     * No `owner`: PopupCard.close() asks the owner to close, and the owner here
     * would be the panel behind it, which is not what a menu selection should do.
     */
    PopupCard {
        id: displayMenu
        anchorItem: button
        bar: root.bar
        contentWidth: displayMenu.fittedContentWidth(Style.space(180))
        contentHeight: displayMenu.fittedContentHeight(displayList.contentHeight)

        ListView {
            id: displayList
            anchors.fill: parent
            spacing: 0
            // Four rows, so the list never needs to scroll and the mouse wheel
            // over the popup should not be swallowed by it.
            interactive: false
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.displayChoices

            delegate: Item {
                id: displayRow
                required property var modelData

                width: displayList.width
                height: Style.space(30)

                Rectangle {
                    anchors.fill: parent
                    radius: Math.max(2, Style.cornerRadius)
                    color: displayMouse.containsMouse
                        ? Style.hoverFillFor(Color.popups.text, Color.accent)
                        : "transparent"
                }

                Text {
                    id: displayTick
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    width: Style.space(22)
                    horizontalAlignment: Text.AlignHCenter
                    textFormat: Text.PlainText
                    text: root.displayIndex === displayRow.modelData ? "\u2713" : ""
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: displayTick.right
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    textFormat: Text.PlainText
                    text: "ddcutil display " + displayRow.modelData
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                }

                MouseArea {
                    id: displayMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.chooseDisplay(displayRow.modelData)
                }
            }
        }
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

                    // The hero has no room for a colour cue, so the failure is
                    // repeated here in text that can actually be read.
                    Text {
                        width: parent.width
                        visible: root.statusIsError
                        text: root.plain(root.statusDetail, 200)
                        textFormat: Text.PlainText
                        color: "#f44"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }

                    // The one failure the user can fix without reading anything
                    // else: the display number moved, and the picker changes it.
                    Text {
                        width: parent.width
                        visible: root.displayMissing
                        text: "Right-click the bar icon to pick a different display."
                        textFormat: Text.PlainText
                        color: Util.alpha(Color.foreground, 0.7)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
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
                }
            }
        }
    }
}