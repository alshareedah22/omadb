import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Layout.js" as Layout

Panel {
  id: root
  moduleName: "blackcode.omadbngin"
  ipcTarget: "blackcode.omadbngin"
  manageIpc: true

  // ---- Settings (shell.json → this widget's bar entry; see manifest schema) ----
  // countStyle replaces 1.6's `label`: "Icon only" there means Hidden here.
  readonly property string countStyle: {
    const c = String(setting("countStyle", ""))
    if (c === "Badge" || c === "Text" || c === "Hidden") return c
    return String(setting("label", "")) === "Icon only" ? "Hidden" : "Badge"
  }
  readonly property bool crashDot: setting("crashDot", true) !== false
  readonly property bool compact: String(setting("rowStyle", "Detailed")) === "Compact"
  readonly property bool statsOn: setting("stats", true) !== false
  readonly property string defaultMode: String(setting("defaultMode", "Native")) === "Docker" ? "docker" : "native"
  readonly property var portDefaults: { const v = setting("ports", {}); return v && typeof v === "object" ? v : {} }
  readonly property var userDefaults: { const v = setting("users", {}); return v && typeof v === "object" ? v : {} }
  readonly property string backupDir: String(setting("backupDir", ""))
  readonly property string backupLabel: backupDir || "~/Downloads"
  readonly property var backupEnv: backupDir ? { OMADBNGIN_BACKUP_DIR: backupDir.replace(/^~(?=\/|$)/, Quickshell.env("HOME")) } : ({})
  onStatsOnChanged: DbState.stats = statsOn

  // ---- Pages, search, stacks ----
  property string page: "servers"         // "servers" | "settings"
  property string search: ""
  readonly property var shown: services.filter(function(s) {
    if (search === "") return true
    const q = search.toLowerCase()
    return [s.name, s.engine, s.flavor || "", s.exact || s.version, String(s.port), s.stack || "", s.mode]
      .some(function(t) { return String(t).toLowerCase().indexOf(q) !== -1 })
  })
  // [{stack, items}] in list order: servers without a stack first, then each stack
  readonly property var groups: {
    const out = [{ stack: "", items: shown.filter(function(s) { return !s.stack }) }]
    const names = []
    shown.forEach(function(s) { if (s.stack && names.indexOf(s.stack) === -1) names.push(s.stack) })
    names.sort().forEach(function(n) { out.push({ stack: n, items: shown.filter(function(s) { return s.stack === n }) }) })
    return out.filter(function(g) { return g.items.length > 0 })
  }
  function powerAll(list, on) {
    list.forEach(function(s) {
      if (s.running !== on) root.run(s.name, on ? "Starting" : "Stopping", [on ? "start" : "stop", s.name])
    })
  }

  // ---- Copy as ----
  function formatsFor(s) {
    const k = s.engine
    if (k === "redis" || k === "valkey") return [["url", "URL"], ["env", "REDIS_URL"], ["laravel", "Laravel"], ["django", "Django"], ["cli", "CLI"]]
    if (k === "mongodb") return [["url", "URL"], ["env", "MONGODB_URI"], ["laravel", "Laravel"], ["cli", "CLI"]]
    return [["url", "URL"], ["env", "DATABASE_URL"], ["laravel", "Laravel"], ["django", "Django"], ["jdbc", "JDBC"], ["cli", "CLI"]]
  }
  function copyAs(name, format, label) {
    Quickshell.execDetached([root.ctl, "copy", name, format])
    root.copiedName = name
    root.copiedLabel = label
    copiedTimer.restart()
  }
  property string copiedLabel: "URL"

  // ---- Logs inside the panel ----
  property string shownLogs: ""
  property var logLines: []
  function toggleLogs(name) {
    root.logLines = []
    root.shownLogs = root.shownLogs === name ? "" : name
  }

  readonly property string ctl: decodeURIComponent(String(Qt.resolvedUrl("dbctl")).replace(/^file:\/\//, ""))
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : ""
  readonly property color dim: Qt.darker(root.fg, 1.4)

  // ---- Live state, read from Docker by dbctl ----
  property bool stateLoaded: false
  property string dockerStatus: "running"
  property var engines: []
  property var services: []
  property var installed: []
  readonly property bool dockerUp: dockerStatus === "running"
  readonly property int runningCount: services.filter(function(s) { return s.running }).length

  function engineInfo(id) {
    for (let i = 0; i < engines.length; i++) if (engines[i].id === id) return engines[i]
    return { id: id, title: id, port: 0, versions: [] }
  }

  // ---- Actions: one queue, so commands never race each other ----
  property var queue: []
  property string busyName: ""
  property string busyLabel: ""
  property string busyDetail: ""
  property var stderrLines: []
  property string errorText: ""
  property string armedDelete: ""
  property string copiedName: ""
  property string shownCreds: ""
  property string shownTools: ""      // the server whose backup / restore / port tools are open
  property var backups: []
  property string armedRestore: ""
  property string portDraft: ""       // kept here: a state refresh rebuilds the rows
  property bool portFocus: false
  property bool omatable: false       // OmaTablePlus is installed: offer Open in OmaTablePlus

  function human(n) {
    return n >= 1073741824 ? (n / 1073741824).toFixed(1) + " GB" : n >= 1048576 ? Math.round(n / 1048576) + " MB"
      : n >= 1024 ? Math.round(n / 1024) + " KB" : n + " B"
  }
  function uptime(since) {
    const s = Math.max(0, Date.now() / 1000 - since)
    return s < 3600 ? Math.max(1, Math.round(s / 60)) + " min" : s < 86400 ? Math.round(s / 3600) + " h" : Math.round(s / 86400) + " d"
  }
  function health(s) {
    const parts = []
    if (s.running && s.since) parts.push("up " + uptime(s.since))
    if (s.running && root.statsOn && DbState.cpu[s.name] !== undefined) parts.push(DbState.cpu[s.name].toFixed(1) + "% CPU")
    if (s.running && s.memory) parts.push(human(s.memory) + " RAM")
    const size = DbState.sizes[s.name]
    if (size) parts.push(human(size) + " data")
    return parts.join("  ·  ")
  }
  function openInOmaTablePlus(name) {
    root.close()
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "blackcode.omatableplus", JSON.stringify({ connect: "omadb:" + name })])
  }
  function toggleTools(name) {
    root.armedRestore = ""
    root.portDraft = ""
    root.portFocus = false
    root.shownTools = root.shownTools === name ? "" : name
    root.backups = []
    if (root.shownTools) loadBackups()
  }
  function loadBackups() {
    if (!root.shownTools || backupsProc.running) return
    backupsProc.command = [root.ctl, "backups", root.shownTools]
    backupsProc.environment = root.backupEnv
    backupsProc.running = true
  }
  function restoreBackup(name, path) {
    if (root.armedRestore !== path) { root.armedRestore = path; return }
    root.armedRestore = ""
    run(name, "Restoring", ["restore", name, path], root.backupEnv)
  }

  function refresh() { DbState.refreshSoon() }

  // The shared state (DbState) changed: take it, unless the port field is being typed in,
  // since a new list rebuilds the rows and would take its focus (and draft) mid-typing.
  function applyState() {
    const s = DbState.snapshot
    if (!s) return
    root.omatable = !!s.omatable
    root.dockerStatus = s.docker || "missing"
    root.engines = s.engines || []
    if (!root.portFocus) root.services = s.services || []
    root.installed = s.installed || []
    root.stateLoaded = true
  }
  Connections {
    target: DbState
    function onSnapshotChanged() { root.applyState() }
  }
  onPortFocusChanged: if (!portFocus) applyState()
  Component.onCompleted: { DbState.users += 1; DbState.stats = statsOn; applyState(); claimReopen() }
  Component.onDestruction: { DbState.users -= 1; if (opened) DbState.viewers -= 1 }

  function run(name, label, args, env) {
    root.errorText = ""
    root.queue = root.queue.concat([{ name: name, label: label, command: [root.ctl].concat(args), env: env || ({}) }])
    if (!actionProc.running) runNext()
  }

  function runNext() {
    if (root.queue.length === 0) { root.busyName = ""; root.busyLabel = ""; return }
    const job = root.queue[0]
    root.queue = root.queue.slice(1)
    root.busyName = job.name
    root.busyLabel = job.label
    root.busyDetail = ""
    root.stderrLines = []
    actionProc.command = job.command
    actionProc.environment = job.env
    actionProc.running = true
  }

  function launch(args) {
    root.close()
    Quickshell.execDetached([root.ctl].concat(args))
  }

  function copyUrl(name) { copyAs(name, "url", "URL") }

  function removeService(name) {
    if (root.armedDelete !== name) {
      root.armedDelete = name
      armTimer.restart()
      return
    }
    root.armedDelete = ""
    run(name, "Removing", ["remove", name])
  }

  function statusText(s) {
    if (root.busyName === s.name && root.busyLabel !== "") return root.busyLabel + "…"
    if (s.state === "failed" || DbState.crashed.indexOf(s.name) !== -1) return s.oom ? "Out of memory · see logs" : "Stopped unexpectedly · see logs"
    if (s.state === "running") return s.health === "starting" || s.ready === false ? "Starting…" : "Running"
    if (s.state === "restarting") return "Restarting…"
    if (s.state === "created" || s.state === "exited") return "Stopped"
    return s.state.charAt(0).toUpperCase() + s.state.slice(1)
  }

  // ---- New server form ----
  property string newEngine: "postgresql"
  property string newVersion: ""
  property string suggestedPort: ""
  property bool newAutostart: false
  property string newMode: defaultMode
  function isInstalled(engine, line) {
    return root.installed.some(function(i) { return i.engine === engine && i.line === line })
  }
  readonly property var newEngineInfo: engineInfo(newEngine)
  readonly property string defaultName: {
    const base = newEngine + "-" + String(newVersion || "").split(/[.-]/)[0]
    const taken = {}
    services.forEach(function(s) { taken[s.name] = true })
    if (!taken[base]) return base
    for (let i = 2; ; i++) if (!taken[base + "-" + i]) return base + "-" + i
  }

  readonly property string builtinUser: ({ postgresql: "postgres", postgis: "postgres", mysql: "root", mariadb: "root", redis: "default", valkey: "default" })[newEngine] || ""
  readonly property string defaultUser: String(userDefaults[newEngine] || builtinUser)
  function askPort(id) {
    if (portProc.running) return
    const base = root.portDefaults[id]
    portProc.command = [root.ctl, "port", id].concat(base ? [String(base)] : [])
    portProc.running = true
  }

  function pickEngine(id) {
    root.newEngine = id
    const info = engineInfo(id)
    root.newVersion = info.versions.length > 0 ? info.versions[0] : ""
    root.suggestedPort = ""
    portField.text = ""
    askPort(id)
  }

  function createService() {
    const name = nameField.text.trim() || root.defaultName
    const port = portField.text.trim() || root.suggestedPort
    if (!/^[a-z0-9][a-z0-9-]{0,40}$/.test(name)) { root.errorText = "Name: lowercase letters, digits and dashes."; return }
    const user = userField.text.trim() || (root.defaultUser !== root.builtinUser ? root.defaultUser : "")
    const pass = passField.text
    if (root.newEngine === "mongodb" && user !== "" && pass === "") { root.errorText = "MongoDB needs a password when you set a username."; return }
    // the password goes in the environment: arguments are visible to every local account
    run(name, "Creating", ["create", root.newEngine, root.newVersion, name, port, root.newAutostart ? "on" : "off", root.newMode, user],
        { OMADBNGIN_PASSWORD: pass })
  }

  // The form is cleared only once the server exists, so a failed create keeps what you typed.
  function createFinished(ok) {
    if (!ok) return
    nameField.text = ""
    portField.text = ""
    userField.text = ""
    passField.text = ""
    root.suggestedPort = ""
  }

  onOpenedChanged: {
    root.portFocus = false
    DbState.viewers += opened ? 1 : -1
    if (opened) {
      root.errorText = ""
      root.armedDelete = ""
      DbState.ackCrashes()
      if (root.newVersion === "" && root.engines.length > 0) pickEngine(root.newEngine)
      else askPort(root.newEngine)
    } else {
      root.shownLogs = ""
      root.page = "servers"
      root.search = ""
    }
  }

  onEnginesChanged: if (root.newVersion === "" && root.engines.length > 0) pickEngine(root.newEngine)

  Timer {
    id: armTimer
    interval: 3000
    onTriggered: root.armedDelete = ""
  }

  Timer {
    id: copiedTimer
    interval: 1500
    onTriggered: root.copiedName = ""
  }

  Process {
    id: actionProc
    stderr: SplitParser {
      onRead: function(line) {
        const l = String(line).trim()
        if (l === "") return
        root.stderrLines = root.stderrLines.concat([l]).slice(-3)
        if (l.indexOf("dbctl:") !== 0) root.busyDetail = l.replace(/…$/, "")
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.errorText = root.stderrLines.slice(-2).join("\n") || "Failed."
      if (root.busyLabel === "Creating") root.createFinished(exitCode === 0)
      root.refresh()
      root.loadBackups()
      root.runNext()
      if (root.opened) root.askPort(root.newEngine)
    }
  }

  Process {
    id: backupsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.backups = JSON.parse(text) } catch (e) { root.backups = [] } }
    }
  }

  Process {
    id: portProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.suggestedPort = text.trim()
    }
  }

  // ---- Settings writes: our own entry in shell.json, with a rolling backup ----
  // Not the shell's inline save: that one cannot move the entry to another place on the bar.
  readonly property string shellPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  property string settingsMessage: ""
  property bool writeFailed: false
  property var shellConfig: null      // read when the settings page opens
  readonly property var selfAt: shellConfig ? Layout.findSelf(shellConfig) : null
  property string moveSection: ""
  property string movePlace: "last"
  property int moveAnchor: -1           // index in moveNeighbours
  readonly property var moveNeighbours: shellConfig && moveSection ? Layout.neighbours(shellConfig, moveSection) : []

  function readShell() {
    try { shellFile.reload(); return String(shellFile.text()) } catch (e) { return null }
  }
  function openSettings() {
    const raw = readShell()
    try { root.shellConfig = raw ? JSON.parse(raw) : null } catch (e) { root.shellConfig = null }
    root.moveSection = root.selfAt ? root.selfAt.section : "right"
    root.movePlace = "last"
    root.moveAnchor = -1
    root.settingsMessage = ""
    root.page = "settings"
    if (!root.opened) root.open()
  }
  function writeShell(plan) {
    const raw = readShell()
    if (raw === null || raw === "") { root.settingsMessage = "shell.json can't be read"; return false }
    const result = plan(raw)
    if (result.error) {
      root.settingsMessage = ({ invalid: "shell.json can't be read", none: "OmaDBngin is not in the bar layout",
        anchor: "Pick the widget to place it next to" })[result.error] || "Not saved"
      return false
    }
    if (result.unchanged) return true
    shellBackup.setText(raw)
    if (!shellBackup.waitForJob()) { root.settingsMessage = "Could not back up shell.json"; return false }
    DbState.reopenScreen = root.screenName
    DbState.reopenPage = "settings"
    root.writeFailed = false
    shellFile.setText(result.next)
    if (!shellFile.waitForJob() || root.writeFailed) {
      DbState.reopenPage = ""
      root.settingsMessage = "Could not write shell.json"
      return false
    }
    forgetReopen.restart()
    const after = readShell()
    try { root.shellConfig = JSON.parse(after) } catch (e) {}
    return true
  }
  function saveSettings(changes) { return writeShell(function(raw) { return Layout.planSettings(raw, changes) }) }
  function moveOnBar() {
    const place = root.movePlace
    if ((place === "before" || place === "after") && root.moveAnchor < 0) { root.settingsMessage = "Pick the widget to place it next to"; return }
    writeShell(function(raw) { return Layout.planMove(raw, root.moveSection, place, root.moveAnchor) })
  }
  property bool armedReset: false
  function resetSettings() {
    if (!root.armedReset) { root.armedReset = true; return }
    root.armedReset = false
    writeShell(Layout.planReset)
  }

  // The shortcut: dbctl bind / unbind, with its answer shown under the buttons.
  function shortcut(on) {
    shortcutProc.command = [root.ctl, on ? "bind" : "unbind"]
    shortcutProc.running = true
  }

  property FileView shellFile: FileView {
    path: root.shellPath
    blockAllReads: true
    preload: false
    atomicWrites: true
    printErrors: false
    onSaveFailed: root.writeFailed = true
  }
  property FileView shellBackup: FileView {
    path: root.shellPath + ".omadbngin-settings-backup"
    blockAllReads: true
    preload: false
    atomicWrites: true
    printErrors: false
  }

  // After a save Omarchy may rebuild the bar; the new copy on this screen reopens the settings.
  readonly property string screenName: QsWindow.window && QsWindow.window.screen ? String(QsWindow.window.screen.name) : ""
  function claimReopen() {
    if (DbState.reopenPage === "" || root.screenName === "" || root.screenName !== DbState.reopenScreen) return
    DbState.reopenPage = ""
    if (root.opened) root.openSettings(); else reopenTimer.restart()
  }
  Connections {
    target: DbState
    function onReopenPageChanged() { root.claimReopen() }
  }
  onScreenNameChanged: claimReopen()
  Timer { id: reopenTimer; interval: 250; onTriggered: root.openSettings() }
  Timer { id: forgetReopen; interval: 1500; onTriggered: DbState.reopenPage = "" }

  Process {
    id: shortcutProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.settingsMessage = text.trim() }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.settingsMessage = text.trim().replace(/^dbctl: /, "") }
  }

  // Follows one server's log while its log view is open; nothing runs otherwise.
  Process {
    id: tailProc
    running: root.opened && root.shownLogs !== ""
    command: [root.ctl, "tail", root.shownLogs]
    stdout: SplitParser {
      onRead: function(line) { root.logLines = root.logLines.concat([String(line)]).slice(-200) }
    }
  }

  // ---- Small building blocks ----
  component SettingRow: Item {
    property string title: ""
    default property alias content: holder.data
    width: settingsPage.width
    height: Math.max(rowTitle.implicitHeight, holder.childrenRect.height)
    Text {
      id: rowTitle
      anchors.verticalCenter: parent.verticalCenter
      text: parent.title
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item {
      id: holder
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.fg, 1.3)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Chip: CursorSurface {
    id: chip
    property string label: ""
    property bool selected: false
    signal picked()

    width: chipText.implicitWidth + Style.space(18)
    height: chipText.implicitHeight + Style.space(10)
    current: selected
    outline: !selected
    hasCursor: chipMouse.containsMouse
    foreground: root.fg
    accent: Color.accent

    Text {
      id: chipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: chip.label
      color: chip.selected ? Color.accent : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: chip.selected
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.picked()
    }
  }

  component IconAction: Text {
    id: action
    property string tip: ""
    property color hoverColor: Color.accent
    signal activated()

    textFormat: Text.PlainText
    color: actionMouse.containsMouse ? hoverColor : Qt.darker(root.fg, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.icon

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      anchors.margins: -4
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.activated()
    }

    PanelToolTip {
      visible: actionMouse.containsMouse && action.tip !== ""
      text: action.tip
    }
  }

  // ---- Bar button ----
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The label is drawn by barIcon below: a color database icon, the running count, a crash dot.
    text: "󰆼"
    labelVisible: false
    fixedWidth: vertical ? -1 : barIcon.implicitWidth + Style.spaceReal(6) * 2
    fontSize: Style.font.caption
    horizontalMargin: 6
    tooltipText: (root.services.length === 0 ? "Databases" : root.services.map(function(s) {
      const crashed = DbState.crashed.indexOf(s.name) !== -1
      return (s.running ? "● " : crashed ? "✕ " : "○ ") + s.name + "  " + root.engineInfo(s.flavor || s.engine).title
        + " " + (s.exact || s.version) + "  :" + s.port + (crashed ? "  stopped unexpectedly" : "")
    }).join("\n")) + "\nRight-click: settings"
    onPressed: function(b) {
      if (b === Qt.RightButton) { if (root.opened && root.page === "settings") root.close(); else root.openSettings() }
      else { root.page = "servers"; root.toggle() }
    }
    Row {
      id: barIcon
      anchors.centerIn: parent
      spacing: Math.round(Style.font.caption * 0.3)
      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: icon.width
        height: icon.height
        Image {
          id: icon
          source: Qt.resolvedUrl("icon.svg")
          width: Math.round(Style.font.caption * 1.35)
          height: width
          sourceSize: Qt.size(width * 2, height * 2)
          smooth: true
          opacity: root.runningCount > 0 ? 1 : 0.55
        }
        // running count as a badge on the icon's top-right corner
        Rectangle {
          visible: root.countStyle === "Badge" && root.runningCount > 0
          readonly property real d: Math.round(Style.font.caption * 0.85)
          width: Math.max(d, badgeText.implicitWidth + 4)
          height: d
          radius: d / 2
          x: icon.width - width * 0.6
          y: -height * 0.35
          color: Color.accent
          Text {
            id: badgeText
            anchors.centerIn: parent
            text: String(root.runningCount)
            color: Color.background
            font.family: button.fontFamily
            font.pixelSize: Math.round(Style.font.caption * 0.62)
            font.bold: true
          }
        }
        // a server stopped on its own: red until the panel is opened
        Rectangle {
          visible: root.crashDot && DbState.unackedCrashes > 0
          readonly property real d: Math.round(Style.font.caption * 0.5)
          width: d
          height: d
          radius: d / 2
          x: icon.width - d * 0.7
          y: icon.height - d * 0.8
          color: Color.urgent
          border.width: 1
          border.color: Color.background
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.countStyle === "Text" && root.runningCount > 0
        text: String(root.runningCount)
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
        renderType: Text.NativeRendering
      }
    }
  }

  // ---- Popup ----
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: nameField
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(1100))

    Column {
      id: panelColumn
      anchors.fill: parent
      spacing: Style.space(10)

      // Header
      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

        Image {
          id: heroIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          source: Qt.resolvedUrl("icon.svg")
          width: Math.round(Style.font.display * 1.25)
          height: width
          sourceSize: Qt.size(width * 2, height * 2)
          smooth: true
        }

        Row {
          id: headerActions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(14)
          IconAction {
            visible: root.page === "servers" && root.shown.some(function(s) { return !s.running })
            text: "󰐊"
            tip: root.search ? "Start the servers shown" : "Start all servers"
            onActivated: root.powerAll(root.shown, true)
          }
          IconAction {
            visible: root.page === "servers" && root.shown.some(function(s) { return s.running })
            text: "󰓛"
            hoverColor: Color.urgent
            tip: root.search ? "Stop the servers shown" : "Stop all servers"
            onActivated: root.powerAll(root.shown, false)
          }
          IconAction {
            text: root.page === "settings" ? "󰅖" : "󰒓"
            color: root.page === "settings" ? Color.accent : Qt.darker(root.fg, 1.5)
            tip: root.page === "settings" ? "Back to servers" : "Settings"
            onActivated: root.page === "settings" ? root.page = "servers" : root.openSettings()
          }
        }

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: headerActions.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: "OmaDBngin"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: root.page === "settings" ? "SETTINGS" : root.runningCount + " RUNNING  ·  " + root.services.length + " SERVERS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }
        }
      }

      Text {
        width: parent.width
        visible: root.stateLoaded && !root.dockerUp && root.newMode === "docker"
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: root.dockerStatus === "missing"
          ? "Docker is not installed. Install it with: omarchy install docker"
          : "Docker is not running. Start the docker service to use Docker mode, or pick Native engine."
        color: Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Column {
        id: serversPage
        visible: root.page === "servers"
        width: parent.width
        spacing: Style.space(10)

        PanelSeparator { foreground: root.fg }

        // Servers
        PanelSectionHeader {
          text: "SERVERS"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Label {
          width: parent.width
          visible: root.services.length === 0
          wrapMode: Text.Wrap
          text: root.busyLabel === "Creating" ? "Creating " + root.busyName + "… " + (root.busyDetail || "the first server of each version downloads it once.")
            : "No servers yet. Create one below."
        }

        TextField {
          id: searchField
          visible: root.services.length > 5
          width: parent.width
          foreground: root.fg
          placeholderText: "Search name, engine, version, port or stack"
          text: root.search
          onTextEdited: root.search = text
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { if (root.search) { root.search = ""; event.accepted = true } }
          }
        }

        Label {
          visible: root.search !== "" && root.shown.length === 0
          text: "No server matches “" + root.search + "”"
        }

        Repeater {
          model: root.groups
          delegate: Column {
            id: group
            required property var modelData
            width: serversPage.width
            spacing: Style.space(2)

          // a stack: its name, with start / stop for its servers
          Item {
            visible: group.modelData.stack !== ""
            width: parent.width
            height: visible ? stackTitle.implicitHeight + Style.space(10) : 0
            Text {
              id: stackTitle
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "󰕮  " + group.modelData.stack.toUpperCase() + "  ·  "
                + group.modelData.items.filter(function(s) { return s.running }).length + "/" + group.modelData.items.length
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
            }
            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)
              IconAction {
                visible: group.modelData.items.some(function(s) { return !s.running })
                text: "󰐊"
                tip: "Start " + group.modelData.stack
                onActivated: root.powerAll(group.modelData.items, true)
              }
              IconAction {
                visible: group.modelData.items.some(function(s) { return s.running })
                text: "󰓛"
                hoverColor: Color.urgent
                tip: "Stop " + group.modelData.stack
                onActivated: root.powerAll(group.modelData.items, false)
              }
            }
          }

          Repeater {
            model: group.modelData.items

            CursorSurface {
              id: row
              required property var modelData
              readonly property bool busy: root.busyName === modelData.name
              readonly property bool armed: root.armedDelete === modelData.name

              width: parent.width
              height: rowText.implicitHeight + Style.space(16)
              hasCursor: rowMouse.containsMouse
              foreground: root.fg
              accent: Color.accent

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
              }

              Text {
                id: dot
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                // level with the name, also when the tools below it are open
                y: rowText.y + rowName.y + (rowName.height - height) / 2
                text: "●"
                color: row.modelData.running ? (row.modelData.health === "starting" ? Color.accent : "#4caf50") : Qt.darker(root.fg, 2.2)
                font.pixelSize: Style.font.caption
              }

              Column {
                id: rowText
                readonly property bool showCreds: root.shownCreds === row.modelData.name
                anchors.left: dot.right
                anchors.leftMargin: Style.space(10)
                anchors.right: rowActions.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  id: rowName
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  text: row.modelData.name
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  text: row.armed ? "Click 󰆴 again to delete it and its data" : (row.modelData.mode === "docker" ? "󰡨 " : "󰆼 ")
                    + root.engineInfo(row.modelData.flavor || row.modelData.engine).title + " " + (row.modelData.exact || row.modelData.version)
                    + "  ·  :" + row.modelData.port
                  color: row.armed ? Color.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: rowText.showCreds
                  wrapMode: Text.WrapAnywhere
                  text: "User: " + (row.modelData.user || "none (no auth)")
                    + "    Password: " + (row.modelData.password || "none")
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: !row.armed && text !== ""
                  wrapMode: Text.Wrap
                  // the green dot already says "Running"
                  text: [root.copiedName === row.modelData.name ? root.copiedLabel + " copied" : root.statusText(row.modelData),
                         root.compact ? "" : root.health(row.modelData)]
                    .filter(function(t) { return t !== "" && t !== "Running" }).join("  ·  ")
                  color: Qt.darker(root.fg, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: !!row.modelData.error && !row.modelData.running
                  wrapMode: Text.Wrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                  text: row.modelData.error || ""
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // backup, restore and port, under the row when ⋯ is on
                // built only while open: every refresh rebuilds the rows, so hidden tools would cost CPU
                Loader {
                  // the full row width: the text column itself is narrowed by the action icons
                  width: row.width - rowText.x - Style.space(10)
                  active: root.shownTools === row.modelData.name
                  visible: active
                  sourceComponent: Column {
                    width: parent ? parent.width : 0
                    spacing: Style.space(6)
                    topPadding: Style.space(6)
                    Row {
                      spacing: Style.space(8)
                      Chip {
                        label: row.modelData.engine === "mongodb" ? "Back up in OmaTablePlus" : "󰁯  Back up to " + root.backupLabel
                        onPicked: row.modelData.engine === "mongodb" ? root.openInOmaTablePlus(row.modelData.name)
                          : root.run(row.modelData.name, "Backing up", ["backup", row.modelData.name], root.backupEnv)
                      }
                      TextField {
                        id: movePort
                        width: Style.space(70)
                        foreground: root.fg
                        placeholderText: String(row.modelData.port)
                        text: root.portDraft
                        onTextEdited: root.portDraft = text
                        onActiveFocusChanged: root.portFocus = activeFocus
                        onAccepted: moveChip.picked()
                      }
                      Chip {
                        id: moveChip
                        label: "Move to port"
                        onPicked: {
                          movePort.focus = false
                          root.portFocus = false
                          if (root.portDraft) root.run(row.modelData.name, "Moving", ["set-port", row.modelData.name, root.portDraft])
                          root.portDraft = ""
                        }
                      }
                    }
                    Text {
                      visible: root.backups.length === 0 && row.modelData.engine !== "mongodb"
                      text: "No backups of " + row.modelData.name + " in " + root.backupLabel + " yet"
                      color: Qt.darker(root.fg, 1.6)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Label { text: "Copy as" }
                    Flow {
                      width: parent.width
                      spacing: Style.space(6)
                      Repeater {
                        model: root.formatsFor(row.modelData)
                        Chip {
                          required property var modelData
                          label: modelData[1]
                          onPicked: root.copyAs(row.modelData.name, modelData[0], modelData[1])
                        }
                      }
                    }
                    Label { text: "Stack: a project group, started and stopped together" }
                    Row {
                      spacing: Style.space(8)
                      TextField {
                        id: stackField
                        width: Style.space(160)
                        foreground: root.fg
                        placeholderText: row.modelData.stack || "none"
                        onActiveFocusChanged: root.portFocus = activeFocus
                        onAccepted: stackChip.picked()
                      }
                      Chip {
                        id: stackChip
                        label: stackField.text.trim() ? "Put in " + stackField.text.trim() : (row.modelData.stack ? "Take out of " + row.modelData.stack : "Set")
                        onPicked: {
                          const st = stackField.text.trim()
                          stackField.focus = false
                          root.portFocus = false
                          if (st) root.run(row.modelData.name, "Saving", ["stack", "add", st, row.modelData.name])
                          else if (row.modelData.stack) root.run(row.modelData.name, "Saving", ["stack", "remove", row.modelData.name])
                          stackField.text = ""
                        }
                      }
                      Chip {
                        label: root.shownLogs === row.modelData.name ? "Hide log" : "󰦪  Log here"
                        selected: root.shownLogs === row.modelData.name
                        onPicked: root.toggleLogs(row.modelData.name)
                      }
                    }
                    Rectangle {
                      visible: root.shownLogs === row.modelData.name
                      width: parent.width
                      height: Style.space(180)
                      radius: Style.space(6)
                      color: Qt.rgba(0, 0, 0, 0.25)
                      clip: true
                      ListView {
                        id: logView
                        anchors.fill: parent
                        anchors.margins: Style.space(6)
                        model: root.shownLogs === row.modelData.name ? root.logLines : []
                        onCountChanged: positionViewAtEnd()
                        delegate: Text {
                          required property var modelData
                          width: logView.width
                          textFormat: Text.PlainText
                          wrapMode: Text.WrapAnywhere
                          text: modelData
                          color: root.fg
                          font.family: "monospace"
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                    Repeater {
                      model: root.backups
                      delegate: Row {
                        required property var modelData
                        spacing: Style.space(10)
                        Text {
                          width: Style.space(200)
                          elide: Text.ElideMiddle
                          text: modelData.path.split("/").pop() + "  ·  " + root.human(modelData.bytes)
                          color: root.fg
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          anchors.verticalCenter: parent.verticalCenter
                        }
                        Chip {
                          label: root.armedRestore === modelData.path ? "Click again: replaces data" : "Restore"
                          selected: root.armedRestore === modelData.path
                          onPicked: root.restoreBackup(row.modelData.name, modelData.path)
                        }
                      }
                    }
                  }
                }
              }

              Row {
                id: rowActions
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.top: parent.top
                anchors.topMargin: Style.space(14)
                spacing: Style.space(12)

                IconAction {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.omatable
                  text: "\uf0ce"
                  tip: "Open in OmaTablePlus"
                  onActivated: root.openInOmaTablePlus(row.modelData.name)
                }

                IconAction {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "\uf141"
                  color: root.shownTools === row.modelData.name ? Color.accent : Qt.darker(root.fg, 1.5)
                  tip: "Copy as, stack, log, back up, restore, port"
                  onActivated: root.toggleTools(row.modelData.name)
                }

                IconAction {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰌆"
                  color: rowText.showCreds ? Color.accent : Qt.darker(root.fg, 1.5)
                  tip: rowText.showCreds ? "Hide username and password" : "Show username and password"
                  onActivated: root.shownCreds = rowText.showCreds ? "" : row.modelData.name
                }

                IconAction {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰆏"
                  tip: "Copy connection URL"
                  onActivated: root.copyUrl(row.modelData.name)
                }

                IconAction {
                  anchors.verticalCenter: parent.verticalCenter
                  text: ""
                  tip: "Open CLI client"
                  onActivated: root.launch(["client", row.modelData.name])
                }

                IconAction {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰦪"
                  tip: "Show logs"
                  onActivated: root.launch(["logs", row.modelData.name])
                }

                IconAction {
                  anchors.verticalCenter: parent.verticalCenter
                  text: row.modelData.autostart ? "󰐥" : "󰐦"
                  color: row.modelData.autostart ? Color.accent : Qt.darker(root.fg, 1.5)
                  tip: row.modelData.autostart ? "Starts with the system · click to turn off" : "Start with the system"
                  onActivated: root.run(row.modelData.name, "Saving", ["autostart", row.modelData.name, row.modelData.autostart ? "off" : "on"])
                }

                IconAction {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰆴"
                  hoverColor: Color.urgent
                  color: row.armed ? Color.urgent : Qt.darker(root.fg, 1.5)
                  tip: "Delete server and its data"
                  onActivated: root.removeService(row.modelData.name)
                }

                ToggleSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  checked: row.modelData.running
                  busy: row.busy
                  foreground: root.fg
                  accent: Color.accent
                  onToggled: root.run(row.modelData.name, row.modelData.running ? "Stopping" : "Starting",
                                [row.modelData.running ? "stop" : "start", row.modelData.name])
                            }
                          }
                        }
                      }
                      }
                    }

                    PanelSeparator { foreground: root.fg }

        // New server
        PanelSectionHeader {
          text: "NEW SERVER"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Label { text: "Run as" }
        Flow {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: [{ label: "󰆼 Native engine", value: "native" }, { label: "󰡨 Docker container", value: "docker" }]
            Chip {
              required property var modelData
              label: modelData.label
              selected: root.newMode === modelData.value
              onPicked: {
                root.newMode = modelData.value
                // Docker-only engines (PostGIS) cannot run natively.
                if (modelData.value === "native" && root.newEngineInfo.dockerOnly) root.pickEngine("postgresql")
              }
            }
          }
        }

        Label { text: "Engine" }
        Flow {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: root.engines
            Chip {
              required property var modelData
              // Docker-only engines (PostGIS) carry the Docker mark and switch the form to Docker.
              label: modelData.dockerOnly ? modelData.title + " 󰡨" : modelData.title
              selected: root.newEngine === modelData.id
              onPicked: {
                if (modelData.dockerOnly) root.newMode = "docker"
                root.pickEngine(modelData.id)
              }
            }
          }
        }

        Label { text: "Version" }
        Flow {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: root.newEngineInfo.versions
            Chip {
              required property var modelData
              label: root.newMode === "native" && !root.isInstalled(root.newEngine, modelData) ? modelData + " 󰇚" : modelData
              selected: root.newVersion === modelData
              onPicked: root.newVersion = modelData
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Column {
            width: (parent.width - parent.spacing) * 0.62
            spacing: Style.space(4)
            Label { text: "Name" }
            TextField {
              id: nameField
              width: parent.width
              foreground: root.fg
              placeholderText: root.defaultName
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.createService(); event.accepted = true }
                else if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
              }
            }
          }

          Column {
            width: (parent.width - parent.spacing) * 0.38
            spacing: Style.space(4)
            Label { text: "Port" }
            TextField {
              id: portField
              width: parent.width
              foreground: root.fg
              placeholderText: root.suggestedPort || "auto"
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.createService(); event.accepted = true }
                else if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
              }
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.space(4)
            Label { text: "Username" }
            TextField {
              id: userField
              width: parent.width
              foreground: root.fg
              placeholderText: root.defaultUser || "none (no auth)"
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.createService(); event.accepted = true }
                else if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
              }
            }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.space(4)
            Label { text: "Password" }
            TextField {
              id: passField
              width: parent.width
              foreground: root.fg
              placeholderText: "none"
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.createService(); event.accepted = true }
                else if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
              }
            }
          }
        }

        Item {
          width: parent.width
          implicitHeight: createChip.height

          Chip {
            id: autostartChip
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            label: root.newAutostart ? "󰐥 Start with system" : "󰐦 Start with system"
            selected: root.newAutostart
            onPicked: root.newAutostart = !root.newAutostart
          }

          Chip {
            id: createChip
            anchors.right: parent.right
            label: root.busyLabel === "Creating" ? (root.busyDetail ? root.busyDetail.split(" ")[0] + "…" : "Creating…") : "󰐕 Create"
            selected: true
            enabled: (root.newMode === "native" || root.dockerUp) && root.newVersion !== "" && root.busyLabel !== "Creating"
            onPicked: root.createService()
          }
        }

        Label {
          width: parent.width
          wrapMode: Text.Wrap
          text: {
            const e = root.newEngine
            const u = userField.text.trim() || root.defaultUser
            const user = (u ? "User " + u : "No user") + (passField.text ? ", with password" : ", no password")
              + ((e === "mysql" || e === "mariadb") && passField.text && u !== "root" ? " (root gets the same password)" : "") + ". "
            if (root.newMode === "docker") return user + "Runs in a Docker container; data is kept in a Docker volume until you delete the server."
            return user + "Runs the engine itself: 󰇚 versions are downloaded once to ~/.local/share/omadbngin, data stays there until you delete the server."
          }
          color: Qt.darker(root.fg, 1.6)
        }

        Text {
          width: parent.width
          visible: root.errorText !== ""
          textFormat: Text.PlainText
          text: root.errorText
          color: Color.urgent
          wrapMode: Text.Wrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Column {
        id: settingsPage
        visible: root.page === "settings"
        width: parent.width
        spacing: Style.space(8)


        PanelSeparator { foreground: root.fg }
        PanelSectionHeader { text: "POSITION ON THE BAR"; foreground: root.fg; fontFamily: root.fontFamily }
        Label {
          text: root.selfAt ? "Now: " + root.selfAt.section + ", place " + (root.selfAt.index + 1) : "OmaDBngin is not in the bar layout"
        }
        Flow {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: [["left", "Left"], ["center", "Center"], ["right", "Right"]]
            Chip {
              required property var modelData
              label: modelData[1]
              selected: root.moveSection === modelData[0]
              onPicked: { root.moveSection = modelData[0]; root.moveAnchor = -1 }
            }
          }
        }
        Flow {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: [["first", "First"], ["last", "Last"], ["before", "Before…"], ["after", "After…"]]
            Chip {
              required property var modelData
              label: modelData[1]
              selected: root.movePlace === modelData[0]
              enabled: modelData[0] === "first" || modelData[0] === "last" || root.moveNeighbours.length > 0
              onPicked: root.movePlace = modelData[0]
            }
          }
        }
        Flow {
          visible: root.movePlace === "before" || root.movePlace === "after"
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: root.moveNeighbours
            Chip {
              required property var modelData
              // copies of one plugin share an id: each is named by the widget it shows
              label: (modelData.glyph ? modelData.glyph + "  " : "") + modelData.label
              selected: root.moveAnchor === modelData.index
              onPicked: root.moveAnchor = modelData.index
            }
          }
        }
        Chip {
          label: "Move"
          selected: true
          onPicked: root.moveOnBar()
        }

        PanelSeparator { foreground: root.fg }
        PanelSectionHeader { text: "BAR ICON"; foreground: root.fg; fontFamily: root.fontFamily }
        SettingRow {
          title: "Running count"
          Row {
            spacing: Style.space(6)
            Repeater {
              model: ["Badge", "Text", "Hidden"]
              Chip {
                required property var modelData
                label: modelData
                selected: root.countStyle === modelData
                onPicked: root.saveSettings({ countStyle: modelData, label: null })
              }
            }
          }
        }
        SettingRow {
          title: "Red dot when a server stops on its own"
          ToggleSwitch {
            checked: root.crashDot
            foreground: root.fg
            accent: Color.accent
            onToggled: root.saveSettings({ crashDot: !root.crashDot })
          }
        }

        PanelSeparator { foreground: root.fg }
        PanelSectionHeader { text: "PANEL"; foreground: root.fg; fontFamily: root.fontFamily }
        SettingRow {
          title: "Rows"
          Row {
            spacing: Style.space(6)
            Repeater {
              model: ["Detailed", "Compact"]
              Chip {
                required property var modelData
                label: modelData
                selected: (root.compact ? "Compact" : "Detailed") === modelData
                onPicked: root.saveSettings({ rowStyle: modelData })
              }
            }
          }
        }
        SettingRow {
          title: "CPU, memory and readiness while open"
          ToggleSwitch {
            checked: root.statsOn
            foreground: root.fg
            accent: Color.accent
            onToggled: root.saveSettings({ stats: !root.statsOn })
          }
        }
        SettingRow {
          title: "New servers run as"
          Row {
            spacing: Style.space(6)
            Repeater {
              model: ["Native", "Docker"]
              Chip {
                required property var modelData
                label: modelData
                selected: (root.defaultMode === "docker" ? "Docker" : "Native") === modelData
                onPicked: { root.newMode = modelData.toLowerCase(); root.saveSettings({ defaultMode: modelData }) }
              }
            }
          }
        }

        PanelSeparator { foreground: root.fg }
        PanelSectionHeader { text: "DEFAULTS FOR NEW SERVERS"; foreground: root.fg; fontFamily: root.fontFamily }
        Label { text: "Empty fields use the engine's own default. Enter saves." }
        Repeater {
          model: root.engines
          delegate: Item {
            required property var modelData
            width: settingsPage.width
            height: defPort.height
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: parent.modelData.title
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            TextField {
              id: defUser
              anchors.right: defPort.left
              anchors.rightMargin: Style.space(6)
              width: Style.space(120)
              foreground: root.fg
              visible: parent.modelData.id !== "mongodb"
              placeholderText: String(root.userDefaults[parent.modelData.id] || ({ postgresql: "postgres", postgis: "postgres", mysql: "root", mariadb: "root", redis: "default", valkey: "default" })[parent.modelData.id] || "user")
              onAccepted: {
                const v = text.trim()
                const next = Object.assign({}, root.userDefaults)
                if (v) next[parent.modelData.id] = v; else delete next[parent.modelData.id]
                root.saveSettings({ users: Object.keys(next).length ? next : null })
                text = ""
              }
            }
            TextField {
              id: defPort
              anchors.right: parent.right
              width: Style.space(80)
              foreground: root.fg
              placeholderText: String(root.portDefaults[parent.modelData.id] || parent.modelData.port)
              validator: IntValidator { bottom: 1024; top: 65535 }
              onAccepted: {
                const v = parseInt(text, 10)
                const next = Object.assign({}, root.portDefaults)
                if (v) next[parent.modelData.id] = v; else delete next[parent.modelData.id]
                root.saveSettings({ ports: Object.keys(next).length ? next : null })
                text = ""
              }
            }
          }
        }
        SettingRow {
          title: "Backup folder"
          TextField {
            width: Style.space(220)
            foreground: root.fg
            placeholderText: root.backupLabel
            onAccepted: { root.saveSettings({ backupDir: text.trim() || null }); text = "" }
          }
        }

        PanelSeparator { foreground: root.fg }
        PanelSectionHeader { text: "SHORTCUT"; foreground: root.fg; fontFamily: root.fontFamily }
        SettingRow {
          title: "SUPER+ALT+D opens this panel"
          Row {
            spacing: Style.space(6)
            Chip { label: "Add"; onPicked: root.shortcut(true) }
            Chip { label: "Remove"; onPicked: root.shortcut(false) }
          }
        }

        PanelSeparator { foreground: root.fg }
        Item {
          width: parent.width
          height: resetChip.height
          Chip {
            id: resetChip
            label: root.armedReset ? "Click again: reset every setting" : "Reset to defaults"
            selected: root.armedReset
            onPicked: root.resetSettings()
          }
        }
        Text {
          width: parent.width
          visible: root.settingsMessage !== ""
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: root.settingsMessage
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
