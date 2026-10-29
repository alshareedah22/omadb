.pragma library

// The OmaDBngin entry in shell.json's bar layout: where it sits and its settings. Pure: the
// panel reads the file, plans the change here, then writes the result itself (with a backup).

var PLUGIN_ID = "blackcode.omadbngin"
var SECTIONS = ["left", "center", "right"]

function serialize(config) { return JSON.stringify(config, null, 2) + "\n" }

function layoutOf(config) {
  var layout = config && config.bar ? config.bar.layout : null
  return layout && typeof layout === "object" ? layout : null
}

function findSelf(config) {
  var layout = layoutOf(config)
  if (!layout) return null
  for (var s = 0; s < SECTIONS.length; s++) {
    var list = Array.isArray(layout[SECTIONS[s]]) ? layout[SECTIONS[s]] : []
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === PLUGIN_ID) return { section: SECTIONS[s], index: i }
  }
  return null
}

// Glyphs (the Nerd Font the bar uses) for the widgets people usually have on the bar.
var GLYPHS = {
  "omarchy.menu": "\uf303", "omarchy.workspaces": "\udb81\udd70", "omarchy.clock": "\udb82\udd54",
  "omarchy.network": "\udb82\udd28", "omarchy.bluetooth": "\udb80\udcaf", "omarchy.audio": "\udb81\udd7e",
  "omarchy.microphone": "\udb80\udf6c", "omarchy.power": "\udb80\udc79", "omarchy.monitor": "\udb80\udf79",
  "omarchy.system-update": "\uf021", "omarchy.agents": "\udb85\udea3", "omarchy.tailscale": "\udb80\udf18",
  "omarchy.tray": "\uf053", "omarchy.weather": "\ue302", "omarchy.indicators": "\udb80\udc9a",
  "blackcode.power-menu": "\uf011", "blackcode.omatableplus": "\uf0ce", "blackcode.omalangy": "\uf0ac"
}

// Some plugins put several copies on the bar under one id and say which widget each copy is
// (OmaColorBar's `icon`; a copy without one is its network widget).
function shownId(entry) {
  if (entry.id === "blackcode.omacolorbar") return entry.icon ? String(entry.icon) : "omarchy.network"
  return String(entry.id)
}

var NAMES = {
  "omarchy.power": "Battery", "omarchy.system-update": "Updates", "blackcode.omatableplus": "OmaTablePlus",
  "blackcode.omalangy": "OmaLangy", "blackcode.omacleanmyarch": "OmaCleanMyArch", "blackcode.power-menu": "Power menu"
}

function nameOf(id) {
  if (NAMES[id]) return NAMES[id]
  var n = String(id).replace(/^[a-z0-9]+\./, "").replace(/-/g, " ")
  return n.charAt(0).toUpperCase() + n.slice(1)
}

// The other widgets of a section, in bar order: {index, id, label, glyph}. `index` is the
// widget's place in the section once OmaDBngin is taken out, which is what planMove takes.
function neighbours(config, section) {
  var layout = layoutOf(config)
  var list = layout && Array.isArray(layout[section]) ? layout[section] : []
  return list.filter(function(e) { return e && e.id && e.id !== PLUGIN_ID }).map(function(e, i) {
    var id = shownId(e)
    return { index: i, id: id, label: nameOf(id), glyph: GLYPHS[id] || "" }
  })
}

function parse(raw) {
  var config
  try { config = JSON.parse(raw) } catch (e) { return null }
  return config && layoutOf(config) ? config : null
}

function finish(raw, config) {
  var next = serialize(config)
  return next === raw ? { unchanged: true } : { next: next }
}

// Moves our entry to `section`, at `place`: "first", "last", or "before"/"after" the widget at
// index `anchor` of neighbours(config, section): by place, since copies of a plugin share one id.
// Returns {next} | {unchanged} | {error: "invalid" | "none" | "section" | "anchor" | "place"}.
function planMove(raw, section, place, anchor) {
  var config = parse(raw)
  if (!config) return { error: "invalid" }
  if (SECTIONS.indexOf(section) === -1) return { error: "section" }
  var at = findSelf(config)
  if (!at) return { error: "none" }
  var layout = config.bar.layout
  var entry = layout[at.section].splice(at.index, 1)[0]
  if (!Array.isArray(layout[section])) layout[section] = []
  var list = layout[section]
  var index
  if (place === "first") index = 0
  else if (place === "last") index = list.length
  else if (place === "before" || place === "after") {
    // the same filter as neighbours(): its index n is the n-th widget with an id
    var seen = -1, found = -1
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || !list[i].id) continue
      if (++seen === Number(anchor)) { found = i; break }
    }
    if (found === -1) return { error: "anchor" }
    index = place === "before" ? found : found + 1
  } else return { error: "place" }
  list.splice(index, 0, entry)
  return finish(raw, config)
}

// Sets keys on our entry (null removes one). `id` is never changed.
function planSettings(raw, changes) {
  var config = parse(raw)
  if (!config) return { error: "invalid" }
  var at = findSelf(config)
  if (!at) return { error: "none" }
  var entry = config.bar.layout[at.section][at.index]
  for (var key in changes) {
    if (key === "id") continue
    if (changes[key] === null) delete entry[key]
    else entry[key] = changes[key]
  }
  return finish(raw, config)
}

function planReset(raw) {
  var config = parse(raw)
  if (!config) return { error: "invalid" }
  var at = findSelf(config)
  if (!at) return { error: "none" }
  config.bar.layout[at.section][at.index] = { id: PLUGIN_ID }
  return finish(raw, config)
}
