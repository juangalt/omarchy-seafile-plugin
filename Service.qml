import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property string pluginDir: ""

  property bool installed: false
  property bool configured: false
  property bool running: false
  property bool snoozed: false
  property int snoozeUntil: 0
  property string snoozeLabel: ""
  property string aggregate: "missing"
  property string statusText: "Checking…"
  property int lastSyncTs: 0
  property var repos: []
  property var syncErrors: []
  property string logPath: ""
  property string worktreeParent: ""
  property string actionStatus: ""
  property string lastError: ""
  property bool refreshing: false

  // Optimistic pause/resume: -1 follow reality, 0 paused, 1 active.
  property int _desired: -1
  readonly property bool active: {
    if (_desired === -1) return running && !snoozed
    return _desired === 1
  }

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 3600)
  readonly property bool busy: statusProcess.running || controlProcess.running
  readonly property string helperPath: pluginDir !== "" ? (pluginDir + "/helper.py") : ""
  readonly property string setupPath: pluginDir !== "" ? (pluginDir + "/scripts/setup.sh") : ""

  property string _statusOutput: ""
  property string _controlOutput: ""
  property string _controlError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function elideStatus(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 160 ? value.substring(0, 157) + "…" : value
  }

  function fileUrlToPath(url) {
    var s = String(url || "")
    if (s.indexOf("file://") === 0) {
      s = s.substring(7)
      if (s.indexOf("//") === 0) s = s.substring(1)
      try { return decodeURIComponent(s) } catch (e) { return s }
    }
    return s
  }

  function refresh() {
    if (statusProcess.running || helperPath === "") return
    _statusOutput = ""
    refreshing = true
    statusProcess.command = ["python3", helperPath, "status"]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = "Failed to read Seafile status"
      return
    }
    installed = parsed.installed === true
    configured = parsed.configured === true
    running = parsed.running === true
    snoozed = parsed.snoozed === true
    snoozeUntil = Number(parsed.snoozeUntil || 0)
    snoozeLabel = String(parsed.snoozeLabel || "")
    aggregate = String(parsed.aggregate || "")
    statusText = String(parsed.statusText || "")
    lastSyncTs = Number(parsed.lastSyncTs || 0)
    repos = parsed.repos || []
    syncErrors = parsed.syncErrors || []
    logPath = String(parsed.logPath || "")
    worktreeParent = String(parsed.worktreeParent || "")
    if (_desired !== -1 && active === (_desired === 1)) _desired = -1
    lastError = ""
  }

  function runHelper(args, desired) {
    if (helperPath === "" || controlProcess.running) return
    if (desired !== undefined) _desired = desired
    _controlOutput = ""
    _controlError = ""
    controlProcess.command = ["python3", helperPath].concat(args)
    controlProcess.running = true
  }

  function pause() { runHelper(["pause"], 0) }
  function resume() { runHelper(["resume"], 1) }

  function toggleRunning() {
    if (!installed || busy) return
    if (active) pause()
    else resume()
  }

  function syncNow() {
    if (!installed || busy) return
    actionStatus = "Syncing…"
    runHelper(["sync-now"], 1)
  }

  function snooze(seconds, label) {
    if (!installed || busy) return
    actionStatus = "Snoozed"
    actionStatusTimer.restart()
    runHelper(["snooze", String(seconds), String(label)], 0)
  }

  function installPackage() {
    actionStatus = "Opening installer…"
    actionStatusTimer.restart()
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      "yay -S --needed seafile"
    ])
    delayedRefresh.restart()
  }

  function runSetup() {
    if (setupPath === "") return
    actionStatus = "Opening setup…"
    actionStatusTimer.restart()
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      "bash " + shellQuote(setupPath)
    ])
    delayedRefresh.restart()
  }

  function shellQuote(value) {
    return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
  }

  function openFolder(path) {
    var target = String(path || "")
    if (target === "" && repos.length > 0) target = String(repos[0].path || "")
    if (target === "") return
    Quickshell.execDetached(["xdg-open", target])
  }

  function openLogs() {
    var path = String(logPath || "")
    if (path === "") return
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      "less -R +G " + shellQuote(path)
    ])
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.helperPath !== ""
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: root.helperPath !== ""
    onTriggered: {
      ticks += 1
      if ((root.running && root.configured) || ticks >= 15) startupRamp.running = false
      else root.refresh()
    }
  }

  Timer {
    id: snoozeWatch
    interval: 30000
    repeat: true
    running: root.snoozed
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 1200
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1500
    repeat: true
    running: false
    onTriggered: {
      settleTimer.ticks += 1
      root.refresh()
      if (settleTimer.ticks >= 4) {
        settleTimer.ticks = 0
        settleTimer.running = false
        root._desired = -1
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
      onStreamFinished: root._statusOutput = text
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.lastError = root.elideStatus(stdout || "Failed to read Seafile status")
    }
  }

  Process {
    id: controlProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: controlStdout
      waitForEnd: true
      onStreamFinished: root._controlOutput = text
    }
    stderr: StdioCollector {
      id: controlStderr
      waitForEnd: true
      onStreamFinished: root._controlError = text
    }
    onExited: function(exitCode) {
      var stdout = String(controlStdout.text || root._controlOutput || "")
      var stderr = String(controlStderr.text || root._controlError || "")
      var message = ""
      try {
        var parsed = JSON.parse(stdout)
        if (parsed && parsed.error) message = String(parsed.error)
      } catch (e) {
        message = stderr || stdout
      }
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = root.elideStatus(message || "Something went wrong")
        root.actionStatus = root.lastError
      } else {
        root.lastError = ""
        if (root.actionStatus === "Syncing…") root.actionStatus = ""
      }
      settleTimer.ticks = 0
      settleTimer.restart()
      delayedRefresh.restart()
    }
  }

  onHelperPathChanged: {
    if (helperPath !== "") {
      refreshTimer.restart()
      refresh()
    }
  }
}
