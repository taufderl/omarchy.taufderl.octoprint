.pragma library

// ---------------------------------------------------------------------
// OctoPrint — data model
//
// DATA SOURCE: a self-hosted OctoPrint instance's REST API
// (https://docs.octoprint.org/en/master/api/). Two endpoints, polled
// together each cycle:
//   GET /api/job     — job state text, progress %, time remaining, file name
//   GET /api/printer — tool/bed temperatures, connection flags
// Auth is a single "X-Api-Key" header (generated in OctoPrint's own
// Settings → API). No CORS setup needed on the OctoPrint side — CORS is
// a browser concept and requests here go through curl (see curlArgs()
// below), not a browser-style client.
//
// /api/printer returns 409 when the printer itself isn't connected (the
// OctoPrint *server* can be up with no printer attached/powered — the
// documented, expected state when nothing is printing) — that's treated
// as "not connected", not an error.
// ---------------------------------------------------------------------

// Restricts the configured host to a bare http(s) origin — scheme limited
// to http/https, no embedded userinfo ("user:pass@..."), no path/query/
// fragment beyond the origin. Anything else normalizes to "" (the same
// "not configured" state fetchStatus() already handles), so a malformed
// or hostile value can't reach either the authenticated XHR or the "open
// in browser" link with an unexpected scheme or target — both now derive
// from this single validated value instead of the raw setting.
var HOST_ORIGIN_RE = /^https?:\/\/[^\s@\/?#]+$/i

function normalizeHost(raw) {
    var s = String(raw || "").trim().replace(/\/+$/, "")
    return HOST_ORIGIN_RE.test(s) ? s : ""
}

// Per-state icon for the small inline indicator next to the state text in
// the panel body — NOT the widget's brand icon (that's the constant 🐙 in
// BarWidget.qml/Panel.qml, a nod to OctoPrint's own "Tentacle logo",
// kept fixed rather than swapped per state). No dedicated 3D-printer
// glyph exists in Unicode, so this uses ⚙ for "actively doing something
// mechanical" states rather than the paper-printer 🖨️.
var STATE_META = {
    "Printing": { icon: "⚙", color: "#50fa7b" },
    "Paused": { icon: "⏸", color: "#ffb86c" },
    "Pausing": { icon: "⏸", color: "#ffb86c" },
    "Cancelling": { icon: "🛑", color: "#ff5555" },
    "Error": { icon: "⚠", color: "#ff5555" },
    "Offline": { icon: "🔌", color: "#6272a4" },
    "Offline after error": { icon: "⚠", color: "#ff5555" },
    "Opening serial connection": { icon: "🔌", color: "#8be9fd" },
    "Operational": { icon: "✅", color: "#8be9fd" }
}

function stateMeta(stateText) {
    return STATE_META[stateText] || { icon: "🐙", color: "#f8f8f2" }
}

// job.state and job.job.file.name are OctoPrint-controlled (an attacker
// with write access to the instance — or a MITM of an unencrypted
// connection — can set either to an arbitrary string) and end up both in
// this panel's own Text elements and in the bar's tooltip string, the
// latter going through Omarchy's shared tooltip whose inner Text isn't
// ours to set textFormat on. Stripping angle brackets here means neither
// place can ever have a "<img src=...>"-style payload interpreted as
// markup, no matter how it's ultimately rendered.
function sanitizeField(v) {
    return String(v === undefined || v === null ? "" : v).replace(/[<>]/g, "")
}

function formatDuration(seconds) {
    if (seconds === null || seconds === undefined || seconds < 0 || isNaN(seconds)) return ""
    var s = Math.round(seconds)
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    if (h > 0) return h + "h " + m + "m"
    if (m > 0) return m + "m"
    return s + "s"
}

function formatTemp(v) {
    return v === null || v === undefined ? "--" : Math.round(v * 10) / 10 + "°"
}

// /api/job and /api/printer are small, fixed-shape JSON documents;
// anything wildly past that is either a broken proxy or a hostile/
// compromised endpoint, so this refuses to buffer/parse past a cap
// regardless of what Content-Length (if any) claims.
var MAX_RESPONSE_BYTES = 262144

// QML's own XMLHttpRequest has no way to abort mid-download: even with a
// Content-Length pre-check, a chunked (or falsely-labeled) response is
// still fully materialized into responseText before onreadystatechange
// ever reaches DONE, so a check made there runs after the damage is
// already done. curl's --max-filesize genuinely aborts the transfer
// itself once the byte count is exceeded, Content-Length or not — so
// requests go through a curl subprocess (via a QML Process — see
// BarWidget.qml) instead. Since callers need the real HTTP status (401/
// 403/409 are all meaningful, not just "it worked or it didn't"), -f
// isn't used; the status is appended to stdout instead and split off
// here.
var STATUS_SENTINEL = "\n@@OMARCHY_HTTP_STATUS@@"

function curlArgs(url, apiKey) {
    return ["curl", "-sS",
        "--proto", "=http,https", "--proto-redir", "=http,https",
        "--max-filesize", String(MAX_RESPONSE_BYTES),
        "--max-time", "8",
        "-H", "X-Api-Key: " + apiKey,
        "-w", STATUS_SENTINEL + "%{http_code}",
        "--", url]
}

// Turns one curl Process's (exitCode, stdout) into the same
// {data|error, status} shape getJson()'s XHR callback used to produce.
// 409 is returned as a status, not thrown away, so callers can
// distinguish "printer not connected" from a real failure.
function interpretCurlExit(exitCode, rawOutput) {
    if (exitCode === 63) return { data: null, error: "OctoPrint response too large", status: 0 }
    if (exitCode === 28) return { data: null, error: "OctoPrint request timed out", status: 0 }
    if (exitCode !== 0) return { data: null, error: "Could not reach OctoPrint", status: 0 }

    var idx = rawOutput.lastIndexOf(STATUS_SENTINEL)
    if (idx === -1) return { data: null, error: "Failed to parse OctoPrint response", status: 0 }
    var status = parseInt(rawOutput.slice(idx + STATUS_SENTINEL.length), 10) || 0
    var body = rawOutput.slice(0, idx)

    if (status === 200) {
        if (body.length > MAX_RESPONSE_BYTES) return { data: null, error: "OctoPrint response too large", status: status }
        try {
            return { data: JSON.parse(body), error: null, status: 200 }
        } catch (e) {
            return { data: null, error: "Failed to parse OctoPrint response", status: status }
        }
    } else if (status === 401 || status === 403) {
        return { data: null, error: "OctoPrint rejected the API key", status: status }
    } else if (status === 409) {
        return { data: null, error: "Printer not connected", status: 409 }
    } else {
        return { data: null, error: "OctoPrint error (" + status + ")", status: status }
    }
}

// Combines the /api/job + /api/printer curl results the same way
// fetchStatus() used to combine its two XHR callbacks: a 409 from either
// endpoint (printer not connected) is not fatal on its own.
function combineResults(jobResult, printerResult) {
    var fatalError = null
    if (jobResult.error && jobResult.status !== 409) fatalError = jobResult.error
    if (printerResult.error && printerResult.status !== 409) fatalError = fatalError || printerResult.error
    if (fatalError) return { status: null, error: fatalError }
    return { status: buildStatus(jobResult.data, printerResult.data), error: null }
}

// Combines /api/job + /api/printer into one status object. A 409 from
// either endpoint (printer not connected) is not treated as fatal — the
// resulting status just has less data (no temps, or a generic "Offline"
// state) rather than showing an error banner for a normal, expected state.
function buildStatus(job, printer) {
    var stateText = (job && job.state) ||
        (printer && printer.state && printer.state.text) ||
        "Offline"
    var meta = stateMeta(stateText)
    var flags = (printer && printer.state && printer.state.flags) || {}
    var progress = (job && job.progress) || {}
    var file = (job && job.job && job.job.file) || {}
    var tool0 = (printer && printer.temperature && printer.temperature.tool0) || null
    var bed = (printer && printer.temperature && printer.temperature.bed) || null

    return {
        stateText: sanitizeField(stateText),
        statusIcon: meta.icon,
        color: meta.color,
        printing: !!flags.printing,
        paused: !!(flags.paused || flags.pausing),
        error: !!(flags.error || flags.closedOrError),
        fileName: sanitizeField(file.name || ""),
        completion: (progress.completion === null || progress.completion === undefined) ? null : progress.completion,
        printTimeLeft: (progress.printTimeLeft === null || progress.printTimeLeft === undefined) ? null : progress.printTimeLeft,
        toolActual: tool0 ? tool0.actual : null,
        toolTarget: tool0 ? tool0.target : null,
        bedActual: bed ? bed.actual : null,
        bedTarget: bed ? bed.target : null
    }
}

// ---------------------------------------------------------------------
// Credentials file — ~/.local/state/omarchy/taufderl.octoprint/settings.json
//
// Read and write both go through a QML Process (see BarWidget.qml)
// running one of these small, argv-safe shell scripts rather than
// Quickshell.Io's FileView, for two reasons a FileView bound directly to
// the path can't address:
//
// - Read: FileView.text() materializes the whole file unconditionally.
//   This is a plugin-owned file under a directory only this plugin
//   writes to, but if it were ever replaced by something huge or a
//   non-regular special file (FIFO, device), a plain read would happily
//   buffer all of it or block on it. The read script stats the path
//   first and only execs `head -c <limit>` once it's confirmed to be a
//   regular file within bounds.
// - Write: FileView.setText() + a chmod 600 afterward (the previous
//   approach) leaves a real window where the just-written file exists at
//   whatever the default umask produces before the deferred chmod lands.
//   The write script sets `umask 077` before ever creating the temp
//   file, so it's mode 600 from its very first byte — the atomic rename
//   onto the final path carries that same mode with it, so there's no
//   separate chmod step left to race at all.
//
// Both pass the path (and, for writes, the JSON content) as their own
// argv element rather than interpolating them into the script text, so
// arbitrary bytes in either — quotes, `$()`, backticks, newlines — can
// never be read as shell syntax.
// ---------------------------------------------------------------------

var MAX_CREDENTIALS_BYTES = 16384

function readCredentialsArgs(path) {
    return ["sh", "-c",
        'info=$(stat -c "%s %F" -- "$1" 2>/dev/null) || exit 2\n' +
        'sz=${info%% *}\n' +
        'type=${info#* }\n' +
        '[ "$type" = "regular file" ] || exit 4\n' +
        '[ "$sz" -le "$2" ] || exit 4\n' +
        'exec head -c "$2" -- "$1"\n',
        "sh", path, String(MAX_CREDENTIALS_BYTES)]
}

function writeCredentialsArgs(path, jsonText) {
    return ["sh", "-c",
        'umask 077\n' +
        'tmp="$1.tmp.$$"\n' +
        'printf %s "$2" > "$tmp" || { rm -f -- "$tmp"; exit 1; }\n' +
        'mv -f -- "$tmp" "$1"\n',
        "sh", path, jsonText]
}
