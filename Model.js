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

// The API key is NOT passed via -H: curl puts every argv element
// (headers included) into the process's own command line, which any
// same-UID process can read for the process's whole lifetime via
// /proc/<pid>/cmdline or `ps` — confirmed locally, and exactly what
// moving the key out of shell.json was meant to avoid. curl reads the
// header from a --config file instead, which never appears in its argv.
// That config file's own content — built here — carries the key, so it
// goes to disk over stdin (see writeApiKeyConfigArgs() below and its
// caller in BarWidget.qml), not as an argv element either: the same
// /proc/<pid>/cmdline exposure applies to the *writing* process just as
// much as it would to curl.
// See writeApiKeyConfigArgs()/removeApiKeyConfigArgs() below for how
// that file itself is created (mode 600, inside the already-700 state
// directory, one-time-use path per fetch) and cleaned up.
function apiKeyConfigLine(apiKey) {
    var escaped = String(apiKey).replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
    return "header = \"X-Api-Key: " + escaped + "\"\n"
}

// Content comes in over stdin (the caller writes it via Process.write()
// after starting this, then disables stdinEnabled to signal EOF — see
// BarWidget.qml) rather than as an argv element, and lands via `mktemp`
// (atomically created, exclusive, mode 600 from the instant it exists)
// instead of a "$path.tmp.$$" name a local attacker could pre-place a
// symlink at, guessing the shell's own pid.
function writeApiKeyConfigArgs(path) {
    return ["sh", "-c",
        'umask 077\n' +
        'dir=$(dirname -- "$1") || exit 1\n' +
        'tmp=$(mktemp -- "$dir/.apikey.XXXXXX") || exit 1\n' +
        'cat > "$tmp" || { rm -f -- "$tmp"; exit 1; }\n' +
        'mv -f -- "$tmp" "$1"\n',
        "sh", path]
}

function removeApiKeyConfigArgs(path) {
    return ["rm", "-f", "--", path]
}

// Cleans up any apikey.*.curlconf left behind by a session that ended
// mid-fetch (crash, forced shell restart) — the normal path already
// removes its own file once both requests that used it finish (see
// maybeFinishFetch() in BarWidget.qml), this is only for that abnormal
// case. Safe to run unconditionally: matches only this plugin's own
// naming pattern, inside its own state directory.
function cleanupStaleApiKeyConfigsArgs(stateDir) {
    return ["sh", "-c", 'rm -f -- "$1"/apikey.*.curlconf', "sh", stateDir]
}

function curlArgs(url, apiKeyConfigPath) {
    return ["curl", "-sS",
        "--proto", "=http,https", "--proto-redir", "=http,https",
        "--max-filesize", String(MAX_RESPONSE_BYTES),
        "--max-time", "8",
        "--config", apiKeyConfigPath,
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
//   buffer all of it or block on it. The read script opens the path
//   exactly once (`exec 3<`) and stats *that file descriptor* (via
//   /proc/self/fd/3, not the path again) before reading from it — a
//   second stat-by-path, or a stat-then-reopen, would leave a window
//   where the path could be swapped (symlink, replaced file) between the
//   check and the read; stating the already-open fd can't be fooled that
//   way, since it's pinned to whatever was actually opened.
// - Write: FileView.setText() + a chmod 600 afterward (an earlier
//   approach) leaves a real window where the just-written file exists at
//   whatever the default umask produces before the deferred chmod lands.
//   The write script sets `umask 077` before creating anything, and uses
//   `mktemp` for the temp file — atomically created with an
//   unpredictable name and mode 600 from the instant it exists, unlike a
//   "$path.tmp.$$" name (the shell's own pid, guessable) that a local
//   attacker could pre-place a symlink at. The atomic rename onto the
//   final path carries that same mode with it, so there's no separate
//   chmod step left to race either.
//
// The path is its own argv element rather than interpolated into the
// script text, so arbitrary bytes in it — quotes, `$()`, backticks,
// newlines — can never be read as shell syntax. The secret content
// (JSON for the credentials file, the header line for the curl --config
// file) is never an argv element at all: argv is visible to any
// same-UID process for the writing process's whole lifetime via
// /proc/<pid>/cmdline or `ps`. It's delivered over stdin instead —
// callers write it via Process.write() after starting the write, then
// set stdinEnabled = false to signal EOF (see BarWidget.qml).
// ---------------------------------------------------------------------

var MAX_CREDENTIALS_BYTES = 16384

function readCredentialsArgs(path) {
    return ["sh", "-c",
        // $1 is untrusted: another local process could have replaced it
        // with a FIFO (an ordinary open blocks until a writer shows up,
        // hanging this script) or a symlink to some other file the user
        // can read (an ordinary open follows it transparently, and a
        // stat afterward only ever sees the target's genuine metadata —
        // there's no way to tell after the fact that a symlink was
        // involved at all).
        //
        // `[ -f "$1" ] && [ ! -L "$1" ]` rejects both up front: `-f`
        // requires it to resolve to a regular file, `! -L` requires $1
        // itself not be a symlink, so together $1 must *be* a regular
        // file rather than merely lead to one. Plain lstat/stat never
        // open()s, so this check itself can't be stalled.
        //
        // $1 could still be swapped between that check and the read, so
        // the read uses `dd iflag=nofollow,nonblock`: those map
        // straight to O_NOFOLLOW and O_NONBLOCK on dd's own open(2), so
        // a swap in that gap still can't be followed (ELOOP → dd fails,
        // caught below) or hung on (a FIFO opened O_NONBLOCK with no
        // writer returns EOF immediately instead of blocking).
        // `bs=$(($2 + 1))` with `count=1` bounds the read to one block
        // and, via the +1, makes an oversized source detectable from
        // the output size alone — stating $1 itself afterward would
        // just reopen it to the same races this is avoiding.
        //
        // The copy lands in our own mktemp'd file — not $1 — so the
        // size check and the final read below both act on something
        // this script alone created and named, with no path anyone
        // else can race.
        '[ -e "$1" ] || exit 2\n' +
        '[ -f "$1" ] && [ ! -L "$1" ] || exit 4\n' +
        'umask 077\n' +
        'dir=$(dirname -- "$1") || exit 4\n' +
        'tmp=$(mktemp -- "$dir/.settings-read.XXXXXX") || exit 4\n' +
        'trap \'rm -f -- "$tmp"\' EXIT\n' +
        'dd if="$1" of="$tmp" iflag=nofollow,nonblock bs=$(($2 + 1)) count=1 2>/dev/null || exit 4\n' +
        'sz=$(stat -c "%s" -- "$tmp") || exit 4\n' +
        '[ "$sz" -le "$2" ] || exit 4\n' +
        'cat -- "$tmp"\n',
        "sh", path, String(MAX_CREDENTIALS_BYTES)]
}

function writeCredentialsArgs(path) {
    return ["sh", "-c",
        'umask 077\n' +
        'dir=$(dirname -- "$1") || exit 1\n' +
        'tmp=$(mktemp -- "$dir/.settings.XXXXXX") || exit 1\n' +
        'cat > "$tmp" || { rm -f -- "$tmp"; exit 1; }\n' +
        'mv -f -- "$tmp" "$1"\n',
        "sh", path]
}
