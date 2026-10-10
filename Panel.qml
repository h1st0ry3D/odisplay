import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

/*
 * Odisplay: pick a monitor input from the bar.
 *
 * The panel does not talk to the monitor or to the Logitech receiver. It runs
 * one program, odisplay, which owns the order of operations: the monitor moves
 * first, and the keyboard and mouse only move once it has. That rule is the
 * only thing here that can leave someone unable to type, so it lives in one
 * place instead of in every caller.
 *
 * This panel never writes the settings file itself. It asks odisplay to, so
 * there is one writer that also validates what it is given.
 *
 * odisplay's output is untrusted input. A Text without textFormat sits on
 * Text.AutoText, which renders a string that looks like markup as rich text,
 * and rich text can load an image from a URL the string chooses.
 */
Panel {
    id: root

    moduleName: "h1st0ry3d.odisplay"
    ipcTarget: "h1st0ry3d.odisplay"
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    // -- the program this panel needs
    /*
     * Where odisplay is looked for, in order. The first is the conventional
     * place for something installed system-wide; the second needs no privileges,
     * which is why it is here too.
     */
    readonly property string homeDir: Quickshell.env("HOME") || ""
    readonly property var cliCandidates: [
        "/usr/local/bin/odisplay",
        root.homeDir + "/.local/bin/odisplay"
    ]

    // Resolved once at startup. Empty until the probe finishes, so nothing is
    // sent at a path that has not been checked.
    property string cliPath: ""
    property bool cliMissing: false

    /*
     * odisplay needs HOME to find its config, and XDG_CONFIG_HOME or
     * ODISPLAY_CONFIG if the user set either. Everything else is withheld, so
     * nothing in the session can change what a program name resolves to.
     */
    readonly property var cliEnvironment: {
        var e = ({ "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "HOME": root.homeDir })
        var configHome = Quickshell.env("XDG_CONFIG_HOME") || ""
        var override = Quickshell.env("ODISPLAY_CONFIG") || ""
        if (configHome !== "") e["XDG_CONFIG_HOME"] = configHome
        if (override !== "") e["ODISPLAY_CONFIG"] = override
        return e
    }

    /*
     * Find odisplay, and say so plainly if it is not there. A panel whose
     * buttons silently do nothing is the worst outcome, so this is checked at
     * startup rather than discovered on the first click.
     */
    Process {
        id: cliProbe
        running: false
        property int attempt: 0
        stdout: SplitParser { onRead: function(chunk) {} }
        stderr: SplitParser { onRead: function(chunk) {} }
        environment: root.cliEnvironment
        clearEnvironment: true
        command: ["/usr/bin/test", "-x", root.cliCandidates[cliProbe.attempt]]

        onExited: function(code) {
            if (code === 0) {
                root.cliPath = root.cliCandidates[cliProbe.attempt]
                root.cliMissing = false
                // The panel may have been opened while this probe was still
                // running, and refreshSettings does nothing without a path. Read
                // now as well, so which of the two happened first does not
                // decide whether the panel has any rows.
                if (!root.loadedReady) root.refreshSettings()
                return
            }
            cliProbe.attempt++
            if (cliProbe.attempt < root.cliCandidates.length) {
                cliProbe.command = ["/usr/bin/test", "-x", root.cliCandidates[cliProbe.attempt]]
                cliProbe.running = true
                return
            }
            root.cliMissing = true
            root.statusIsError = true
            root.statusText = "odisplay is not installed."
            root.statusDetail = "Put the odisplay binary at " + root.cliCandidates[0]
                + " or " + root.cliCandidates[1] + ", then reopen the panel."
        }
    }

    // -- settings, read back from odisplay
    /*
     * The inputs, hosts and display number, as odisplay reports them after
     * validating the file. The panel renders what odisplay would send, rather
     * than keeping its own copy of the numbers and its own idea of which are
     * valid.
     */
    property var loaded: null
    property bool loadedReady: false

    readonly property var inputs: root.loadedReady && root.loaded && root.loaded.inputs
        ? root.loaded.inputs : []

    /*
     * Built-in labels for an input the user has not named. Display only: an
     * empty name in the file falls back to one of these, and nothing reads them
     * as anything but a word on a button.
     */
    readonly property var fallbackLabels: ({
        usbc: "USB-C",
        dp: "DisplayPort",
        hdmi: "HDMI"
    })

    readonly property int displayIndex: root.loadedReady && root.loaded
        ? Math.max(1, Number(root.loaded.display) || 1) : 1

    /*
     * An oversized reply is cut off rather than collected whole. odisplay prints
     * a few lines or nothing, so this is a backstop, not a budget to fill.
     */
    readonly property int outputLimit: 4096

    /*
     * odisplay enforces its own timeouts and always exits, so this is only a
     * backstop for one that has wedged. It has to clear the worst case odisplay
     * allows: eight seconds for the display and ten for each device, with the
     * mouse last.
     */
    readonly property int watchdogMs: 40000

    /*
     * The Easy-Switch channel for each input. "0" leaves the devices alone,
     * which is the default and the right choice for an input that is not a
     * Logitech machine.
     */
    readonly property var hostChoices: ["0", "1", "2", "3"]

    function validHost(value) {
        return root.hostChoices.indexOf(String(value)) !== -1
    }

    // The channel this input is set to, with anything off the list read as off.
    function hostFor(key) {
        for (var index = 0; index < root.inputs.length; index++) {
            if (root.inputs[index].key !== key) continue
            var chosen = root.inputs[index].host
            if (chosen === undefined || chosen === null) return "0"
            return root.validHost(chosen) ? String(chosen) : "0"
        }
        return "0"
    }

    function cycleHost(key) {
        if (root.busy) return
        var index = root.hostChoices.indexOf(root.hostFor(key))
        if (index < 0) index = 0
        var next = root.hostChoices[(index + 1) % root.hostChoices.length]
        // Shown straight away so the button answers the click; odisplay's own
        // answer follows and wins if the two ever disagree.
        root.applyLocally(key, "host", next)
        root.runSet(["set", "host", key, next])
    }

    // -- untrusted input
    /*
     * Strip what a rich-text renderer could act on, then cap the length, for the
     * components the shell renders itself and where textFormat cannot be set.
     *
     * A line break becomes a space rather than being dropped: dropping it glues
     * the last word of one line to the first of the next into a word nobody
     * wrote, and keeping it would break the single-line hero. Runs of
     * whitespace collapse, so wrapped output reads as sentences.
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
     * odisplay's own words as one sentence. Its first line says what failed and
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
     * ddcutil's display numbers come from `ddcutil detect` and are not stable
     * across reboots, so the index is picked rather than typed: right-clicking
     * the bar icon offers the numbers ddcutil actually prints, and nothing
     * outside this list can reach odisplay.
     */
    readonly property var displayChoices: [1, 2, 3, 4]

    function listedDisplay(value) {
        return typeof value === "number" && root.displayChoices.indexOf(value) !== -1
    }

    /*
     * One entry picked from the display menu. The choice is stored so the tick
     * comes back after a shell restart, and the menu folds away either way.
     */
    function chooseDisplay(value) {
        if (!root.listedDisplay(value)) return
        if (value !== root.displayIndex) {
            root.applyDisplayLocally(value)
            // A failed switch is the panel's way of pointing at this menu, so
            // picking from it takes that hint away rather than leaving it next to
            // the number the user just changed.
            root.statusIsError = false
            root.statusDetail = ""
            root.statusText = "Using display " + value
            root.runSet(["set", "display", String(value)])
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
     * The key of the row that is currently a text field, or "" for none. One
     * at a time, so there is only ever one field to focus.
     */
    property string renamingKey: ""
    readonly property bool renaming: root.renamingKey !== ""

    readonly property int maxNameLength: 32

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
        for (var index = 0; index < root.inputs.length; index++) {
            if (root.inputs[index].key !== key) continue
            var custom = root.inputs[index].name
            if (typeof custom === "string" && custom !== "") return custom
            break
        }
        return root.fallbackLabels[key] || ""
    }

    /*
     * Show a change before odisplay has been asked, so a button answers its
     * click immediately. The next read replaces this wholesale, and it is
     * reading a file odisplay has just written, so the two agree.
     */
    function applyLocally(key, field, value) {
        if (!root.loaded || !root.loaded.inputs) return
        // A copy, because binding invalidation needs a new object.
        var next = JSON.parse(JSON.stringify(root.loaded))
        for (var index = 0; index < next.inputs.length; index++) {
            if (next.inputs[index].key === key) next.inputs[index][field] = value
        }
        root.loaded = next
    }

    function applyDisplayLocally(value) {
        if (!root.loaded) return
        var next = JSON.parse(JSON.stringify(root.loaded))
        next.display = value
        root.loaded = next
    }

    /*
     * Closing must not leave a field open on a hidden window. Watching the open
     * state covers every way out: outside click, Escape, the bar button, IPC.
     *
     * It also re-reads the settings, so a change made in a terminal shows up on
     * the next open rather than needing a shell restart.
     */
    onOpenedChanged: {
        root.cancelRename()
        if (root.opened) {
            root.refreshSettings()
            return
        }
        root.clearStatus()
    }

    function clearStatus() {
        if (root.cliMissing) return
        root.statusIsError = false
        root.statusDetail = ""
        root.statusText = "Set input source"
    }

    // -- settings read
    function refreshSettings() {
        if (root.cliPath === "") return
        settingsProcess.buffer = ""
        settingsProcess.command = [root.cliPath, "list", "--json"]
        settingsProcess.running = true
    }

    /*
     * An empty split marker hands over raw chunks, so an oversized reply can be
     * cut off. A line-buffered parser has to hold the whole line first.
     */
    Process {
        id: settingsProcess
        running: false
        property string buffer: ""

        stdout: SplitParser {
            splitMarker: ""
            onRead: function(chunk) {
                if (settingsProcess.buffer.length <= root.outputLimit)
                    settingsProcess.buffer += chunk
            }
        }
        stderr: SplitParser { onRead: function(chunk) {} }
        environment: root.cliEnvironment
        clearEnvironment: true
        command: [root.cliPath, "list", "--json"]

        onExited: function(code) {
            var text = settingsProcess.buffer
            settingsProcess.buffer = ""
            if (code !== 0) {
                root.statusIsError = true
                root.statusText = "Could not read the odisplay settings."
                root.statusDetail = "Run `odisplay doctor` in a terminal to see why."
                return
            }
            var parsed = null
            try { parsed = JSON.parse(String(text).trim() || "null") } catch (e) { parsed = null }
            if (!parsed || !parsed.inputs) {
                root.statusIsError = true
                root.statusText = "Could not read the odisplay settings."
                root.statusDetail = "odisplay printed something this panel does not understand."
                return
            }
            root.loaded = parsed
            root.loadedReady = true
        }
    }

    // -- settings write
    /*
     * Every change goes through odisplay, which is the only writer of the file.
     * The read afterwards is what makes the file and the panel agree; it is not
     * an optimisation and it does not skip anything.
     *
     * Deliberately not refused while busy. The caller has already shown the
     * change, so dropping the write here would leave the panel claiming
     * something the file does not say. odisplay writes atomically, so a save
     * running alongside a switch is not a race worth refusing.
     */
    function runSet(args) {
        if (root.cliPath === "") return
        setProcess.buffer = ""
        setProcess.failure = ""
        setProcess.command = [root.cliPath].concat(args)
        setProcess.running = true
    }

    Process {
        id: setProcess
        running: false
        property string buffer: ""
        property string failure: ""

        stdout: SplitParser { onRead: function(chunk) {} }
        stderr: SplitParser {
            splitMarker: ""
            onRead: function(chunk) {
                if (setProcess.failure.length <= root.outputLimit)
                    setProcess.failure += chunk
            }
        }
        environment: root.cliEnvironment
        clearEnvironment: true

        onExited: function(code) {
            var err = root.plain(setProcess.failure.trim(), 200)
            setProcess.buffer = ""
            setProcess.failure = ""
            // Re-read either way: a refused change must not stay on screen as
            // though it took.
            root.refreshSettings()
            if (code === 0 || err === "") return
            root.statusIsError = true
            root.statusText = "Could not save that."
            root.statusDetail = err
        }
    }

    // -- input switching
    /*
     * One call. odisplay moves the monitor and then, only if that worked, the
     * keyboard and mouse. This panel never sees the individual commands, so it
     * cannot reorder them.
     */
    function setInput(entry) {
        if (root.busy || !entry) return
        root.send(entry)
    }

    function send(entry) {
        if (root.busy || !entry || root.cliPath === "") return
        root.pendingKey = entry.key
        root.lastSelected = entry.key
        root.statusIsError = false
        root.statusDetail = ""
        // The name the user gave this input, not the built-in one.
        root.statusText = "Switching to " + root.labelFor(entry.key) + " ..."
        odisplayProcess.buffer = ""
        odisplayProcess.failure = ""
        // Every element is its own argument. No shell, so nothing is parsed twice.
        odisplayProcess.command = [root.cliPath, "switch", entry.key]
        odisplayProcess.running = true
        switchWatchdog.restart()
    }

    // The input the in-flight switch is for, so the result is reported against
    // the right label.
    property string pendingKey: ""

    /*
     * odisplay's exit codes are the contract, and two of them mean opposite
     * things about where the user's keyboard is, so they are not flattened into
     * one message. These are only the fallbacks: odisplay says both halves
     * itself, in words meant for one line of a panel.
     */
    function failedText(code) {
        switch (code) {
        case 1:
            return "odisplay could not use the settings file."
        case 2:
            return "Could not switch. The keyboard and mouse were left alone."
        case 3:
            return "The display moved but the keyboard and mouse did not. The switch underneath the mouse or keyboard is the way back."
        case 4:
            return "A program this needs is not installed."
        default:
            return "odisplay exited with code " + code + "."
        }
    }

    Process {
        id: odisplayProcess
        running: false
        property string buffer: ""
        property string failure: ""

        stdout: SplitParser {
            splitMarker: ""
            onRead: function(chunk) {
                if (odisplayProcess.buffer.length <= root.outputLimit)
                    odisplayProcess.buffer += chunk
            }
        }
        stderr: SplitParser {
            splitMarker: ""
            onRead: function(chunk) {
                if (odisplayProcess.failure.length <= root.outputLimit)
                    odisplayProcess.failure += chunk
            }
        }
        environment: root.cliEnvironment
        clearEnvironment: true

        onExited: function(code) {
            switchWatchdog.stop()
            var out = odisplayProcess.buffer
            var err = odisplayProcess.failure
            odisplayProcess.buffer = ""
            odisplayProcess.failure = ""

            var key = root.pendingKey
            root.pendingKey = ""
            var label = key !== "" ? root.labelFor(key) : "the input"

            // odisplay's own sentence, already written for one line.
            var said = root.plain(out, 120)
            root.statusIsError = code !== 0
            root.statusDetail = ""

            if (code === 0) {
                root.statusText = said !== "" ? root.plain(said, 80) : ("Sent " + label)
                return
            }

            var fallback = root.failedText(code)
            root.statusText = said !== "" ? root.plain(said, 80) : root.plain(fallback, 80)
            // The detail carries why, in full. An exit code on its own says
            // nothing about which of the displays was tried.
            root.statusDetail = root.plain(root.sentence(err), 200) || fallback
        }
    }

    /*
     * ddcutil answers a setvcp in well under a second. This is only the backstop
     * for a call that does not come back at all, which an I2C bus can do when
     * the adapter is taken away underneath it. odisplay has its own timeouts,
     * so this has to clear the slowest odisplay is allowed to be.
     */
    Timer {
        id: switchWatchdog
        interval: root.watchdogMs
        onTriggered: if (odisplayProcess.running) odisplayProcess.signal(15)
    }

    /*
     * Outcome of the last switch, shown in the hero line. Session only: the
     * monitor's own OSD is the source of truth for what it is showing, so
     * nothing here is stored and later re-read as if it were.
     */
    property string statusText: "Set input source"
    property bool statusIsError: false
    // What went wrong underneath the sentence the hero line carries. Empty while
    // nothing has failed.
    property string statusDetail: ""
    property string lastSelected: ""

    /*
     * ddcutil's most common failure on this panel is a display number that has
     * moved since the last reboot. That one gets the way out spelled out, because
     * "Display not found" on its own says nothing about what to do.
     */
    readonly property bool displayMissing: root.statusIsError
        && /\bdisplay\b/i.test(root.statusDetail)
        && /\bnot found\b|\bno displays?\b|\bno such\b|\bunknown display\b|\bfailed to find\b/i.test(root.statusDetail)

    /*
     * Only a switch or a save disables the buttons, so the panel stays
     * responsive. Reading the settings does not: it is quick, and it runs while
     * the panel is opening.
     *
     * A rename is not in here. The row being renamed has already swapped its
     * button for a field, and making everything else unclickable while one field
     * is open is a rule this panel did not have before.
     */
    readonly property bool busy: odisplayProcess.running || setProcess.running

    // Nothing started here may outlive the panel.
    Component.onDestruction: {
        if (odisplayProcess.running) odisplayProcess.signal(15)
        if (setProcess.running) setProcess.signal(15)
        if (settingsProcess.running) settingsProcess.signal(15)
    }

    Component.onCompleted: cliProbe.running = true

    // -- custom names
    /*
     * Right-click on a row. One field is open at a time, so right-clicking a
     * second row moves the field and abandons whatever was typed in the first.
     */
    function renameInput(key) {
        if (root.busy) return
        root.renamingKey = key
    }

    // Enter commits, and so does focus loss, which is what editingFinished
    // reports. Escape puts the row back. Each of those arrives twice for one
    // keystroke, so the renamingKey guard makes the second call a no-op and a
    // cancelled rename cannot land.
    function commitName(key, text) {
        if (root.renamingKey !== key) return
        var name = root.cleanName(text)
        root.endRename()
        // An empty name is a rename back to the built-in label, which is what
        // removing the name from the file means.
        root.applyLocally(key, "name", name)
        root.runSet(["set", "name", key, name])
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
     * The two columns' measurements, shared by the header icons and the rows
     * under them. A width written in both places drifts the moment one of them
     * is edited, and the icons stop pointing at the buttons they label.
     */
    readonly property int hostColumnWidth: Style.space(42)
    readonly property int columnGap: Style.space(6)

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
                     * label is a plain string here rather than a contentItem.
                     *
                     * Right-click renames. The field replaces the button rather than
                     * opening next to it, so the row does not change height and the
                     * panel does not move under the pointer.
                     */
                    /*
                     * One header icon per column, then one row per input.
                     *
                     * The widths have to match the rows below, or the icons sit
                     * over the wrong button: the label column ends where the
                     * switch column starts, and the switch column is as wide as
                     * the host buttons. Both come from the same two properties
                     * the rows use, so they cannot drift apart.
                     *
                     * No border on the header: a box around it reads as a third
                     * button rather than a label for two.
                     */
                    Item {
                        id: headerRow

                        width: parent.width
                        height: 20

                        Text {
                            anchors.left: parent.left
                            anchors.right: switchHeader.left
                            anchors.rightMargin: root.columnGap
                            anchors.verticalCenter: parent.verticalCenter
                            // The bar icon again, so the column under it is
                            // the same thing the bar button switches. Centred,
                            // because the button's own label is.
                            text: "\uf26c"
                            textFormat: Text.PlainText
                            color: Util.alpha(Color.foreground, 0.7)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                        }

                        Text {
                            id: switchHeader
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: root.hostColumnWidth
                            text: "\uf11c"
                            textFormat: Text.PlainText
                            color: Util.alpha(Color.foreground, 0.7)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                        }
                    }

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

                            // The header icon sits above the Easy-Switch button, and
                            // this is its width. The row's own width comes from it.
                            readonly property int hostWidth: root.hostColumnWidth

                            // A visible gap between the two buttons, so they read as
                            // separate controls rather than one split button.
                            readonly property int gap: root.columnGap

                            Button {
                                id: inputButton
                                anchors.left: parent.left
                                anchors.right: hostButton.left
                                anchors.rightMargin: inputRow.gap
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                visible: !inputRow.isRenaming
                                enabled: !root.busy
                                bordered: true
                                text: root.labelFor(modelData.key)
                                // Marks the input sent last. There is no confirmation
                                // step, so this is the only feedback the panel gives.
                                selected: root.lastSelected === modelData.key

                                onClicked: root.setInput(modelData)
                                onRightClicked: root.renameInput(modelData.key)
                            }

                            /*
                             * Cycles this input's Easy-Switch channel: off, 1, 2, 3.
                             *
                             * A cycle rather than a popup on purpose. qs.Ui.Dropdown
                             * renders its options in a separate window, and no
                             * first-party panel puts one inside a KeyboardPanel's
                             * layer-shell surface, where the popup can end up behind
                             * the bar or unable to take the keys. This cannot: it is
                             * two or three characters in the row that is already there.
                             */
                            Button {
                                id: hostButton
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: inputRow.hostWidth
                                enabled: !root.busy
                                bordered: true
                                // The channel itself, spelled out. The tooltip carries
                                // the long form, so the button can stay narrow.
                                text: root.hostFor(modelData.key) === "0"
                                    ? "off"
                                    : root.hostFor(modelData.key)

                                tooltipText: root.hostFor(modelData.key) === "0"
                                    ? "Keyboard and mouse stay put"
                                    : "Move keyboard and mouse to host " + root.hostFor(modelData.key)

                                onClicked: root.cycleHost(modelData.key)
                            }

                            TextField {
                                anchors.left: parent.left
                                anchors.right: hostButton.left
                                anchors.rightMargin: inputRow.gap
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                visible: inputRow.isRenaming
                                enabled: inputRow.isRenaming
                                // Bound to nothing: the text is whatever the user
                                // typed, and a binding to the settings would overwrite
                                // it on the first keystroke. It is set when the field
                                // opens and read on the way out.
                                maximumLength: root.maxNameLength
                                font.family: Style.font.family
                                placeholderText: root.labelFor(modelData.key)

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