function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultStatus()
    parsed.repos = Array.isArray(parsed.repos) ? parsed.repos : []
    parsed.syncErrors = Array.isArray(parsed.syncErrors) ? parsed.syncErrors : []
    return parsed
  } catch (e) {
    var failed = defaultStatus()
    failed.ok = false
    return failed
  }
}

function defaultStatus() {
  return {
    ok: true,
    installed: false,
    configured: false,
    running: false,
    active: false,
    snoozed: false,
    snoozeUntil: 0,
    snoozeLabel: "",
    runningDespiteSnooze: false,
    aggregate: "missing",
    statusText: "Unavailable",
    lastSyncTs: 0,
    repos: [],
    syncErrors: [],
    logPath: "",
    worktreeParent: "",
    detail: ""
  }
}

// file:///abs and file://localhost/abs become /abs. Anything else that is
// not already an absolute path is rejected so the helper is never launched
// against a host-qualified or relative location.
function fileUrlToPath(url) {
  var value = String(url || "").trim()
  if (value.indexOf("file://") === 0) {
    var rest = value.substring(7)
    if (rest.length >= 10 && rest.substring(0, 10).toLowerCase() === "localhost/")
      rest = rest.substring(9)
    if (rest.charAt(0) !== "/") return ""
    try { rest = decodeURIComponent(rest) } catch (e) {}
    if (rest.charAt(0) !== "/") return ""
    value = rest
  }
  if (value.indexOf("\0") !== -1 || value.indexOf("\n") !== -1 || value.indexOf("\r") !== -1)
    return ""
  while (value.length > 1 && value.charAt(value.length - 1) === "/")
    value = value.substring(0, value.length - 1)
  return value
}

function translator(tr) {
  if (typeof tr === "function") return tr
  if (tr && typeof tr.t === "function") return function(key, fallback) { return tr.t(key, fallback) }
  return function(key, fallback) { return fallback !== undefined ? fallback : key }
}

function formatter(fmt) {
  return typeof fmt === "function" ? fmt : function(v) { return String(v) }
}

function clip(text, max) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  if (value.length > max) return value.substring(0, max - 1) + "…"
  return value
}

function relativeTime(timestampSec, nowMs, tr, fmt) {
  var t = translator(tr)
  var f = formatter(fmt)
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return ""
  var now = nowMs === undefined || nowMs === null ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ts * 1000) / 1000))
  if (diff < 60) return t("meta.justNow", "Just now")
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return t("meta.minutesAgo", "%1m ago").replace("%1", f(minutes))
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return t("meta.hoursAgo", "%1h ago").replace("%1", f(hours))
  var days = Math.floor(hours / 24)
  if (days < 30) return t("meta.daysAgo", "%1d ago").replace("%1", f(days))
  return t("meta.monthsAgo", "%1mo ago").replace("%1", f(Math.floor(days / 30)))
}

function minutesLeft(untilSec, nowMs, fmt) {
  var until = Number(untilSec || 0)
  if (!isFinite(until) || until <= 0) return ""
  var now = nowMs === undefined || nowMs === null ? Date.now() : Number(nowMs)
  var remaining = until * 1000 - now
  if (remaining <= 0) return ""
  return formatter(fmt)(Math.max(1, Math.ceil(remaining / 60000)))
}

