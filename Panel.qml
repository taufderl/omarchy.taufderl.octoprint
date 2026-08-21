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

    // Merges `values` into the widget's current settings and writes the
    // result back to shell.json — the same mechanism first-party plugins
    // (clock, tailscale, ...) use for inline edits. Applied to the host
    // widget immediately too, so the change is reflected without waiting
    // for the shell.json round-trip.
    function persistSettings(values) {
        var entry = { id: root.moduleName }
        for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
        for (var key in values) entry[key] = values[key]

        root.settings = entry
        if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
        if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
            root.bar.shell.updateEntryInline(root.moduleName, entry)
    }

    function commitHost(value) {
        var trimmed = OctoModel.normalizeHost(value)
        if (trimmed === root.host) return
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
                        width: parent.width - refreshLabel.width - settingsLabel.width - Style.space(16)
                        text: (root.status ? root.status.icon : "🖨️") + " OctoPrint"
                        color: root.barForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        id: settingsLabel
                        text: "⚙"
                        color: root.barForeground
                        opacity: root.editingSettings ? 1.0 : 0.6
                        font.pixelSize: Style.font.subtitle

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSettingsEditor()
                        }
                    }

                    Text {
                        id: refreshLabel
                        text: root.loading ? "⏳" : "⟳"
                        color: root.barForeground
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
                        placeholderText: "http://192.168.2.7"
                        onEditingFinished: root.commitHost(text)
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
                }

                Text {
                    visible: root.lastError.length > 0
                    width: parent.width
                    text: root.lastError
                    color: "#ff5555"
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }

                Column {
                    visible: root.lastError.length === 0 && root.status !== null
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                        width: parent.width
                        text: root.status ? root.status.stateText : ""
                        color: root.status ? root.status.color : root.barForeground
                        font.pixelSize: 14
                        font.bold: true
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: root.status && root.status.fileName !== ""
                        width: parent.width
                        text: root.status ? root.status.fileName : ""
                        color: root.barForeground
                        opacity: 0.8
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                        elide: Text.ElideMiddle
                    }

                    // Progress bar — only meaningful with an active job.
                    Item {
                        visible: root.status && root.status.completion !== null
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
                            width: root.status && root.status.completion !== null
                                ? parent.width * Math.max(0, Math.min(100, root.status.completion)) / 100
                                : 0
                            color: root.status ? root.status.color : root.barForeground
                        }
                    }

                    Text {
                        visible: root.status && root.status.completion !== null
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
