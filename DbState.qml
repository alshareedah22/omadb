pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

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

  function refresh() {
    if (users <= 0) return
    if (stateProc.running) { refreshTimer.restart(); return }
    stateProc.running = true
  }
  // Coalesce bursts (events, several widgets asking at once) into one run.
  function refreshSoon() { refreshTimer.restart() }

  onUsersChanged: if (users > 0 && !snapshot) refresh()
  onViewersChanged: if (viewers > 0) refresh()

  Timer {
    id: refreshTimer
    interval: 250
    onTriggered: db.refresh()
  }

  // Health checks and image pulls do not always emit events; poll gently. Closed, only the bar
  // count matters, and starts, stops and failures already refresh through the event watchers.
  Timer {
    interval: db.viewers > 0 ? 3000 : 60000
    running: db.users > 0
    repeat: true
    onTriggered: db.refresh()
  }

  Process {
    id: stateProc
    command: [db.ctl, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { db.snapshot = JSON.parse(text) } catch (e) {}
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
