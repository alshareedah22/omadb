import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "blackcode.omadbngin"
  ipcTarget: "blackcode.omadbngin"
  manageIpc: true

  // ---- Settings (shell.json → this widget's bar entry; see manifest schema) ----
  readonly property string labelStyle: String(setting("label", "Icon and count"))
  readonly property string defaultMode: String(setting("defaultMode", "Native")) === "Docker" ? "docker" : "native"

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
  property bool omatable: false       // OmaTable is installed: offer Open in OmaTable

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
    if (s.size) parts.push(human(s.size) + " data")
    if (s.running && s.memory) parts.push(human(s.memory) + " RAM")
    return parts.join("  ·  ")
  }
  function openInOmaTable(name) {
    root.close()
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "blackcode.omatable", JSON.stringify({ connect: "omadb:" + name })])
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
    backupsProc.running = true
  }
  function restoreBackup(name, path) {
    if (root.armedRestore !== path) { root.armedRestore = path; return }
    root.armedRestore = ""
    run(name, "Restoring", ["restore", name, path])
  }

  function refresh() {
    if (stateProc.running) { refreshTimer.restart(); return }
    stateProc.running = true
  }

  function run(name, label, args) {
    root.errorText = ""
    root.queue = root.queue.concat([{ name: name, label: label, command: [root.ctl].concat(args) }])
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
    actionProc.running = true
  }

  function launch(args) {
    root.close()
    Quickshell.execDetached([root.ctl].concat(args))
  }

  function copyUrl(name) {
    Quickshell.execDetached([root.ctl, "copy", name])
    root.copiedName = name
    copiedTimer.restart()
  }

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
    if (s.state === "failed") return "Failed · see logs"
    if (s.state === "running") return s.health === "starting" ? "Starting…" : "Running"
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
    const base = newEngine + "-" + String(newVersion || "").split(".")[0]
    const taken = {}
    services.forEach(function(s) { taken[s.name] = true })
    if (!taken[base]) return base
    for (let i = 2; ; i++) if (!taken[base + "-" + i]) return base + "-" + i
  }

  readonly property string defaultUser: ({ postgresql: "postgres", mysql: "root", mariadb: "root", redis: "default", valkey: "default" })[newEngine] || ""

  function pickEngine(id) {
    root.newEngine = id
    const info = engineInfo(id)
    root.newVersion = info.versions.length > 0 ? info.versions[0] : ""
    root.suggestedPort = ""
    portField.text = ""
    if (!portProc.running) { portProc.command = [root.ctl, "port", id]; portProc.running = true }
  }

  function createService() {
    const name = nameField.text.trim() || root.defaultName
    const port = portField.text.trim() || root.suggestedPort
    if (!/^[a-z0-9][a-z0-9-]{0,40}$/.test(name)) { root.errorText = "Name: lowercase letters, digits and dashes."; return }
    const user = userField.text.trim()
    const pass = passField.text
    if (root.newEngine === "mongodb" && user !== "" && pass === "") { root.errorText = "MongoDB needs a password when you set a username."; return }
    run(name, "Creating", ["create", root.newEngine, root.newVersion, name, port, root.newAutostart ? "on" : "off", root.newMode, user, pass])
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

  Component.onCompleted: refresh()

  onOpenedChanged: {
    root.portFocus = false
    if (opened) {
      refresh()
      root.errorText = ""
      root.armedDelete = ""
      if (root.newVersion === "" && root.engines.length > 0) pickEngine(root.newEngine)
      else if (!portProc.running) { portProc.command = [root.ctl, "port", root.newEngine]; portProc.running = true }
    }
  }

  onEnginesChanged: if (root.newVersion === "" && root.engines.length > 0) pickEngine(root.newEngine)

  Timer {
    id: refreshTimer
    interval: 250
    onTriggered: root.refresh()
  }

  // Health checks and image pulls do not always emit events; poll gently.
  Timer {
    interval: root.opened ? 3000 : 30000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

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
    id: stateProc
    command: [root.ctl, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let s
        try { s = JSON.parse(text) } catch (e) { return }
        root.omatable = !!s.omatable
        root.dockerStatus = s.docker || "missing"
        root.engines = s.engines || []
        // a new list rebuilds the rows, which would take the port field's focus (and draft) mid-typing
        if (!root.portFocus) root.services = s.services || []
        root.installed = s.installed || []
        root.stateLoaded = true
      }
    }
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
      if (root.opened && !portProc.running) { portProc.command = [root.ctl, "port", root.newEngine]; portProc.running = true }
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

  // Live updates: Docker reports every start, stop and removal of our containers.
  Process {
    id: eventsProc
    running: root.dockerUp
    command: ["docker", "events", "--filter", "label=omadbngin.managed=1", "--filter", "type=container", "--format", "{{.Action}}"]
    stdout: SplitParser { onRead: function(line) { refreshTimer.restart() } }
    onExited: eventsRestart.restart()
  }

  // Native servers: systemd logs every start and stop of an omadbngin-* unit.
  Process {
    id: nativeEventsProc
    running: true
    command: ["journalctl", "--user", "-f", "-n", "0", "-o", "cat", "-u", "omadbngin-*.service"]
    // Only systemd's own lines ("Started OmaDBngin …", "omadbngin-x.service: Failed …"), not server logs.
    stdout: SplitParser { onRead: function(line) { if (/OmaDBngin|omadbngin-[^ ]*\.service/.test(String(line))) refreshTimer.restart() } }
    onExited: nativeEventsRestart.restart()
  }

  Timer {
    id: nativeEventsRestart
    interval: 5000
    onTriggered: nativeEventsProc.running = true
  }

  Timer {
    id: eventsRestart
    interval: 5000
    onTriggered: if (root.dockerUp) eventsProc.running = true
  }

  // ---- Small building blocks ----
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
    // The label is drawn by barIcon below: a color database icon plus the running count.
    text: "󰆼"
    labelVisible: false
    fixedWidth: vertical ? -1 : barIcon.implicitWidth + Style.spaceReal(6) * 2
    fontSize: Style.font.caption
    horizontalMargin: 6
    tooltipText: root.services.length === 0 ? "Databases" : root.services.map(function(s) {
      return (s.running ? "● " : "○ ") + s.name + "  :" + s.port
    }).join("\n")
    onPressed: function(b) { root.toggle() }
    Row {
      id: barIcon
      anchors.centerIn: parent
      spacing: Math.round(Style.font.caption * 0.3)
      Image {
        anchors.verticalCenter: parent.verticalCenter
        source: Qt.resolvedUrl("icon.svg")
        width: Math.round(Style.font.caption * 1.35)
        height: width
        sourceSize: Qt.size(width * 2, height * 2)
        smooth: true
        opacity: root.runningCount > 0 ? 1 : 0.55
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.labelStyle !== "Icon only" && root.runningCount > 0
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

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: parent.right
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
            text: root.runningCount + " RUNNING  ·  " + root.services.length + " SERVERS"
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

      Column {
        width: parent.width
        spacing: Style.space(2)

        Repeater {
          model: root.services

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
                  + root.engineInfo(row.modelData.engine).title + " " + (row.modelData.exact || row.modelData.version)
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
                text: [root.copiedName === row.modelData.name ? "URL copied" : root.statusText(row.modelData), root.health(row.modelData)]
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
              Column {
                width: parent.width
                visible: root.shownTools === row.modelData.name
                spacing: Style.space(6)
                topPadding: Style.space(6)
                Row {
                  spacing: Style.space(8)
                  Chip {
                    label: row.modelData.engine === "mongodb" ? "Back up in OmaTable" : "󰁯  Back up to ~/Downloads"
                    onPicked: row.modelData.engine === "mongodb" ? root.openInOmaTable(row.modelData.name)
                      : root.run(row.modelData.name, "Backing up", ["backup", row.modelData.name])
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
                  text: "No backups of " + row.modelData.name + " in ~/Downloads yet"
                  color: Qt.darker(root.fg, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
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
                tip: "Open in OmaTable"
                onActivated: root.openInOmaTable(row.modelData.name)
              }

              IconAction {
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf141"
                color: root.shownTools === row.modelData.name ? Color.accent : Qt.darker(root.fg, 1.5)
                tip: "Back up, restore, change port"
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
            onPicked: root.newMode = modelData.value
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
            label: modelData.title
            selected: root.newEngine === modelData.id
            onPicked: root.pickEngine(modelData.id)
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
  }
}
