pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// One copy of the live state for every OmaDBngin bar widget: each monitor has its own bar, and
// without this every one of them polled dbctl and kept its own event watchers.
Singleton {
  id: db

  readonly property string ctl: decodeURIComponent(String(Qt.resolvedUrl("dbctl")).replace(/^(file|qs):\/\//, ""))

  // Widgets register while they exist (users) and while their panel is open (viewers):
  // nothing runs without a widget, and the poll is quick only while someone is looking.
  property int users: 0
  property int viewers: 0

  // The last `dbctl state`, parsed; null until the first one arrives.
  property var snapshot: null
  readonly property bool dockerUp: snapshot ? snapshot.docker === "running" : false

  // Stats (CPU, memory, readiness) are asked for only while a panel is open and stats are on.
  property bool stats: true
  readonly property bool full: viewers > 0 && stats
  // CPU % per server (100 = one core), from the CPU time between two snapshots.
  property var cpu: ({})
  property var lastCpu: ({})
  // Data size per server, read once each time a panel opens (dbctl caches it for 5 minutes).
  property var sizes: ({})

  // Servers that stopped on their own (failed unit, non-zero exit, out of memory). The bar
  // shows a red dot until the panel is opened (acknowledged) or the server runs again.
  readonly property var crashed: {
    var out = []
    var list = snapshot && snapshot.services ? snapshot.services : []
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      if (s.running) continue
      if (s.state === "failed" || s.oom || (s.exitCode && s.exitCode !== 143 && s.exitCode !== 130)) out.push(s.name)
    }
    return out
  }
  property var acked: ({})
  readonly property int unackedCrashes: crashed.filter(function(n) { return !acked[n] }).length
  function ackCrashes() {
    var next = {}
    crashed.forEach(function(n) { next[n] = true })
    acked = next
  }

  // A settings save rebuilds the bar: the panel on this screen opens again on its settings page.
  // The same request opens the settings from the command line:
  //   qs -p /usr/share/omarchy/shell ipc call omadbngin settings
  property string reopenScreen: ""
  property string reopenPage: ""

  IpcHandler {
    target: "omadbngin"
    function settings(): void {
      var monitor = Hyprland.focusedMonitor
      db.reopenScreen = monitor ? String(monitor.name) : ""
      db.reopenPage = "settings"
    }
  }

  function takeSnapshot(next) {
    var now = Date.now()
    var cpuNext = {}, last = {}
    var list = next && next.services ? next.services : []
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      if (s.cpuUsec === undefined) continue
      last[s.name] = { usec: s.cpuUsec, at: now }
      var prev = lastCpu[s.name]
      if (prev && now > prev.at && s.cpuUsec >= prev.usec)
        cpuNext[s.name] = Math.round((s.cpuUsec - prev.usec) / ((now - prev.at) * 1000) * 1000) / 10
    }
    lastCpu = last
    cpu = cpuNext
    // a server that runs again can crash again: forget that its last crash was seen
    var keep = {}
    for (var n in acked) if (!list.some(function(x) { return x.name === n && x.running })) keep[n] = true
    acked = keep
    snapshot = next
  }

  function refresh() {
    if (users <= 0) return
    if (stateProc.running) { refreshTimer.restart(); return }
    stateProc.running = true
  }
  // Coalesce bursts (events, several widgets asking at once) into one run.
  function refreshSoon() { refreshTimer.restart() }

  onUsersChanged: if (users > 0 && !snapshot) { refresh(); if (!setupDone) { setupDone = true; setupProc.running = true } }

  // Zero configuration: the first time the widget runs, `dbctl setup` adds the SUPER+ALT+D
  // shortcut when that key is free. Later starts find its marker and do nothing.
  property bool setupDone: false
  Process {
    id: setupProc
    command: [db.ctl, "setup"]
    stdout: StdioCollector { onStreamFinished: if (text.trim() !== "already set up") console.info("OmaDBngin: " + text.trim()) }
    stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") console.warn("OmaDBngin: " + text.trim()) }
  }
  onViewersChanged: if (viewers > 0) { refresh(); if (!sizesProc.running) sizesProc.running = true }

  Timer {
    id: refreshTimer
    interval: 250
    onTriggered: db.refresh()
  }

  // Health checks and image pulls do not always emit events; poll gently. Closed, only the bar
  // count matters, and starts, stops and failures already refresh through the event watchers.
  Timer {
    interval: db.viewers > 0 ? 5000 : 60000
    running: db.users > 0
    repeat: true
    onTriggered: db.refresh()
  }

  Process {
    id: stateProc
    command: db.full ? [db.ctl, "state", "--full"] : [db.ctl, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { db.takeSnapshot(JSON.parse(text)) } catch (e) {}
      }
    }
  }

  Process {
    id: sizesProc
    command: [db.ctl, "sizes"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { db.sizes = JSON.parse(text) } catch (e) {}
      }
    }
  }

  // Live updates: Docker reports every start, stop and removal of our containers.
  Process {
    id: eventsProc
    running: db.users > 0 && db.dockerUp
    // Straight from the socket when possible: curl stays at ~1 MB, the docker client at ~18 MB.
    command: ["sh", "-c", "s=${DOCKER_HOST:-unix:///var/run/docker.sock}; s=${s#unix://}; "
      + "if [ -S \"$s\" ] && command -v curl >/dev/null; then exec curl -sfN --unix-socket \"$s\" "
      + "'http://docker/events?filters=%7B%22label%22%3A%5B%22omadbngin.managed%3D1%22%5D%2C%22type%22%3A%5B%22container%22%5D%7D'; "
      + "else exec docker events --filter label=omadbngin.managed=1 --filter type=container --format '{{.Action}}'; fi"]
    stdout: SplitParser { onRead: function(line) { db.refreshSoon() } }
    onExited: eventsRestart.restart()
  }

  // Native servers: systemd logs every start and stop of an omadbngin-* unit.
  Process {
    id: nativeEventsProc
    running: db.users > 0
    command: ["journalctl", "--user", "-f", "-n", "0", "-o", "cat", "-u", "omadbngin-*.service"]
    // Only systemd's own lines ("Started OmaDBngin …", "omadbngin-x.service: Failed …"), not server logs.
    stdout: SplitParser { onRead: function(line) { if (/OmaDBngin|omadbngin-[^ ]*\.service/.test(String(line))) db.refreshSoon() } }
    onExited: nativeEventsRestart.restart()
  }

  Timer {
    id: nativeEventsRestart
    interval: 5000
    onTriggered: if (db.users > 0) nativeEventsProc.running = true
  }

  Timer {
    id: eventsRestart
    interval: 5000
    onTriggered: if (db.users > 0 && db.dockerUp) eventsProc.running = true
  }
}
