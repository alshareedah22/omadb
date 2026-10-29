const test = require("node:test")
const assert = require("node:assert")
const path = require("path")
const load = p => require("./load")(path.join("..", p))
const L = load("Layout.js")

function cfg() {
  return {
    bar: { layout: {
      left: [{ id: "omarchy.menu" }, { id: "omarchy.workspaces" }],
      center: [{ id: "omarchy.clock" }],
      right: [{ id: "omarchy.tray" }, { id: "blackcode.omadbngin", label: "Icon only" }, { id: "omarchy.audio" }]
    } },
    plugins: []
  }
}
const raw = c => L.serialize(c)
const layoutOf = plan => JSON.parse(plan.next).bar.layout

test("findSelf", () => {
  assert.deepStrictEqual(L.findSelf(cfg()), { section: "right", index: 1 })
  assert.deepStrictEqual(L.findSelf({ bar: { layout: {} } }), null)
})

test("neighbours lists the other widgets of a section with a name each", () => {
  assert.deepStrictEqual(L.neighbours(cfg(), "right").map(n => n.label), ["Tray", "Audio"])
  assert.deepStrictEqual(L.neighbours(cfg(), "center").map(n => n.label), ["Clock"])
})

function colorbar() {
  const c = cfg()
  c.bar.layout.right = [
    { id: "blackcode.omacolorbar", icon: "omarchy.tray" },
    { id: "blackcode.omacolorbar", icon: "omarchy.network" },
    { id: "blackcode.omadbngin" },
    { id: "blackcode.omacolorbar", icon: "omarchy.audio" },
    { id: "blackcode.omacolorbar" },
    { id: "blackcode.power-menu" }
  ]
  return c
}

test("copies of one plugin (OmaColorBar) are told apart by the widget they show", () => {
  const n = L.neighbours(colorbar(), "right")
  assert.deepStrictEqual(n.map(x => x.label), ["Tray", "Network", "Audio", "Network", "Power menu"])
  assert.deepStrictEqual(n.map(x => x.index), [0, 1, 2, 3, 4])
  assert.ok(n.every(x => typeof x.glyph === "string"))
  assert.strictEqual(n[0].glyph !== "", true)
})

test("before / after picks the exact copy by its place, not the shared id", () => {
  const ids = plan => layoutOf(plan).right.map(e => e.icon || e.id)
  assert.deepStrictEqual(ids(L.planMove(raw(colorbar()), "right", "after", 2)),
    ["omarchy.tray", "omarchy.network", "omarchy.audio", "blackcode.omadbngin", "blackcode.omacolorbar", "blackcode.power-menu"])
  assert.deepStrictEqual(ids(L.planMove(raw(colorbar()), "right", "before", 0)),
    ["blackcode.omadbngin", "omarchy.tray", "omarchy.network", "omarchy.audio", "blackcode.omacolorbar", "blackcode.power-menu"])
  assert.strictEqual(L.planMove(raw(colorbar()), "right", "after", 1).unchanged, true)
  assert.strictEqual(L.planMove(raw(colorbar()), "right", "after", 9).error, "anchor")
})

test("move first / last in another section keeps the entry and its settings", () => {
  const first = layoutOf(L.planMove(raw(cfg()), "left", "first", ""))
  assert.deepStrictEqual(first.left[0], { id: "blackcode.omadbngin", label: "Icon only" })
  assert.strictEqual(first.right.length, 2)
  const last = layoutOf(L.planMove(raw(cfg()), "center", "last", ""))
  assert.deepStrictEqual(last.center.map(e => e.id), ["omarchy.clock", "blackcode.omadbngin"])
})

test("move before / after a widget, also within the same section", () => {
  assert.deepStrictEqual(layoutOf(L.planMove(raw(cfg()), "right", "after", 1)).right.map(e => e.id),
    ["omarchy.tray", "omarchy.audio", "blackcode.omadbngin"])
  assert.deepStrictEqual(layoutOf(L.planMove(raw(cfg()), "left", "before", 1)).left.map(e => e.id),
    ["omarchy.menu", "blackcode.omadbngin", "omarchy.workspaces"])
})

test("move to where it already is is unchanged; bad input is refused", () => {
  assert.strictEqual(L.planMove(raw(cfg()), "right", "after", 0).unchanged, true)
  assert.strictEqual(L.planMove(raw(cfg()), "top", "first", "").error, "section")
  assert.strictEqual(L.planMove(raw(cfg()), "left", "after", 5).error, "anchor")
  assert.strictEqual(L.planMove("{nope", "left", "first", "").error, "invalid")
  const none = cfg(); none.bar.layout.right.splice(1, 1)
  assert.strictEqual(L.planMove(raw(none), "left", "first", "").error, "none")
})

test("planSettings changes only our entry; null removes a key", () => {
  const plan = L.planSettings(raw(cfg()), { countStyle: "Badge", label: null })
  const out = layoutOf(plan)
  assert.deepStrictEqual(out.right[1], { id: "blackcode.omadbngin", countStyle: "Badge" })
  assert.deepStrictEqual(out.left, cfg().bar.layout.left)
  assert.strictEqual(L.planSettings(raw(cfg()), { id: "x", label: "Icon only" }).unchanged, true)
})

test("resetSettings keeps only the id", () => {
  assert.deepStrictEqual(layoutOf(L.planReset(raw(cfg()))).right[1], { id: "blackcode.omadbngin" })
})

test("known plugins and widgets get their proper names", () => {
  const c = cfg()
  c.bar.layout.center = [{ id: "blackcode.omatableplus" }, { id: "omarchy.power" }, { id: "someone.my-widget" }]
  assert.deepStrictEqual(L.neighbours(c, "center").map(n => n.label), ["OmaTablePlus", "Battery", "My widget"])
})
