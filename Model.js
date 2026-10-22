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

function formatter(fmt) {
  return typeof fmt === "function" ? fmt : function(v) { return String(v) }
}

function relativeTime(timestampSec, nowMs, fmt) {
  var f = formatter(fmt)
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return ""
  var now = nowMs === undefined || nowMs === null ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ts * 1000) / 1000))
  if (diff < 60) return "just now"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return f(minutes) + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return f(hours) + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return f(days) + "d ago"
  return f(Math.floor(days / 30)) + "mo ago"
}

function heroMeta(status, strings, fmt) {
  if (!status) return ""
  if (status.snoozed) {
    var until = Number(status.snoozeUntil || 0)
    var label = String(status.snoozeLabel || "")
    if (until > 0) {
      var mins = Math.max(1, Math.ceil((until * 1000 - Date.now()) / 60000))
      return (label ? label + " · " : "") + formatter(fmt)(mins) + "m left"
    }
    return label || strings.t("meta.snoozed")
  }
  if (!status.installed) return strings.t("meta.notInstalled")
  if (!status.configured) return strings.t("meta.notConfigured")
  if (status.aggregate === "needs-resync") return strings.t("meta.needsResync")
  if (!status.active) return strings.t("meta.paused")

  var parts = []
  var text = String(status.statusText || "")
  if (text !== "") parts.push(text)
  var rel = relativeTime(status.lastSyncTs, undefined, fmt)
  if (rel !== "" && status.aggregate === "synchronized") parts.push(rel)
  if (status.aggregate === "error" && status.syncErrors && status.syncErrors.length > 0) {
    var err = status.syncErrors[0]
    var errText = String((err && (err.error || err.path)) || "")
    if (errText !== "") parts.push(errText)
  }
  return parts.join(" · ")
}

function primaryPath(status) {
  if (!status || !status.repos || status.repos.length === 0) return ""
  return String(status.repos[0].path || "")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus,
    defaultStatus: defaultStatus,
    relativeTime: relativeTime,
    heroMeta: heroMeta,
    primaryPath: primaryPath
  }
}
