import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as OctoModel

Panel {
    id: root
    moduleName: "taufderl.octoprint"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null

    property var status: null
    property bool loading: false
    property string lastError: ""
    property string host: ""
    property string apiKey: ""
    property int pollSeconds: 15
    property bool editingSettings: false

    signal refreshRequested()

    function open() {
        root.controller.show()
    }

    function close() {
        root.controller.hide()
    }

    function toggleSettingsEditor() {
        root.editingSettings = !root.editingSettings
    }

    // Writes the full settings object back to shell.json — the same
    // mechanism first-party plugins (clock, tailscale, ...) use for inline
    // edits. Applied to the host widget immediately too, so the change is
    // reflected without waiting for the shell.json round-trip.
    //
    // Built from root.host/root.apiKey/root.pollSeconds (this plugin's own
    // individually-tracked, reactively-bound properties) rather than by
    // copying whatever's currently in root.settings — that object is only
    // as fresh as the shell's last injection into this widget, and merging
    // from a transiently stale copy would write the gap back permanently.
    // The three tracked properties are each independently sourced via
    // setting() in BarWidget.qml and self-correct on the next settings
    // change, so reconstructing the entry from them can't lose a field.
    function persistSettings(values) {
        var entry = {
            id: root.moduleName,
            host: root.host,
            apiKey: root.apiKey,
            pollSeconds: root.pollSeconds
        }
        for (var key in values) entry[key] = values[key]

        root.settings = entry
        if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
        if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
            root.bar.shell.updateEntryInline(root.moduleName, entry)
    }

    // An empty field clears the host (intentional). Non-empty input that
    // fails normalizeHost()'s validation is left uncommitted rather than
    // persisted as-is — silently accepting it would just mean root.host
    // (which re-validates on every read in BarWidget.qml) reads back as ""
    // anyway, so persisting it would only look saved without doing
    // anything.
    function commitHost(value) {
        var raw = String(value || "").trim()
        if (raw === "") {
            if (root.host !== "") persistSettings({ host: "" })
            return
        }
        var trimmed = OctoModel.normalizeHost(raw)
        if (trimmed === "" || trimmed === root.host) return
        persistSettings({ host: trimmed })
    }

    function commitApiKey(value) {
        var trimmed = String(value || "").trim()
        if (trimmed === root.apiKey) return
        persistSettings({ apiKey: trimmed })
    }

    function switchPanel(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.hostWidget || root, direction)
        return false
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(320))
        contentHeight: panel.fittedContentHeight(content.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction) }

            Column {
                id: content
                width: parent.width
                spacing: Style.space(8)

                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                        width: parent.width - refreshLabel.width - settingsLabel.width - Style.space(16) -
                               (openLinkLabel.visible ? openLinkLabel.width + Style.space(8) : 0)
                        text: "🐙 OctoPrint"
                        color: root.barForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        id: openLinkLabel
                        visible: root.host !== ""
                        text: "󰏌"
                        color: root.barForeground
                        opacity: 0.7
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.subtitle

                        MouseArea {
                            id: openLinkHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Qt.openUrlExternally(root.host)
                        }

                        PanelToolTip {
                            visible: openLinkHover.containsMouse
                            text: "Open OctoPrint in browser"
                        }
                    }

                    Text {
                        id: settingsLabel
                        text: "󰒓"
                        color: root.barForeground
                        opacity: root.editingSettings ? 1.0 : 0.6
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.subtitle

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSettingsEditor()
                        }
                    }

                    Text {
                        id: refreshLabel
                        text: root.loading ? "󰔟" : "󰑐"
                        color: root.barForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.subtitle

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.refreshRequested()
                        }
                    }
                }

                Item {
                    width: 1
                    height: Style.space(6)
                }

                Column {
                    visible: root.editingSettings
                    width: parent.width
                    spacing: Style.space(6)

                    // Resynced (rather than kept as a live binding) each
                    // time the editor opens: a declarative `text: ...`
                    // binding would be permanently severed the moment the
                    // user types a character, per normal QML semantics.
                    onVisibleChanged: {
                        if (!visible) return
                        hostField.text = root.host
                        apiKeyField.text = root.apiKey
                    }

                    Text {
                        text: "OctoPrint URL"
                        color: root.barForeground
                        opacity: 0.7
                        font.pixelSize: 11
                    }

                    TextField {
                        id: hostField
                        width: parent.width
                        placeholderText: "http://octopi.local"
                        onEditingFinished: root.commitHost(text)
                    }

                    Text {
                        visible: hostField.text !== "" && OctoModel.normalizeHost(hostField.text) === ""
                        width: parent.width
                        text: "Must be a plain http:// or https:// address — no credentials, path, or query string."
                        color: "#ff5555"
                        font.pixelSize: 10
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: /^http:\/\//i.test(OctoModel.normalizeHost(hostField.text))
                        width: parent.width
                        text: "⚠ Plain HTTP sends the API key unencrypted — anyone on this network segment can read it. Use https:// if your OctoPrint instance supports it."
                        color: "#ffb86c"
                        font.pixelSize: 10
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        text: "API key (Settings → API in OctoPrint)"
                        color: root.barForeground
                        opacity: 0.7
                        font.pixelSize: 11
                    }

                    TextField {
                        id: apiKeyField
                        width: parent.width
                        password: true
                        placeholderText: "API key"
                        onEditingFinished: root.commitApiKey(text)
                    }

                    Text {
                        width: parent.width
                        text: "Stored in plaintext in shell.json — Omarchy exposes no secret-storage mechanism to third-party plugins. Use a scoped/revocable key."
                        color: root.barForeground
                        opacity: 0.5
                        font.pixelSize: 10
                        wrapMode: Text.WordWrap
                    }
                }

                Text {
                    visible: root.lastError.length > 0
                    width: parent.width
                    text: root.lastError
                    color: "#ff5555"
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }

                Text {
                    visible: /^http:\/\//i.test(root.host)
                    width: parent.width
                    text: "⚠ Connected over plain HTTP — the API key is sent unencrypted on this network segment."
                    color: "#ffb86c"
                    font.pixelSize: 10
                    wrapMode: Text.WordWrap
                }

                Column {
                    id: statusColumn
                    visible: root.lastError.length === 0 && root.status !== null
                    width: parent.width
                    spacing: Style.space(6)

                    // OctoPrint's /api/job keeps reporting the *previous*
                    // job's completion/printTimeLeft even after it
                    // finishes and the state moves back to "Operational" —
                    // it doesn't clear that until a new file is loaded. So
                    // this can't just check completion !== null, or the
                    // progress bar and "100% · 0m left" line stay stuck
                    // showing after a print is done.
                    readonly property bool showProgress: root.status &&
                        (root.status.printing || root.status.paused) &&
                        root.status.completion !== null

                    Text {
                        width: parent.width
                        text: root.status ? root.status.statusIcon + " " + root.status.stateText : ""
                        textFormat: Text.PlainText
                        color: root.status ? root.status.color : root.barForeground
                        font.pixelSize: 14
                        font.bold: true
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        // Same reasoning as showProgress below: OctoPrint
                        // keeps reporting the last-printed file's name
                        // indefinitely once idle, not just fileName !== "".
                        visible: root.status && (root.status.printing || root.status.paused) && root.status.fileName !== ""
                        width: parent.width
                        text: root.status ? root.status.fileName : ""
                        textFormat: Text.PlainText
                        color: root.barForeground
                        opacity: 0.8
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                        elide: Text.ElideMiddle
                    }

                    // Progress bar — only while actually mid-print, not
                    // just whenever completion happens to be non-null.
                    Item {
                        visible: statusColumn.showProgress
                        width: parent.width
                        height: Style.space(8)

                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            color: root.barForeground
                            opacity: 0.15
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            radius: height / 2
                            width: statusColumn.showProgress
                                ? parent.width * Math.max(0, Math.min(100, root.status.completion)) / 100
                                : 0
                            color: root.status ? root.status.color : root.barForeground
                        }
                    }

                    Text {
                        visible: statusColumn.showProgress
                        text: root.status
                            ? Math.round(root.status.completion) + "%" +
                              (root.status.printTimeLeft !== null ? " · " + OctoModel.formatDuration(root.status.printTimeLeft) + " left" : "")
                            : ""
                        color: root.barForeground
                        opacity: 0.8
                        font.pixelSize: 11
                    }

                    Row {
                        width: parent.width
                        spacing: Style.space(16)

                        Text {
                            visible: root.status && root.status.toolActual !== null
                            text: "🔥 " + (root.status ? OctoModel.formatTemp(root.status.toolActual) : "") +
                                  (root.status && root.status.toolTarget ? " → " + OctoModel.formatTemp(root.status.toolTarget) : "")
                            color: root.barForeground
                            font.pixelSize: 12
                        }

                        Text {
                            visible: root.status && root.status.bedActual !== null
                            text: "🛏 " + (root.status ? OctoModel.formatTemp(root.status.bedActual) : "") +
                                  (root.status && root.status.bedTarget ? " → " + OctoModel.formatTemp(root.status.bedTarget) : "")
                            color: root.barForeground
                            font.pixelSize: 12
                        }
                    }
                }
            }
        }
    }
}
