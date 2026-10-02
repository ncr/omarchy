// A monitor can show its own background instead of the shared one. Each one is
// a link at ~/.local/state/omarchy/current/monitor-backgrounds/<output>, to an
// image or to a folder. A folder holds versions of the shared backgrounds made
// for that monitor's shape, under the same file names.

function basename(path) {
  return String(path || "").split("/").pop()
}

// Reads monitor-backgrounds.sh: one line per monitor, its output name and
// target, then for a folder the image names it holds, separated by tabs.
function parse(text) {
  var backgrounds = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var fields = lines[i].split("\t")
    if (fields.length < 3 || !fields[0] || !fields[2]) continue
    if (fields[1] === "image") {
      backgrounds[fields[0]] = { path: fields[2], folder: false, names: {} }
    } else if (fields[1] === "folder") {
      var names = {}
      for (var j = 3; j < fields.length; j++) {
        if (fields[j]) names[fields[j]] = true
      }
      backgrounds[fields[0]] = { path: fields[2], folder: true, names: names }
    }
  }
  return backgrounds
}

// The path a monitor shows for the shared background `path`. `durable` is the
// background's lasting path when `path` is a transition snapshot, so a folder
// can match it by name. A folder without that name falls back to the shared one.
function resolve(backgrounds, output, path, durable) {
  var background = backgrounds ? backgrounds[output] : undefined
  if (!background || !path) return path
  if (!background.folder) return background.path

  var name = basename(durable || path)
  return background.names[name] ? background.path + "/" + name : path
}

// Every path a monitor could be showing for these shared backgrounds.
function paths(backgrounds, sharedPaths) {
  var found = []
  for (var output in backgrounds) {
    for (var i = 0; i < sharedPaths.length; i++) {
      var path = resolve(backgrounds, output, sharedPaths[i], sharedPaths[i])
      if (path && found.indexOf(path) === -1) found.push(path)
    }
  }
  return found
}

function same(a, b) {
  return JSON.stringify(a || {}) === JSON.stringify(b || {})
}

if (typeof module !== "undefined") {
  module.exports = {
    basename: basename,
    parse: parse,
    resolve: resolve,
    paths: paths,
    same: same
  }
}
