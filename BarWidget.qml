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
    // Re-validated here (not just at save time in Panel.qml's settings
    // editor) so a value hand-edited directly into shell.json can't reach
    // either the authenticated XHR or the "open in browser" link — both
    // of which read this same property — with an unexpected scheme,
    // embedded credentials, or path/query.
    readonly property string host: OctoModel.normalizeHost(root.setting("host", ""))
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
        panelLoader.item.pollSeconds = Qt.binding(function() { return root.pollSeconds })
    }

    function refresh() {
        if (root.loading) return
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
        // 10s floor keeps this comfortably above getJson's 8s per-request
        // timeout (Model.js) — refresh()'s own in-flight guard above is the
        // real safeguard against overlap, this just avoids a low setting
        // firing a timer that does nothing every few seconds.
        interval: Math.max(10, root.pollSeconds) * 1000
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
        // fileName/printTimeLeft gated on printing (not just presence) —
        // OctoPrint keeps reporting the last job's data indefinitely once
        // idle, not just while actually printing/paused.
        tooltipText: root.lastError
            ? root.lastError
            : (root.status
                ? root.status.stateText +
                  ((root.status.printing || root.status.paused) && root.status.fileName ? " · " + root.status.fileName : "") +
                  (root.status.printing && root.status.printTimeLeft !== null
                      ? " · " + OctoModel.formatDuration(root.status.printTimeLeft) + " left"
                      : "")
                : "OctoPrint")
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.LeftButton) root.toggle()
        }
    }
}
