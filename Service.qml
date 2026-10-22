import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  // Filesystem path or file URL of the plugin directory. Resolved below.
  property string pluginDir: ""

  property bool installed: false
  property bool configured: false
  property bool running: false
  property bool snoozed: false
  property int snoozeUntil: 0
  property string snoozeLabel: ""
  property bool runningDespiteSnooze: false
  property string aggregate: "missing"
  // IPC status() reads this, so it stays the helper's English text.
  property string statusText: "Checking…"
  property int lastSyncTs: 0
  property var repos: []
  property var syncErrors: []
  property string logPath: ""
  property string worktreeParent: ""
  property string detail: ""
  property string actionStatus: ""
  property string lastError: ""
  property bool refreshing: false

  // Optimistic pause/resume: -1 follow reality, 0 paused, 1 active.
  property int _desired: -1
  property bool _pendingSync: false
  readonly property bool active: {
    if (_desired === -1) return running && (!snoozed || runningDespiteSnooze)
    return _desired === 1
  }

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 3600)
  readonly property bool busy: helperBusy
  readonly property string pluginPath: Model.fileUrlToPath(pluginDir)
  readonly property bool pluginPathAbsolute: pluginPath.length > 0 && pluginPath.charAt(0) === "/"
  readonly property string helperPath: pluginPathAbsolute ? (pluginPath + "/helper.py") : ""
  readonly property string setupPath: pluginPathAbsolute ? (pluginPath + "/scripts/setup.sh") : ""
  // Set only after FileView confirms helper.py. A relative or missing path never runs.
  property bool helperFileOk: false
  readonly property bool helperReady: pluginPathAbsolute && helperPath !== "" && helperFileOk

  property string _statusOutput: ""
  property string _controlOutput: ""
  property string _controlError: ""
  // Set before spawning control so a timer refresh cannot sneak in between
  // the busy check and controlProcess.running = true.
  property bool _controlClaimed: false
  readonly property bool helperBusy: statusProcess.running || controlProcess.running || _controlClaimed

  Commons.Translations {
    id: strings
    directory: root.pluginPathAbsolute ? root.pluginPath + "/i18n" : ""
  }

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

  function tr(key, fallback) {
    return strings.t(key, fallback)
  }

  function refresh() {
    // Never overlap status with control: status while snoozed can stop_daemon()
    // and race sync-now/resume that just started the daemon.
    if (helperBusy || !helperReady) return
    _statusOutput = ""
    refreshing = true
    statusProcess.command = ["python3", helperPath, "status"]
    statusProcess.running = true
  }

  function noteBusy() {
    actionStatus = tr("action.busy", "Busy…")
    actionStatusTimer.restart()
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = tr("statusParseFailed", "Failed to read Seafile status")
      return
    }
    installed = parsed.installed === true
    configured = parsed.configured === true
    running = parsed.running === true
    snoozed = parsed.snoozed === true
    snoozeUntil = Number(parsed.snoozeUntil || 0)
    snoozeLabel = String(parsed.snoozeLabel || "")
    runningDespiteSnooze = parsed.runningDespiteSnooze === true
    aggregate = String(parsed.aggregate || "")
    statusText = String(parsed.statusText || "")
    lastSyncTs = Number(parsed.lastSyncTs || 0)
    repos = parsed.repos || []
    syncErrors = parsed.syncErrors || []
    logPath = String(parsed.logPath || "")
    worktreeParent = String(parsed.worktreeParent || "")
    detail = String(parsed.detail || "")
    var realityActive = running && (!snoozed || runningDespiteSnooze)
    if (_desired !== -1 && realityActive === (_desired === 1)) _desired = -1
    lastError = ""
  }

  function runHelper(args, desired) {
    if (!helperReady || helperBusy) return false
    _controlClaimed = true
    if (desired !== undefined) _desired = desired
    _controlOutput = ""
    _controlError = ""
    controlProcess.command = ["python3", helperPath].concat(args)
    controlProcess.running = true
    return true
  }

  function pause() { runHelper(["pause"], 0) }
  function resume() { runHelper(["resume"], 1) }

  function toggleRunning() {
    if (!installed || !helperReady) return
    if (busy) { noteBusy(); return }
    if (active) pause()
    else resume()
  }

  function syncNow() {
    if (!installed || !helperReady) return
    if (busy) { noteBusy(); return }
    actionStatusTimer.stop()
    _pendingSync = true
    actionStatus = tr("action.syncing", "Syncing…")
    if (!runHelper(["sync-now"], 1)) {
      _pendingSync = false
      noteBusy()
    }
  }

  function snooze(seconds, label) {
    if (!installed || !helperReady) return
    if (busy) { noteBusy(); return }
    actionStatus = tr("action.snoozed", "Snoozed")
    actionStatusTimer.restart()
    runHelper(["snooze", String(seconds), String(label)], 0)
  }

  function installPackage() {
    actionStatus = tr("action.installing", "Opening installer…")
    actionStatusTimer.restart()
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      "yay -S --needed seafile"
    ])
    delayedRefresh.restart()
  }

  function runSetup() {
    if (setupPath === "") return
    actionStatus = tr("action.setup", "Opening setup…")
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
    var explicit = arguments.length > 0
    var target = String(path || "")
    if (target === "" && !explicit && repos.length > 0)
      target = String(repos[0].path || "")
    if (target.charAt(0) !== "/") return
    Quickshell.execDetached(["xdg-open", target])
  }

  function openLogs() {
    var path = String(logPath || "")
    if (path.charAt(0) !== "/") return
    var quoted = shellQuote(path)
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      "bash -lc " + shellQuote(
        "if [ -f " + quoted + " ]; then less +G " + quoted + "; "
        + "else echo 'No Seafile log yet.'; echo " + quoted + "; read -n1 -s; fi"
      )
    ])
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.helperReady
    // First hit comes from startupRamp to avoid a double status probe at launch.
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  Timer {
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: root.helperReady
    triggeredOnStart: true
    onTriggered: {
      ticks += 1
      root.refresh()
      if ((root.running && root.configured) || ticks >= 15) startupRamp.running = false
    }
  }

  Timer {
    id: snoozeWatch
    interval: 30000
    repeat: true
    running: root.snoozed && root.helperReady
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

  FileView {
    id: helperFile
    path: root.helperPath
    watchChanges: true
    printErrors: false
    onPathChanged: root.helperFileOk = false
    onLoaded: {
      var seen = String(path || "")
      Qt.callLater(function() {
        root.helperFileOk = seen !== "" && seen === root.helperPath
      })
    }
    onLoadFailed: root.helperFileOk = false
    onFileChanged: reload()
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
      else root.lastError = root.elideStatus(stdout || root.tr("statusParseFailed", "Failed to read Seafile status"))
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
      root._controlClaimed = false
      var stdout = String(controlStdout.text || root._controlOutput || "")
      var stderr = String(controlStderr.text || root._controlError || "")
      var message = ""
      var parsedOk = false
      var syncPayload = null
      try {
        syncPayload = JSON.parse(stdout)
        message = Model.controlMessage(syncPayload)
        parsedOk = true
      } catch (e) {
        message = String(stderr || stdout || "").trim()
      }
      if (parsedOk && message === "" && exitCode !== 0)
        message = String(stderr || "").trim()
      var failed = parsedOk ? (exitCode !== 0 || message !== "") : (exitCode !== 0)
      var wasSync = root._pendingSync
      root._pendingSync = false
      if (failed) {
        root.actionStatusTimer.stop()
        root._desired = -1
        root.lastError = root.elideStatus(message || root.tr("action.failed", "Something went wrong"))
        root.actionStatus = root.lastError
      } else {
        root.lastError = ""
        if (wasSync) {
          var synced = syncPayload ? Number(syncPayload.synced || 0) : -1
          if (synced === 0) {
            root.actionStatus = root.tr("action.nothingToSync", "No libraries to sync")
            root.actionStatusTimer.restart()
          } else {
            // RPC accepted — keep a soft status until settle refreshes catch up.
            root.actionStatus = root.tr("action.syncRequested", "Sync requested…")
            root.actionStatusTimer.restart()
          }
        }
      }
      settleTimer.ticks = 0
      settleTimer.restart()
      delayedRefresh.restart()
    }
  }
}
