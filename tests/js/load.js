// Loads a QML ".pragma library" JavaScript file into Node: drops the pragma and any
// ".import" lines and returns every top-level function and var.
const fs = require("fs")
const path = require("path")

module.exports = function load(file) {
  const src = fs.readFileSync(path.join(__dirname, "..", file), "utf8")
    .replace(/^\.pragma library\s*$/m, "")
    .replace(/^\.import .*$/gm, "")
  const names = [...src.matchAll(/^(?:function\s+(\w+)|var\s+(\w+))/gm)].map(m => m[1] || m[2])
  return new Function(src + "\nreturn {" + names.join(",") + "}")()
}
