const assert = require("assert")
const Model = require("../Model.js")

function t(key, fallback) {
  return fallback || key
}

function fmt(n) {
  return String(n)
}

// Paths
assert.strictEqual(Model.fileUrlToPath("file:///home/felipe/plugin/"), "/home/felipe/plugin")
assert.strictEqual(Model.fileUrlToPath("file://localhost/home/felipe/plugin"), "/home/felipe/plugin")
assert.strictEqual(Model.fileUrlToPath("/already/absolute"), "/already/absolute")
assert.strictEqual(Model.fileUrlToPath("file://host/path"), "")
assert.strictEqual(Model.fileUrlToPath("relative/path"), "")
assert.strictEqual(Model.fileUrlToPath("file:///tmp/x\ny"), "")

// controlMessage
const joined = Model.controlMessage({
  error: "top",
  errors: ["a", "b"],
})
assert.ok(joined.includes("top"))
assert.ok(joined.includes("a"))
assert.strictEqual(Model.controlMessage({ ok: true, synced: 1 }), "")

// heroMeta branches
const needsResync = Model.heroMeta(
  {
    installed: true,
    configured: true,
    active: true,
    aggregate: "needs-resync",
    statusText: "Needs re-attach",
    lastSyncTs: 0,
    syncErrors: [],
  },
  { t },
  fmt
)
assert.ok(String(needsResync).toLowerCase().includes("unbound") || String(needsResync).includes("Connect"))

const snoozeMeta = Model.heroMeta(
  {
    installed: true,
    configured: true,
    active: false,
    snoozed: true,
    snoozeUntil: Math.floor(Date.now() / 1000) + 900,
    snoozeLabel: "15 minutes",
    aggregate: "snoozed",
    statusText: "Snoozed",
    lastSyncTs: 0,
    syncErrors: [],
  },
  { t },
  fmt
)
assert.ok(String(snoozeMeta).includes("15 minutes"))
assert.ok(String(snoozeMeta).includes("left"))

const despite = Model.heroMeta(
  {
    installed: true,
    configured: true,
    active: true,
    snoozed: true,
    runningDespiteSnooze: true,
    snoozeUntil: Math.floor(Date.now() / 1000) + 600,
    aggregate: "synchronized",
    statusText: "Synchronized",
    lastSyncTs: 0,
    syncErrors: [],
  },
  { t },
  fmt
)
assert.ok(String(despite).toLowerCase().includes("still running"))

const errMeta = Model.heroMeta(
  {
    installed: true,
    configured: true,
    active: true,
    aggregate: "error",
    statusText: "Error",
    lastSyncTs: 0,
    syncErrors: [{ error: "Download permission denied" }],
  },
  { t },
  fmt
)
assert.ok(String(errMeta).includes("Download permission denied"))

console.log("model.test.js ok")
