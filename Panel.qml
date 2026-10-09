import QtQuick
import QtQuick.Controls
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
        root.statusText = "Switching to " + entry.label + " ..."
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
            var label = root.pendingEntry ? root.pendingEntry.label : "the input"
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
                     * One row per input.
                     *
                     * qs.Ui.Button renders its own `text` with Text.PlainText, so the
                     * label is a plain string here rather than a contentItem. Only the
                     * name is shown; the VCP value each one sends is in the source.
                     */
                    Repeater {
                        model: root.inputs

                        Button {
                            id: inputButton
                            required property var modelData

                            width: parent.width
                            height: 34
                            enabled: !root.busy
                            text: modelData.label
                            // Marks the input sent last. There is no confirmation
                            // step, so this is the only feedback the panel gives.
                            selected: root.lastSelected === modelData.key

                            onClicked: root.setInput(modelData)
                        }
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