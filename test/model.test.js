const assert = require("assert")
const Model = require("../Model.js")

function t(key, fallback) {
  return fallback || key
}

assert.strictEqual(Model.fileUrlToPath("file:///home/felipe/plugin/"), "/home/felipe/plugin")
assert.strictEqual(Model.fileUrlToPath("file://localhost/home/felipe/plugin"), "/home/felipe/plugin")
assert.strictEqual(Model.fileUrlToPath("/already/absolute"), "/already/absolute")

const joined = Model.controlMessage({
  error: "top",
  errors: ["a", "b"],
})
assert.ok(joined.includes("top"))
assert.ok(joined.includes("a"))

const meta = Model.heroMeta(
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
  (n) => String(n)
)
assert.ok(String(meta).length > 0)

console.log("model.test.js ok")
