import QtQuick
import Quickshell
import qs.Ui
import "Model.js" as OctoModel

BarWidget {
    id: root
    moduleName: "taufderl.octoprint"

    // Settings — the shell only ever assigns the whole `settings` object
    // (see Bar.qml's injectProps), never individual properties, so each
    // value has to be pulled out (and defaulted) via the base's setting().
    readonly property string host: String(root.setting("host", ""))
    readonly property string apiKey: String(root.setting("apiKey", ""))
    readonly property int pollSeconds: Number(root.setting("pollSeconds", 15)) || 15

    property var status: null
    property bool loading: false
    property string lastError: ""

    readonly property bool opened: panelLoader.item
        ? panelLoader.item.opened === true
        : false
    readonly property bool popoutSwitchClosing: panelLoader.item
        ? panelLoader.item.popoutSwitchClosing === true
        : false

    function open() {
        if (panelLoader.item) panelLoader.item.open()
    }

    function close() {
        if (panelLoader.item) panelLoader.item.close()
    }

    function toggle() {
        if (panelLoader.item) panelLoader.item.toggle()
    }

    function closeForPopoutSwitch() {
        if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
    }

    function injectPanel() {
        if (!panelLoader.item) return
        panelLoader.item.bar = root.bar
        panelLoader.item.settings = Qt.binding(function() { return root.settings })
        panelLoader.item.anchorItem = button
        panelLoader.item.hostWidget = root
        panelLoader.item.status = Qt.binding(function() { return root.status })
        panelLoader.item.loading = Qt.binding(function() { return root.loading })
        panelLoader.item.lastError = Qt.binding(function() { return root.lastError })
        panelLoader.item.host = Qt.binding(function() { return root.host })
        panelLoader.item.apiKey = Qt.binding(function() { return root.apiKey })
    }

    function refresh() {
        root.loading = true
        OctoModel.fetchStatus(root.host, root.apiKey, function(status, error) {
            root.loading = false
            root.lastError = error || ""
            root.status = status
        })
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()
    onHostChanged: root.refresh()
    onApiKeyChanged: root.refresh()

    Component.onCompleted: root.refresh()

    Timer {
        interval: Math.max(5, root.pollSeconds) * 1000
        running: true
        repeat: true
        triggeredOnStart: false
        onTriggered: root.refresh()
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel()
            Qt.callLater(root.injectPanel)
        }
    }

    Connections {
        target: panelLoader.item
        ignoreUnknownSignals: true
        function onRefreshRequested() { root.refresh() }
    }

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        // 🐙 stays fixed — a nod to OctoPrint's own "Tentacle logo"
        // branding at octoprint.org — rather than swapping between
        // per-state icons; only the completion % (while actually
        // printing) and the active-color urgency change.
        text: "🐙" +
              (root.status && root.status.printing && root.status.completion !== null
                  ? " " + Math.round(root.status.completion) + "%"
                  : "")
        active: !!(root.status && (root.status.printing || root.status.error))
        tooltipText: root.lastError
            ? root.lastError
            : (root.status
                ? root.status.stateText +
                  (root.status.fileName ? " · " + root.status.fileName : "") +
                  (root.status.printing && root.status.printTimeLeft !== null
                      ? " · " + OctoModel.formatDuration(root.status.printTimeLeft) + " left"
                      : "")
                : "OctoPrint")
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.LeftButton) root.toggle()
        }
    }
}