function heroMeta(status, tr, fmt) {
  if (!status) return ""
  var t = translator(tr)
  var f = formatter(fmt)

  if (status.runningDespiteSnooze) {
    var leftDespite = minutesLeft(status.snoozeUntil, undefined, f)
    if (leftDespite !== "")
      return t("meta.runningDespiteSnoozeLeft", "Sync still running · %1m left").replace("%1", leftDespite)
    return t("meta.runningDespiteSnooze", "Sync still running")
  }

  if (status.snoozed) {
    var left = minutesLeft(status.snoozeUntil, undefined, f)
    var label = clip(status.snoozeLabel, 40)
    if (left !== "") {
      if (label !== "")
        return t("meta.snoozeLabelLeft", "%1 · %2m left").replace("%2", left).replace("%1", label)
      return t("meta.minutesLeft", "%1m left").replace("%1", left)
    }
    return label || t("meta.snoozed", "Snoozed")
  }

  if (!status.installed) return t("meta.notInstalled", "Install seaf-cli to get started")

  var aggregate = String(status.aggregate || "")
  var detail = clip(status.detail, 80)

  if (aggregate === "needs-resync") return t("meta.needsResync", "Library unbound — open Connect / repair")
  if (aggregate === "unreachable") {
    if (detail !== "") return t("meta.unreachableDetail", "Unreachable · %1").replace("%1", detail)
    return t("meta.unreachable", "Unreachable")
  }
  if (aggregate === "unknown") {
    if (detail !== "") return t("meta.unknownDetail", "Unknown · %1").replace("%1", detail)
    return t("meta.unknown", "Unknown")
  }
  if (aggregate === "error") {
    var errText = ""
    if (status.syncErrors && status.syncErrors.length > 0) {
      var err = status.syncErrors[0]
      errText = clip((err && (err.error || err.path)) || "", 80)
    }
    if (errText !== "") return t("meta.errorDetail", "Error · %1").replace("%1", errText)
    return t("meta.error", "Error")
  }
  if (!status.configured || aggregate === "setup") return t("meta.notConfigured", "Connect your Seafile server")
  if (!status.active || aggregate === "paused") return t("meta.paused", "Syncing paused")
  if (aggregate === "idle") return t("meta.idle", "No libraries")
  if (aggregate === "synchronized") {
    var rel = relativeTime(status.lastSyncTs, undefined, t, f)
    if (rel !== "") return t("meta.synchronizedAgo", "Synchronized · %1").replace("%1", rel)
    return t("meta.synchronized", "Synchronized")
  }
  if (aggregate === "syncing") return t("meta.syncing", "Syncing")
  if (aggregate === "waiting") return t("meta.waiting", "Waiting")

  var fallback = clip(status.statusText, 80)
  return fallback
}

var LIBRARY_STATES = {
  "synchronized": ["state.synchronized", "Synchronized"],
  "uploading": ["state.uploading", "Uploading"],
  "downloading": ["state.downloading", "Downloading"],
  "committing": ["state.committing", "Committing"],
  "fetch": ["state.fetch", "Fetching"],
  "initializing": ["state.initializing", "Initializing"],
  "waiting for sync": ["state.waiting", "Waiting"],
  "auto sync disabled": ["state.autoSyncDisabled", "Auto sync disabled"],
  "error": ["state.error", "Error"],
  "daemon stopped": ["state.daemonStopped", "Daemon stopped"],
  "unreachable": ["state.unreachable", "Unreachable"],
  "unknown": ["state.unknown", "Unknown"]
}

function libraryStateLabel(state, tr) {
  var value = String(state || "")
  var mapped = LIBRARY_STATES[value]
  if (!mapped) return value
  return translator(tr)(mapped[0], mapped[1])
}

function libraryMeta(repo, tr) {
  if (!repo) return ""
  var parts = []
  var state = libraryStateLabel(repo.state, tr)
  if (state !== "") parts.push(state)
  var path = String(repo.path || "")
  if (path !== "") parts.push(path)
  return parts.join(" · ")
}

function libraryError(repo) {
  if (!repo) return ""
  return String(repo.error || "").replace(/\s+/g, " ").trim()
}

function controlMessage(parsed) {
  if (!parsed || typeof parsed !== "object") return ""
  var items = []
  function push(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    if (value === "" || items.indexOf(value) !== -1) return
    items.push(value)
  }
  if (Array.isArray(parsed.errors)) {
    for (var i = 0; i < parsed.errors.length; i++) {
      var item = parsed.errors[i]
      if (item && typeof item === "object") push(item.error || item.message || "")
      else push(item)
    }
  }
  var fromError = String(parsed.error || "").replace(/\s+/g, " ").trim()
  if (fromError === "") return items.join("; ")
  if (items.length === 0) return fromError
  var extra = []
  for (var j = 0; j < items.length; j++) {
    if (fromError.indexOf(items[j]) === -1) extra.push(items[j])
  }
  if (extra.length === 0) return fromError
  return fromError + "; " + extra.join("; ")
}

function primaryPath(status) {
  if (!status || !status.repos || status.repos.length === 0) return ""
  return String(status.repos[0].path || "")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus,
    defaultStatus: defaultStatus,
    fileUrlToPath: fileUrlToPath,
    relativeTime: relativeTime,
    heroMeta: heroMeta,
    libraryStateLabel: libraryStateLabel,
    libraryMeta: libraryMeta,
    libraryError: libraryError,
    controlMessage: controlMessage,
    primaryPath: primaryPath
  }
}
