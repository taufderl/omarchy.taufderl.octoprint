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
    // ~/.local/state/omarchy/taufderl.octoprint/settings.json, mode 600
    // from the moment it's created (see writeCredentialsArgs() in
    // Model.js, driven from persistCredentials() below). Still
    // re-validated on every load/persist (not just at save time in Panel.
    // qml's settings editor) so a hand-edited value in that file can't
    // reach either the authenticated curl request or the "open in
    // browser" link — both of which read this same property — with an
    // unexpected scheme, embedded credentials, or path/query.
    property string host: ""
    property string apiKey: ""

    readonly property string homeDir: Quickshell.env("HOME")
    readonly property string stateDir: homeDir + "/.local/state/omarchy/taufderl.octoprint"
    readonly property string credentialsPath: stateDir + "/settings.json"
    property bool stateDirReady: false
    property bool credentialsLoaded: false
    property string _pendingCredentialsJson: ""

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

    // Kicks off the bounded read (see Model.js's readCredentialsArgs) once
    // the state directory is confirmed to exist. Exit codes match what
    // that script documents: 0 = read the (bounded, regular-file-only)
    // content; 2 = stat failed, i.e. no credentials file yet, so this is
    // either a fresh install or an upgrade that still needs migrating;
    // anything else = the file exists but isn't safe to trust (too large,
    // or not a regular file) — surface that rather than silently retrying
    // or overwriting whatever is actually there.
    function loadCredentials() {
        credentialsReadProc.command = OctoModel.readCredentialsArgs(root.credentialsPath)
        credentialsReadProc.running = true
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
        var json = JSON.stringify({ host: root.host, apiKey: root.apiKey }, null, 2) + "\n"
        // json (carries apiKey) goes over stdin, not argv — see
        // Model.js's writeCredentialsArgs() doc comment.
        root._pendingCredentialsJson = json
        credentialsWriteProc.command = OctoModel.writeCredentialsArgs(root.credentialsPath)
        credentialsWriteProc.running = true
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

    // Validates host/apiKey before starting the two curl Processes (see
    // startFetch()/jobProc/printerProc below) — starting them is a
    // QML-side operation, so these checks live here rather than in
    // Model.js.
    function refresh() {
        if (root.loading) return
        if (root.host === "") {
            root.loading = false
            root.lastError = "No OctoPrint host configured"
            root.status = null
            return
        }
        if (root.apiKey.trim() === "") {
            root.loading = false
            root.lastError = "No OctoPrint API key configured"
            root.status = null
            return
        }
        root.loading = true
        root.startFetch()
    }

    property var _jobResult: null
    property var _printerResult: null
    property int _fetchSeq: 0
    property string _apiKeyConfigPath: ""
    property string _pendingApiKeyConfigLine: ""

    // The API key never touches curl's argv (see Model.js's curlArgs()) —
    // it's written to a one-time-use --config file first, both requests
    // read it from there, and it's deleted once both have finished (see
    // maybeFinishFetch()). _fetchSeq makes each cycle's path unique, so a
    // slow cleanup from a previous cycle can never race a fresh write for
    // this one.
    function startFetch() {
        root._jobResult = null
        root._printerResult = null
        root._fetchSeq++
        root._apiKeyConfigPath = root.stateDir + "/apikey." + root._fetchSeq + ".curlconf"
        // The config line (carries apiKey) goes over stdin, not argv —
        // see Model.js's writeApiKeyConfigArgs() doc comment.
        root._pendingApiKeyConfigLine = OctoModel.apiKeyConfigLine(root.apiKey)
        apiKeyConfigWriteProc.command = OctoModel.writeApiKeyConfigArgs(root._apiKeyConfigPath)
        apiKeyConfigWriteProc.running = true
    }

    function maybeFinishFetch() {
        if (root._jobResult === null || root._printerResult === null) return
        root.loading = false
        var combined = OctoModel.combineResults(root._jobResult, root._printerResult)
        root.lastError = combined.error || ""
        root.status = combined.status
        apiKeyConfigRemoveProc.command = OctoModel.removeApiKeyConfigArgs(root._apiKeyConfigPath)
        apiKeyConfigRemoveProc.running = true
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
    onStateDirReadyChanged: if (root.stateDirReady) root.loadCredentials()

    Component.onCompleted: {
        mkdirProc.running = true
        root.refresh()
    }

    // install -d (unlike plain mkdir -p) applies its -m mode only to the
    // named leaf directory — any missing parents (e.g. a not-yet-existing
    // ~/.local/state/omarchy/) are created at the normal default mode, so
    // this can't affect the shared parent other plugins' state dirs also
    // live under. The credentials file this plugin writes below therefore
    // sits inside an owner-only directory from before it's ever created,
    // not just after a later chmod.
    Process {
        id: mkdirProc
        command: ["install", "-d", "-m", "700", "--", root.stateDir]
        onExited: {
            root.stateDirReady = true
            // Best-effort: clears out an apikey.*.curlconf a previous run
            // left behind by ending mid-fetch (crash, forced restart) —
            // the normal path already removes its own file once both
            // requests using it finish (see maybeFinishFetch()).
            cleanupStaleApiKeyConfigsProc.command = OctoModel.cleanupStaleApiKeyConfigsArgs(root.stateDir)
            cleanupStaleApiKeyConfigsProc.running = true
        }
    }

    Process {
        id: cleanupStaleApiKeyConfigsProc
        command: []
    }

    property string _credentialsReadOutput: ""

    // See Model.js's readCredentialsArgs()/writeCredentialsArgs() for why
    // these run a small shell script instead of using Quickshell.Io's
    // FileView: a bounded, type-checked read, and a write that's mode 600
    // from creation rather than chmod'd afterward.
    Process {
        id: credentialsReadProc
        command: []
        stdout: StdioCollector {
            id: credentialsReadStdout
            waitForEnd: true
            onStreamFinished: root._credentialsReadOutput = text
        }
        onExited: function(exitCode) {
            if (exitCode === 0) {
                root.loadCredentialsFromText(String(credentialsReadStdout.text || root._credentialsReadOutput || ""))
            } else if (exitCode === 2) {
                root.credentialsFileMissing = true
                root.attemptMigrationIfNeeded()
            } else {
                root.credentialsLoaded = true
                root.lastError = "OctoPrint credentials file looks invalid (~/.local/state/omarchy/taufderl.octoprint/settings.json) — not loading it"
            }
        }
    }

    // apiKey (inside the JSON) is delivered over stdin rather than argv —
    // write() only does anything once the process is actually running
    // (this->process is set), hence doing it from onRunningChanged rather
    // than right after setting `running = true`. Clearing stdinEnabled
    // closes the write channel, which is this script's only EOF signal
    // for `cat` to stop reading and move on to the rename.
    Process {
        id: credentialsWriteProc
        command: []
        stdinEnabled: true
        onRunningChanged: {
            if (running) {
                write(root._pendingCredentialsJson)
                stdinEnabled = false
            } else {
                stdinEnabled = true
            }
        }
    }

    // Writes the per-cycle --config file (see startFetch()), then kicks
    // off both curl requests once it's actually landed on disk — mode
    // 600, so no window where it's readable by anyone but this user.
    // apiKey is delivered over stdin rather than argv — see
    // credentialsWriteProc above for why write() happens in
    // onRunningChanged and stdinEnabled is reset in the `else` branch.
    Process {
        id: apiKeyConfigWriteProc
        command: []
        stdinEnabled: true
        onRunningChanged: {
            if (running) {
                write(root._pendingApiKeyConfigLine)
                stdinEnabled = false
            } else {
                stdinEnabled = true
            }
        }
        onExited: function(exitCode) {
            if (exitCode !== 0) {
                root.loading = false
                root.lastError = "Could not prepare the OctoPrint request"
                apiKeyConfigRemoveProc.command = OctoModel.removeApiKeyConfigArgs(root._apiKeyConfigPath)
                apiKeyConfigRemoveProc.running = true
                return
            }
            jobProc.command = OctoModel.curlArgs(root.host + "/api/job", root._apiKeyConfigPath)
            printerProc.command = OctoModel.curlArgs(root.host + "/api/printer", root._apiKeyConfigPath)
            jobProc.running = true
            printerProc.running = true
        }
    }

    Process {
        id: apiKeyConfigRemoveProc
        command: []
    }

    property string _jobOutput: ""
    property string _printerOutput: ""

    Process {
        id: jobProc
        command: []
        stdout: StdioCollector { id: jobStdout; waitForEnd: true; onStreamFinished: root._jobOutput = text }
        onExited: function(exitCode) {
            root._jobResult = OctoModel.interpretCurlExit(exitCode, String(jobStdout.text || root._jobOutput || ""))
            root.maybeFinishFetch()
        }
    }

    Process {
        id: printerProc
        command: []
        stdout: StdioCollector { id: printerStdout; waitForEnd: true; onStreamFinished: root._printerOutput = text }
        onExited: function(exitCode) {
            root._printerResult = OctoModel.interpretCurlExit(exitCode, String(printerStdout.text || root._printerOutput || ""))
            root.maybeFinishFetch()
        }
    }

    Timer {
        // 10s floor keeps this comfortably above curlArgs' 8s --max-time
        // (Model.js) — refresh()'s own in-flight guard above is the real
        // safeguard against overlap, this just avoids a low setting
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
