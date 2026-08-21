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
// Settings → API). No CORS setup needed on the OctoPrint side — QML's
// XMLHttpRequest doesn't enforce browser-style same-origin restrictions,
// confirmed against two other unrelated cross-origin feeds while building
// other Omarchy plugins.
//
// /api/printer returns 409 when the printer itself isn't connected (the
// OctoPrint *server* can be up with no printer attached/powered — the
// documented, expected state when nothing is printing) — that's treated
// as "not connected", not an error.
// ---------------------------------------------------------------------

function normalizeHost(raw) {
    var s = String(raw || "").trim()
    return s.replace(/\/+$/, "")
}

// Per-state icon for the small inline indicator next to the state text in
// the panel body — NOT the widget's brand icon (that's the constant 🐙 in
// BarWidget.qml/Panel.qml, a nod to OctoPrint's actual "Tentacle logo"
// branding at octoprint.org, kept fixed rather than swapped per state —
// the same "logo stays put, color/text conveys status" pattern used by
// this shell's other bar widgets).
// No dedicated 3D-printer glyph exists in Unicode, so this deliberately
// avoids 🖨️ (a flat-paper printer — wrong device entirely) in favor of ⚙
// for "actively doing something mechanical" states.
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

// One XHR against one endpoint, normalized to (data, errorMessage, status).
// 409 is reported through the callback as a status, not thrown away, so
// callers can distinguish "printer not connected" from a real failure.
function getJson(url, apiKey, callback) {
    var xhr = new XMLHttpRequest()
    var settled = false
    xhr.open("GET", url)
    xhr.setRequestHeader("X-Api-Key", apiKey)
    xhr.timeout = 8000
    xhr.ontimeout = function() {
        if (settled) return
        settled = true
        callback(null, "OctoPrint request timed out", 0)
    }
    xhr.onreadystatechange = function() {
        if (xhr.readyState !== XMLHttpRequest.DONE) return
        if (settled) return
        settled = true
        if (xhr.status === 200) {
            try {
                callback(JSON.parse(xhr.responseText), null, 200)
            } catch (e) {
                callback(null, "Failed to parse OctoPrint response", xhr.status)
            }
        } else if (xhr.status === 401 || xhr.status === 403) {
            callback(null, "OctoPrint rejected the API key", xhr.status)
        } else if (xhr.status === 409) {
            callback(null, "Printer not connected", 409)
        } else if (xhr.status === 0) {
            callback(null, "Could not reach OctoPrint", 0)
        } else {
            callback(null, "OctoPrint error (" + xhr.status + ")", xhr.status)
        }
    }
    xhr.send()
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
        stateText: stateText,
        statusIcon: meta.icon,
        color: meta.color,
        printing: !!flags.printing,
        paused: !!(flags.paused || flags.pausing),
        error: !!(flags.error || flags.closedOrError),
        fileName: file.name || "",
        completion: (progress.completion === null || progress.completion === undefined) ? null : progress.completion,
        printTimeLeft: (progress.printTimeLeft === null || progress.printTimeLeft === undefined) ? null : progress.printTimeLeft,
        toolActual: tool0 ? tool0.actual : null,
        toolTarget: tool0 ? tool0.target : null,
        bedActual: bed ? bed.actual : null,
        bedTarget: bed ? bed.target : null
    }
}

function fetchStatus(host, apiKey, callback) {
    var base = normalizeHost(host)
    if (base === "") {
        callback(null, "No OctoPrint host configured")
        return
    }
    if (String(apiKey || "").trim() === "") {
        callback(null, "No OctoPrint API key configured")
        return
    }

    var jobData = null
    var printerData = null
    var pending = 2
    var settled = false
    var fatalError = null

    function finish() {
        pending--
        if (pending > 0 || settled) return
        settled = true
        if (fatalError) {
            callback(null, fatalError)
            return
        }
        callback(buildStatus(jobData, printerData), null)
    }

    getJson(base + "/api/job", apiKey, function(data, err, status) {
        if (err) {
            if (status !== 409) fatalError = err
        } else {
            jobData = data
        }
        finish()
    })

    getJson(base + "/api/printer", apiKey, function(data, err, status) {
        if (err) {
            if (status !== 409) fatalError = err
        } else {
            printerData = data
        }
        finish()
    })
}
