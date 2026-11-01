import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "juangalt.seafile"
  ipcTarget: "juangalt.seafile"
  manageIpc: false

  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null
  readonly property Item hero: panel.loadedContent ? panel.loadedContent.hero : null
  readonly property Item libraryColumn: panel.loadedContent ? panel.loadedContent.libraryColumn : null

  Commons.Translations {
    id: strings
    directory: root.pluginDir.charAt(0) === "/" ? root.pluginDir + "/i18n" : Qt.resolvedUrl("i18n")
  }

  readonly property string pluginDir: Model.fileUrlToPath(String(Qt.resolvedUrl(".")))

  property string focusSection: "setup"
  property int actionIndex: 0
  property int moreIndex: 0
  property int libraryIndex: 0
  property bool cursorActive: false
  property bool moreOpen: false
  property bool syncSettingsOpen: false
  property string syncSettingsRepoId: ""
  // back | auto | interval
  property string syncFocus: "auto"
  property int syncIntervalIndex: 0
  // Ticking clock so relative "Just now" / snooze countdowns re-evaluate.
  property double nowMs: Date.now()

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool attention: {
    var aggregate = seafile.aggregate
    return aggregate === "error" || aggregate === "needs-resync" || aggregate === "unreachable"
  }
  readonly property color iconColor: {
    if (!seafile.installed || !seafile.configured) return dim
    if (root.attention) return urgent
    if (seafile.active) return foreground
    return dim
  }
  readonly property color barIconColor: {
    if (!seafile.installed || !seafile.configured) return Qt.darker(barForeground, 1.55)
    if (root.attention) return urgent
    if (seafile.active) return barForeground
    return Qt.darker(barForeground, 1.55)
  }
  readonly property string toggleHint: seafile.active ? strings.t("pauseSyncing") : strings.t("resumeSyncing")
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && seafile.installed && seafile.configured
  readonly property string heroMetaText: {
    var _lang = strings.language
    var _now = root.nowMs
    return Model.heroMeta({
      installed: seafile.installed,
      configured: seafile.configured,
      active: seafile.active,
      snoozed: seafile.snoozed,
      snoozeUntil: seafile.snoozeUntil,
      snoozeLabel: seafile.snoozeLabel,
      runningDespiteSnooze: seafile.runningDespiteSnooze,
      statusText: seafile.statusText,
      lastSyncTs: seafile.lastSyncTs,
      aggregate: seafile.aggregate,
      syncErrors: seafile.syncErrors,
      detail: seafile.detail,
      nowMs: _now
    }, root.tr, Commons.I18n.formatNumber)
  }

  readonly property var primaryActions: {
    var items = []
    if (seafile.installed && seafile.configured) {
      items.push({ id: "sync", label: strings.t("syncNow"), icon: "󰑓" })
      items.push({ id: "folder", label: strings.t("openFolder"), icon: "󰉋" })
    }
    return items
  }

  readonly property var moreActions: {
    var items = []
    if (seafile.installed && seafile.configured) {
      if (seafile.repos.length > 0)
        items.push({ id: "syncSettings", label: strings.t("syncSettings"), icon: "󰒓" })
      items.push({ id: "snooze15", label: strings.t("snooze15"), icon: "󰒲" })
      items.push({ id: "snooze1h", label: strings.t("snooze1h"), icon: "󰒲" })
      if (seafile.snoozed)
        items.push({ id: "snoozeClear", label: strings.t("snoozeClear"), icon: "󰚭" })
      items.push({ id: "logs", label: strings.t("showLogs"), icon: "󰌱" })
      items.push({ id: "setup", label: strings.t("setup"), icon: "󰌾" })
    }
    return items
  }

  readonly property var syncSettingsRepo: {
    var rid = String(root.syncSettingsRepoId || "")
    if (rid === "") return null
    for (var i = 0; i < seafile.repos.length; i++) {
      var repo = seafile.repos[i]
      if (repo && String(repo.id || "") === rid) return repo
    }
    return null
  }

  readonly property var syncIntervalChoices: {
    var presets = Model.syncIntervalPresets()
    var repo = root.syncSettingsRepo
    var sec = repo ? Number(repo.syncIntervalSec || 0) : 0
    if (!isFinite(sec) || sec < 0) sec = 0
    if (Model.presetIndexForInterval(sec) < 0 && sec > 0) {
      presets = presets.slice()
      presets.push({
        id: "current",
        seconds: Math.floor(sec),
        key: "sync.everySeconds",
        fallback: "Every %1s"
      })
    }
    return presets
  }

  function tr(key, fallback) {
    return strings.t(key, fallback)
  }

  function ensureCursor() {
    if (!seafile.installed || !seafile.configured) {
      focusSection = "setup"
      actionIndex = 0
      moreIndex = 0
      libraryIndex = 0
      syncSettingsOpen = false
      return
    }
    if (syncSettingsOpen) {
      if (!syncSettingsRepo) {
        syncSettingsOpen = false
        focusSection = "header"
      } else {
        focusSection = "sync"
        if (syncIntervalIndex >= syncIntervalChoices.length)
          syncIntervalIndex = Math.max(0, syncIntervalChoices.length - 1)
      }
      return
    }
    if (focusSection === "setup") focusSection = "header"
    if (focusSection === "sync") focusSection = "header"
    if (focusSection === "libraries" && seafile.repos.length === 0) focusSection = "header"
    if (focusSection === "actions" && primaryActions.length === 0) focusSection = "header"
    if (focusSection === "more" && (!moreOpen || moreActions.length === 0)) focusSection = "header"
    if (libraryIndex >= seafile.repos.length) libraryIndex = Math.max(0, seafile.repos.length - 1)
    if (actionIndex >= primaryActions.length) actionIndex = Math.max(0, primaryActions.length - 1)
    if (moreIndex >= moreActions.length) moreIndex = Math.max(0, moreActions.length - 1)
  }

  function openSyncSettings(repoId) {
    if (!seafile.installed || !seafile.configured || seafile.repos.length === 0) return
    var id = String(repoId || "")
    if (id === "") {
      if (focusSection === "libraries" && libraryIndex >= 0 && libraryIndex < seafile.repos.length)
        id = String((seafile.repos[libraryIndex] && seafile.repos[libraryIndex].id) || "")
      if (id === "") id = String((seafile.repos[0] && seafile.repos[0].id) || "")
    }
    if (id === "") return
    syncSettingsRepoId = id
    syncSettingsOpen = true
    moreOpen = false
    cursorActive = true
    focusSection = "sync"
    syncFocus = "auto"
    var repo = null
    for (var i = 0; i < seafile.repos.length; i++) {
      if (String((seafile.repos[i] && seafile.repos[i].id) || "") === id) {
        repo = seafile.repos[i]
        break
      }
    }
    var sec = repo ? Number(repo.syncIntervalSec || 0) : 0
    if (!isFinite(sec) || sec < 0) sec = 0
    var preset = Model.presetIndexForInterval(sec)
    if (preset >= 0) syncIntervalIndex = preset
    else if (sec > 0) syncIntervalIndex = Model.syncIntervalPresets().length
    else syncIntervalIndex = 0
    if (panelFlick) panelFlick.contentY = 0
  }

  function closeSyncSettings() {
    syncSettingsOpen = false
    focusSection = "more"
    moreOpen = true
    moreIndex = 0
    cursorActive = true
  }

  function intervalChoiceLabel(choice) {
    if (!choice) return ""
    var label = strings.t(choice.key, choice.fallback)
    if (String(choice.id || "") === "current" || String(choice.key || "") === "sync.everySeconds")
      return label.replace("%1", String(choice.seconds || 0))
    return label
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return

    if (focusSection === "setup") return

    if (focusSection === "sync") {
      if (syncFocus === "back") {
        if (dy > 0) syncFocus = "auto"
      } else if (syncFocus === "auto") {
        if (dy < 0) syncFocus = "back"
        else if (dy > 0) {
          syncFocus = "interval"
          if (syncIntervalIndex < 0) syncIntervalIndex = 0
        }
      } else if (syncFocus === "interval") {
        if (dy < 0 && syncIntervalIndex <= 0) {
          syncFocus = "auto"
          syncIntervalIndex = 0
        } else {
          syncIntervalIndex = Math.max(0, Math.min(syncIntervalChoices.length - 1, syncIntervalIndex + dy))
        }
      }
      return
    }

    if (focusSection === "header") {
      if (dy > 0) {
        if (seafile.repos.length > 0) {
          focusSection = "libraries"
          libraryIndex = 0
        } else if (primaryActions.length > 0) {
          focusSection = "actions"
          actionIndex = 0
        }
      }
      scrollCursorIntoView()
      return
    }

    if (focusSection === "libraries") {
      if (dy < 0 && libraryIndex === 0) {
        focusSection = "header"
        scrollCursorIntoView()
        return
      }
      if (dy > 0 && libraryIndex >= seafile.repos.length - 1) {
        if (primaryActions.length > 0) {
          focusSection = "actions"
          actionIndex = 0
        }
        scrollCursorIntoView()
        return
      }
      libraryIndex = Math.max(0, Math.min(seafile.repos.length - 1, libraryIndex + dy))
      scrollCursorIntoView()
      return
    }

    if (focusSection === "actions") {
      if (dy < 0 && actionIndex === 0) {
        if (seafile.repos.length > 0) {
          focusSection = "libraries"
          libraryIndex = seafile.repos.length - 1
        } else {
          focusSection = "header"
        }
        scrollCursorIntoView()
        return
      }
      if (dy > 0 && actionIndex >= primaryActions.length - 1) {
        if (moreActions.length > 0) {
          moreOpen = true
          focusSection = "more"
          moreIndex = 0
        }
        return
      }
      actionIndex = Math.max(0, Math.min(primaryActions.length - 1, actionIndex + dy))
      return
    }

    if (focusSection === "more") {
      if (dy < 0 && moreIndex === 0) {
        focusSection = primaryActions.length > 0 ? "actions" : "header"
        if (focusSection === "actions") actionIndex = Math.max(0, primaryActions.length - 1)
        return
      }
      moreIndex = Math.max(0, Math.min(moreActions.length - 1, moreIndex + dy))
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    if (panelFlick) panelFlick.contentY = 0
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "libraries" && libraryColumn && libraryIndex >= 0 && libraryIndex < libraryColumn.children.length)
      scrollItemIntoView(libraryColumn.children[libraryIndex])
    else if (focusSection === "header" && panelFlick)
      panelFlick.contentY = 0
  }

  function openFocusedLibrary() {
    var repo = seafile.repos[libraryIndex]
    if (!repo) return
    seafile.openFolder(String(repo.path || ""))
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "setup") {
      if (!seafile.installed) seafile.installPackage()
      else seafile.runSetup()
      return
    }
    if (focusSection === "sync") {
      if (syncFocus === "back") {
        closeSyncSettings()
        return
      }
      if (syncFocus === "auto") {
        toggleSyncAuto()
        return
      }
      if (syncFocus === "interval") {
        applySyncIntervalChoice(syncIntervalIndex)
        return
      }
      return
    }
    if (focusSection === "header") {
      seafile.toggleRunning()
      return
    }
    if (focusSection === "libraries") openFocusedLibrary()
    else if (focusSection === "actions") runAction(primaryActions[actionIndex])
    else if (focusSection === "more") runAction(moreActions[moreIndex])
  }

  function noteSyncNeedsRunning() {
    seafile.flashStatus(strings.t("sync.needRunning", "Resume syncing before changing sync settings"))
  }

  function toggleSyncAuto() {
    var repo = syncSettingsRepo
    if (!repo || seafile.busy) {
      if (seafile.busy) seafile.noteBusy()
      return
    }
    if (!seafile.running) {
      noteSyncNeedsRunning()
      return
    }
    seafile.setAutoSync(String(repo.id || ""), repo.autoSync === false)
  }

  function applySyncIntervalChoice(index) {
    var repo = syncSettingsRepo
    var choice = syncIntervalChoices[index]
    if (!repo || !choice) return
    if (seafile.busy) { seafile.noteBusy(); return }
    if (!seafile.running) {
      noteSyncNeedsRunning()
      return
    }
    var seconds = Number(choice.seconds || 0)
    if (!isFinite(seconds) || seconds < 0) seconds = 0
    if (Number(repo.syncIntervalSec || 0) === seconds) return
    seafile.setSyncInterval(String(repo.id || ""), Math.floor(seconds))
  }

  function runAction(action) {
    if (!action) return
    if (action.id === "syncSettings") {
      openSyncSettings("")
      return
    }
    if (seafile.busy) { seafile.noteBusy(); return }
    switch (action.id) {
    case "sync": seafile.syncNow(); break
    case "folder": seafile.openFolder(); break
    case "logs": seafile.openLogs(); break
    case "setup": seafile.runSetup(); break
    case "snooze15": seafile.snooze(15 * 60, strings.t("snooze15")); break
    case "snooze1h": seafile.snooze(60 * 60, strings.t("snooze1h")); break
    case "snoozeClear": seafile.resume(); break
    }
  }

  function setActionCursor(index) {
    cursorActive = true
    focusSection = "actions"
    actionIndex = index
  }

  function setMoreCursor(index) {
    cursorActive = true
    moreOpen = true
    focusSection = "more"
    moreIndex = index
  }

  function setLibraryCursor(index) {
    cursorActive = true
    focusSection = "libraries"
    libraryIndex = index
    scrollCursorIntoView()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    moreOpen = false
    syncSettingsOpen = false
    syncSettingsRepoId = ""
    libraryIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    ensureCursor()
    seafile.refresh()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  onLibraryIndexChanged: scrollCursorIntoView()

  Connections {
    target: seafile
    function onReposChanged() { root.ensureCursor() }
    function onInstalledChanged() { root.ensureCursor() }
    function onConfiguredChanged() { root.ensureCursor() }
    function onSnoozedChanged() { root.ensureCursor() }
  }

  Timer {
    id: heroClock
    interval: 30000
    repeat: true
    running: root.opened || seafile.snoozed
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  Service {
    id: seafile
    settings: root.settings
    pluginDir: root.pluginDir
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { seafile.refresh(); return "ok" }
    function syncNow(): string { seafile.syncNow(); return "ok" }
    function status(): string { return seafile.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        SeafileIcon {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize
          color: root.barIconColor
          warning: root.attention
          badgeColor: root.urgent
          opacity: seafile.active && !root.attention ? 1.0 : 0.6
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) seafile.refresh()
      else if (buttonCode === Qt.MiddleButton) seafile.syncNow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(520))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias hero: hero
      property alias libraryColumn: libraryColumn
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          root.ensureCursor()
          return
        }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        if (root.syncSettingsOpen) root.closeSyncSettings()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.syncSettingsOpen) {
          if (t === "a" || t === "A") root.toggleSyncAuto()
          else if (t === "r" || t === "R") seafile.refresh()
          return
        }
        if (t === "r" || t === "R") seafile.refresh()
        else if (t === "s" || t === "S") seafile.syncNow()
        else if (t === "p" || t === "P") seafile.toggleRunning()
        else if (t === "o" || t === "O") {
          if (root.focusSection === "libraries") root.openFocusedLibrary()
          else seafile.openFolder()
        }
        else if (t === "l" || t === "L") seafile.openLogs()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Column {
            id: syncSettingsColumn
            visible: root.syncSettingsOpen
            width: parent.width
            spacing: Style.space(10)

            CursorSurface {
              width: parent.width
              implicitHeight: syncBackRow.implicitHeight + Style.spacing.rowPaddingX
              hasCursor: root.cursorActive && root.focusSection === "sync" && root.syncFocus === "back"
              foreground: root.foreground

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: {
                  root.cursorActive = true
                  root.focusSection = "sync"
                  root.syncFocus = "back"
                }
                onClicked: root.closeSyncSettings()
              }

              RowLayout {
                id: syncBackRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)

                PlainText {
                  text: "󰁍"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }
                PlainText {
                  Layout.fillWidth: true
                  text: strings.t("syncSettings")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }
            }

            PlainText {
              width: parent.width
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              text: root.syncSettingsRepo
                ? String(root.syncSettingsRepo.name || strings.t("library"))
                : strings.t("library")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            PlainText {
              visible: seafile.actionStatus !== "" || seafile.lastError !== ""
              width: parent.width
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              text: seafile.actionStatus !== "" ? seafile.actionStatus : seafile.lastError
              color: seafile.lastError !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Item {
              id: syncAutoBlock
              width: parent.width
              implicitHeight: syncAutoRow.implicitHeight + Style.spacing.rowPaddingX
              readonly property bool ringVisible: root.cursorActive && root.focusSection === "sync" && root.syncFocus === "auto"

              CursorSurface {
                anchors.fill: parent
                hasCursor: syncAutoBlock.ringVisible
                foreground: root.foreground

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.ArrowCursor
                  onEntered: {
                    root.cursorActive = true
                    root.focusSection = "sync"
                    root.syncFocus = "auto"
                  }
                }

                RowLayout {
                  id: syncAutoRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    PlainText {
                      Layout.fillWidth: true
                      text: strings.t("sync.autoSync")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }
                    PlainText {
                      Layout.fillWidth: true
                      text: strings.t("sync.autoSyncHelp")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }

                  ToggleSwitch {
                    id: autoSyncSwitch
                    checked: root.syncSettingsRepo ? root.syncSettingsRepo.autoSync !== false : true
                    busy: seafile.busy
                    hasCursor: false
                    foreground: root.foreground
                    onHovered: function(on) {
                      if (on) {
                        root.cursorActive = true
                        root.focusSection = "sync"
                        root.syncFocus = "auto"
                      }
                    }
                    onToggled: root.toggleSyncAuto()
                  }
                }
              }
            }

            PlainText {
              width: parent.width
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              text: strings.t("sync.checkForChanges")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            PlainText {
              width: parent.width
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              text: strings.t("sync.checkForChangesHelp")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.syncIntervalChoices
                SyncIntervalRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  choice: modelData
                  rowIndex: index
                }
              }
            }
          }

          Item {
            id: header
            visible: !root.syncSettingsOpen && seafile.installed && seafile.configured
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: strings.t("title")
              meta: root.heroMetaText
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: seafile.active ? 1.0 : 0.5
              iconComponent: Component {
                SeafileIcon {
                  iconSize: Style.font.display
                  color: root.iconColor
                  warning: root.attention
                  badgeColor: root.urgent
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: seafile.active
                  busy: seafile.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: seafile.toggleRunning()
                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          PlainText {
            visible: !root.syncSettingsOpen && (seafile.actionStatus !== "" || seafile.lastError !== "")
            width: parent.width
            text: seafile.actionStatus !== "" ? seafile.actionStatus : seafile.lastError
            color: seafile.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          SetupCard {
            visible: !root.syncSettingsOpen && (!seafile.installed || !seafile.configured)
            width: parent.width
          }

          Column {
            visible: !root.syncSettingsOpen && seafile.installed && seafile.configured
            width: parent.width
            spacing: Style.space(6)

            Column {
              id: libraryColumn
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: seafile.repos
                LibraryRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  repo: modelData
                  rowIndex: index
                }
              }
            }

            PlainText {
              visible: seafile.repos.length === 0
              width: parent.width
              text: seafile.aggregate === "needs-resync"
                ? strings.t("noLibrariesNeedsResync")
                : strings.t("noLibraries")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: !root.syncSettingsOpen && seafile.installed && seafile.configured && root.primaryActions.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.primaryActions
              ActionRow {
                required property var modelData
                required property int index
                width: parent.width
                action: modelData
                rowIndex: index
                section: "actions"
              }
            }
          }

          PanelSeparator {
            visible: !root.syncSettingsOpen && seafile.installed && seafile.configured
            foreground: root.foreground
          }

          Column {
            visible: !root.syncSettingsOpen && seafile.installed && seafile.configured
            width: parent.width
            spacing: Style.space(4)

            CursorSurface {
              width: parent.width
              implicitHeight: moreHeader.implicitHeight + Style.spacing.rowPaddingX
              hasCursor: false
              foreground: root.foreground

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.moreOpen = !root.moreOpen
              }

              RowLayout {
                id: moreHeader
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)

                PlainText {
                  text: strings.t("more")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  Layout.fillWidth: true
                }
                PlainText {
                  text: root.moreOpen ? "󰅀" : "󰅂"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Column {
              visible: root.moreOpen
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.moreActions
                ActionRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  action: modelData
                  rowIndex: index
                  section: "more"
                  dimmed: true
                }
              }
            }
          }
        }
      }
    }
  }

  component SetupCard: CursorSurface {
    id: setupCard
    hasCursor: root.cursorActive && root.focusSection === "setup"
    foreground: root.foreground
    implicitHeight: setupCol.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: !seafile.busy
      onEntered: {
        root.cursorActive = true
        root.focusSection = "setup"
      }
      onClicked: {
        if (!seafile.installed) seafile.installPackage()
        else seafile.runSetup()
      }
    }

    ColumnLayout {
      id: setupCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(10)
      spacing: Style.space(4)

      PlainText {
        Layout.fillWidth: true
        text: !seafile.installed ? strings.t("install") : strings.t("setup")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      PlainText {
        Layout.fillWidth: true
        text: !seafile.installed ? strings.t("installHelp") : strings.t("setupHelp")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  component LibraryRow: CursorSurface {
    id: libraryRow
    property var repo: null
    property int rowIndex: 0

    readonly property string repoName: {
      var name = repo ? String(repo.name || "") : ""
      return name !== "" ? name : strings.t("library")
    }
    readonly property string repoMeta: {
      var _lang = strings.language
      return Model.libraryMeta(repo, root.tr)
    }
    readonly property string repoError: Model.libraryError(repo)
    readonly property string repoPath: repo ? String(repo.path || "") : ""

    hasCursor: root.cursorActive && root.focusSection === "libraries" && root.libraryIndex === rowIndex
    foreground: root.foreground
    implicitHeight: libraryContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: libraryRow.repoPath.charAt(0) === "/" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.setLibraryCursor(libraryRow.rowIndex)
      onClicked: seafile.openFolder(libraryRow.repoPath)
    }

    ColumnLayout {
      id: libraryContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(1)

      PlainText {
        Layout.fillWidth: true
        text: libraryRow.repoName
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      PlainText {
        visible: libraryRow.repoMeta !== ""
        Layout.fillWidth: true
        text: libraryRow.repoMeta
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
      PlainText {
        visible: libraryRow.repoError !== ""
        Layout.fillWidth: true
        text: libraryRow.repoError
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }
    }
  }

  component SyncIntervalRow: CursorSurface {
    id: intervalRow
    property var choice: null
    property int rowIndex: 0

    readonly property int choiceSeconds: {
      var sec = Number(intervalRow.choice ? intervalRow.choice.seconds : 0)
      return isFinite(sec) && sec > 0 ? Math.floor(sec) : 0
    }
    readonly property bool selected: {
      var repo = root.syncSettingsRepo
      var current = repo ? Number(repo.syncIntervalSec || 0) : 0
      if (!isFinite(current) || current < 0) current = 0
      return Math.floor(current) === intervalRow.choiceSeconds
    }

    hasCursor: root.cursorActive
      && root.focusSection === "sync"
      && root.syncFocus === "interval"
      && root.syncIntervalIndex === rowIndex
    foreground: root.foreground
    implicitHeight: intervalContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: seafile.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      enabled: !seafile.busy
      onEntered: {
        root.cursorActive = true
        root.focusSection = "sync"
        root.syncFocus = "interval"
        root.syncIntervalIndex = intervalRow.rowIndex
      }
      onClicked: root.applySyncIntervalChoice(intervalRow.rowIndex)
    }

    RowLayout {
      id: intervalContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      PlainText {
        Layout.fillWidth: true
        text: root.intervalChoiceLabel(intervalRow.choice)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      PlainText {
        visible: intervalRow.selected
        text: "󰄬"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property var action: null
    property int rowIndex: 0
    property string section: "actions"
    property bool dimmed: false

    hasCursor: root.cursorActive
      && root.focusSection === section
      && ((section === "actions" && root.actionIndex === rowIndex)
          || (section === "more" && root.moreIndex === rowIndex))
    foreground: root.foreground
    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: seafile.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      enabled: !seafile.busy
      onEntered: {
        if (actionRow.section === "actions") root.setActionCursor(actionRow.rowIndex)
        else root.setMoreCursor(actionRow.rowIndex)
      }
      onClicked: root.runAction(actionRow.action)
    }

    RowLayout {
      id: actionContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      PlainText {
        text: actionRow.action ? String(actionRow.action.icon || "") : ""
        color: actionRow.dimmed ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }
      PlainText {
        Layout.fillWidth: true
        text: actionRow.action ? String(actionRow.action.label || "") : ""
        color: actionRow.dimmed ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
  }
}
