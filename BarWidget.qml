import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import "Model.js" as OctoModel

BarWidget {
    id: root
    moduleName: "taufderl.octoprint"

    // pollSeconds isn't sensitive, so it stays on the ordinary path: the
    // shell only ever assigns the whole `settings` object (see Bar.qml's
    // injectProps), never individual properties, so it's pulled out (and
    // defaulted) via the base's setting().
    readonly property int pollSeconds: Number(root.setting("pollSeconds", 15)) || 15

    // host/apiKey are credentials — host travels with the key and has no
    // legitimate reason to live anywhere else — so unlike pollSeconds they
    // don't come from shell.json at all. shell.json is the file people
    // paste into bug reports or sync as dotfiles; a plugin's own state dir
    // is not, so these live in a dedicated, plugin-owned file instead:
    // ~/.local/state/omarchy/taufderl.octoprint/settings.json, chmod 600'd
    // after every write (see persistCredentials() below). Still
    // re-validated on every load/persist (not just at save time in Panel.
    // qml's settings editor) so a hand-edited value in that file can't
    // reach either the authenticated XHR or the "open in browser" link —
    // both of which read this same property — with an unexpected scheme,
    // embedded credentials, or path/query.
    property string host: ""
    property string apiKey: ""

    readonly property string homeDir: Quickshell.env("HOME")
    readonly property string stateDir: homeDir + "/.local/state/omarchy/taufderl.octoprint"
    readonly property string credentialsPath: stateDir + "/settings.json"
    property bool stateDirReady: false
    property bool credentialsLoaded: false

    // Migration (see migrateCredentialsFromShellSettings() below) needs to
    // read root.setting("host"/"apiKey") — but `settings` itself arrives
    // asynchronously from the shell sometime after construction (that's
    // why onSettingsChanged/onBarChanged exist below), so a value read too
    // early would just be today's still-unset default, not what's actually
    // configured. These two flags gate the read until both "the
    // credentials file doesn't exist" and "settings has actually been
    // delivered at least once" are true, in whichever order they occur —
    // otherwise a migration that runs first would capture nothing, write
    // that as if it were complete, and never get a second chance.
    property bool credentialsFileMissing: false
    property bool settingsDelivered: false

    function attemptMigrationIfNeeded() {
        if (!root.credentialsFileMissing || root.credentialsLoaded || !root.settingsDelivered) return
        root.credentialsFileMissing = false
        root.migrateCredentialsFromShellSettings()
    }

    function loadCredentialsFromText(text) {
        var parsed = {}
        try { parsed = JSON.parse(text || "{}") } catch (e) { parsed = {} }
        root.host = OctoModel.normalizeHost(String(parsed.host || ""))
        root.apiKey = String(parsed.apiKey || "")
        root.credentialsLoaded = true
        root.clearLegacyShellCredentials()
    }

    // First run after upgrading from the version that stored host/apiKey
    // in shell.json (or a fresh install using a still-cached old manifest
    // schema): the credentials file doesn't exist yet, so adopt whatever
    // is still sitting in shell.json into it, then strip those two fields
    // back out of shell.json — otherwise this would just be a copy, not a
    // move, and the plaintext original would linger right where it was.
    function migrateCredentialsFromShellSettings() {
        root.persistCredentials({
            host: OctoModel.normalizeHost(root.setting("host", "")),
            apiKey: String(root.setting("apiKey", ""))
        })
        root.credentialsLoaded = true
        root.clearLegacyShellCredentials()
    }

    function persistCredentials(values) {
        var entry = { host: root.host, apiKey: root.apiKey }
        for (var key in values) entry[key] = values[key]
        root.host = OctoModel.normalizeHost(String(entry.host || ""))
        root.apiKey = String(entry.apiKey || "")
        credentialsFile.setText(JSON.stringify({ host: root.host, apiKey: root.apiKey }, null, 2) + "\n")
        // The API key is a secret; keep the file readable only by the
        // user. A short defer gives the atomic write above somewhere to
        // land first.
        Qt.callLater(function() { chmodProc.running = true })
    }

    // Runs after every credentials load (fresh load or migration) and
    // every time `bar` becomes available, so it fires whichever happens
    // last. A no-op once shell.json's host/apiKey are already empty —
    // which they are after the first successful run — so this can't
    // resurrect a value the user has since cleared through Panel.qml.
    function clearLegacyShellCredentials() {
        if (!root.credentialsLoaded) return
        if (root.setting("host", "") === "" && root.setting("apiKey", "") === "") return
        if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
        root.bar.shell.updateEntryInline(root.moduleName, { id: root.moduleName, pollSeconds: root.pollSeconds })
    }

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

    onBarChanged: {
        injectPanel()
        root.clearLegacyShellCredentials()
        root.attemptMigrationIfNeeded()
    }
    onSettingsChanged: {
        injectPanel()
        root.settingsDelivered = true
        root.attemptMigrationIfNeeded()
    }
    onHostChanged: root.refresh()
    onApiKeyChanged: root.refresh()

    Component.onCompleted: {
        mkdirProc.running = true
        root.refresh()
    }

    // mkdir first, credentials file load only afterwards (path stays ""
    // — FileView treats that as inactive — until stateDirReady flips) so
    // a first-run migration write can never race the directory's own
    // creation.
    Process {
        id: mkdirProc
        command: ["mkdir", "-p", root.stateDir]
        onExited: root.stateDirReady = true
    }

    Process {
        id: chmodProc
        command: ["chmod", "600", root.credentialsPath]
    }

    FileView {
        id: credentialsFile
        path: root.stateDirReady ? root.credentialsPath : ""
        watchChanges: false
        atomicWrites: true
        printErrors: false
        onLoaded: root.loadCredentialsFromText(text())
        onLoadFailed: {
            root.credentialsFileMissing = true
            root.attemptMigrationIfNeeded()
        }
    }

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
