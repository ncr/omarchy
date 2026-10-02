#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# omarchy-theme-bg-set links a monitor's own background and asks the shell to
# reread them. A stub omarchy-shell records the IPC calls.
mkdir -p "$tmp/home" "$tmp/bin" "$tmp/pictures/ultrawide"
cat >"$tmp/bin/omarchy-shell" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$tmp/ipc.log"
STUB
chmod +x "$tmp/bin/omarchy-shell"
touch "$tmp/pictures/portrait.png" "$tmp/pictures/clip.mp4" "$tmp/pictures/shared.png"
touch "$tmp/pictures/ultrawide/1-dawn.webp" "$tmp/pictures/ultrawide/2-dusk.PNG" "$tmp/pictures/ultrawide/notes.txt" "$tmp/pictures/ultrawide/loop.mp4"
mkdir "$tmp/pictures/ultrawide/nested"

bg_set() {
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" "$ROOT/bin/omarchy-theme-bg-set" "$@"
}

monitor_backgrounds="$tmp/home/.local/state/omarchy/current/monitor-backgrounds"

bg_set --monitor DP-1 "$tmp/pictures/portrait.png" || fail "a monitor takes an image"
[[ $(readlink "$monitor_backgrounds/DP-1") == "$tmp/pictures/portrait.png" ]] || fail "a monitor's image is linked under its output name"
[[ $(tail -n 1 "$tmp/ipc.log") == "-q background refreshMonitors" ]] || fail "setting a monitor's background asks the shell to reread them"
pass "a monitor takes an image"

bg_set --monitor HDMI-A-1 "$tmp/pictures/ultrawide" || fail "a monitor takes a folder"
[[ $(readlink "$monitor_backgrounds/HDMI-A-1") == "$tmp/pictures/ultrawide" ]] || fail "a monitor's folder is linked under its output name"
pass "a monitor takes a folder"

if bg_set --monitor DP-1 "$tmp/pictures/clip.mp4" 2>/dev/null; then
  fail "a monitor rejects a video"
fi
[[ $(readlink "$monitor_backgrounds/DP-1") == "$tmp/pictures/portrait.png" ]] || fail "a rejected video leaves the monitor's image"
pass "a monitor rejects a video, which plays on every monitor"

if bg_set --monitor ../DP-1 "$tmp/pictures/portrait.png" 2>/dev/null || bg_set --monitor DP-1 "$tmp/pictures/missing.png" 2>/dev/null; then
  fail "invalid monitor names and missing files are rejected"
fi
[[ ! -e $tmp/home/.local/state/omarchy/current/DP-1 ]] || fail "a monitor name cannot leave the monitor backgrounds folder"
pass "invalid monitor names and missing files are rejected"

# The shell's listing of monitor backgrounds.
listing=$("$ROOT/shell/plugins/background/monitor-backgrounds.sh" "$monitor_backgrounds")
expected="DP-1"$'\t'"image"$'\t'"$tmp/pictures/portrait.png"$'\n'"HDMI-A-1"$'\t'"folder"$'\t'"$tmp/pictures/ultrawide"$'\t'"1-dawn.webp"$'\t'"2-dusk.PNG"
[[ $listing == "$expected" ]] || fail "the listing names each monitor's image, or its folder and the images in it" "$listing"
pass "the listing names each monitor's image, or its folder and the images in it"

ln -s "$tmp/pictures/gone.png" "$monitor_backgrounds/DP-2"
ln -s "$tmp/pictures/clip.mp4" "$monitor_backgrounds/DP-3"
listing=$("$ROOT/shell/plugins/background/monitor-backgrounds.sh" "$monitor_backgrounds")
[[ $listing == "$expected" ]] || fail "the listing skips links to missing files and to videos" "$listing"
pass "the listing skips links to missing files and to videos"

[[ -z $("$ROOT/shell/plugins/background/monitor-backgrounds.sh" "$tmp/nowhere") ]] || fail "no monitor backgrounds lists nothing"
pass "no monitor backgrounds lists nothing"

bg_set --monitor DP-1 --clear || fail "a monitor's background clears"
[[ ! -L $monitor_backgrounds/DP-1 ]] || fail "clearing removes the monitor's link"
pass "a monitor's background clears"

# The shared background is set exactly as before, and leaves monitors alone.
bg_set "$tmp/pictures/shared.png" || fail "the shared background still sets"
[[ $(readlink "$tmp/home/.local/state/omarchy/current/background") == "$tmp/pictures/shared.png" ]] || fail "the shared background is the current background link"
[[ $(tail -n 1 "$tmp/ipc.log") == "-q background set $tmp/pictures/shared.png" ]] || fail "the shared background updates the shell as before"
[[ -L $monitor_backgrounds/HDMI-A-1 ]] || fail "setting the shared background keeps monitors' own backgrounds"
pass "the shared background sets as before and keeps monitors' own backgrounds"

if bg_set --clear 2>/dev/null; then
  fail "--clear needs a monitor"
fi
pass "--clear needs a monitor"

export LISTING="$listing" PICTURES="$tmp/pictures"
run_node_test <<'JS'
const fs = require('fs')
const monitors = requireFromRoot('shell/plugins/background/MonitorBackgrounds.js')
const pictures = process.env.PICTURES

const backgrounds = monitors.parse(process.env.LISTING)
assertDeepEqual(Object.keys(backgrounds), ['DP-1', 'HDMI-A-1'], 'parse reads one entry per monitor')
assertEqual(backgrounds['HDMI-A-1'].folder, true, 'parse marks folders')
assertDeepEqual(Object.keys(backgrounds['HDMI-A-1'].names), ['1-dawn.webp', '2-dusk.PNG'], 'parse keeps the image names in a folder')
assertDeepEqual(monitors.parse(''), {}, 'an empty listing has no monitor backgrounds')

const shared = '/home/me/.local/state/omarchy/current/theme/backgrounds/1-dawn.webp'
assertEqual(monitors.resolve(backgrounds, 'eDP-1', shared, shared), shared, 'a monitor without its own background shows the shared one')
assertEqual(monitors.resolve(backgrounds, 'DP-1', shared, shared), pictures + '/portrait.png', 'a monitor with an image always shows it')
assertEqual(monitors.resolve(backgrounds, 'HDMI-A-1', shared, shared), pictures + '/ultrawide/1-dawn.webp', 'a monitor with a folder shows its file of the same name')
const other = '/home/me/.local/state/omarchy/current/theme/backgrounds/3-noon.webp'
assertEqual(monitors.resolve(backgrounds, 'HDMI-A-1', other, other), other, 'a folder without that name falls back to the shared background')
const snapshot = '/home/me/.cache/omarchy/background-transitions/next-123.webp'
assertEqual(monitors.resolve(backgrounds, 'HDMI-A-1', snapshot, shared), pictures + '/ultrawide/1-dawn.webp', 'a folder matches a transition snapshot by its lasting name')
assertEqual(monitors.resolve(backgrounds, 'DP-1', '', ''), '', 'no shared frame means no frame for any monitor')
assertDeepEqual(
  monitors.paths(backgrounds, [shared]).sort(),
  [pictures + '/portrait.png', pictures + '/ultrawide/1-dawn.webp'].sort(),
  'paths lists what monitors show for a shared background'
)
assert(monitors.same(monitors.parse(process.env.LISTING), backgrounds) && !monitors.same({}, backgrounds), 'same compares listings')

const backgroundQml = fs.readFileSync(path.join(root, 'shell/plugins/background/Background.qml'), 'utf8')
assert(
  /function refreshMonitors\(\): void \{\s*root\.refreshMonitorBackgrounds\(\)/.test(backgroundQml) &&
    backgroundQml.includes('command: [root.omarchyPath + "/shell/plugins/background/monitor-backgrounds.sh"]'),
  'the shell rereads monitor backgrounds over IPC'
)
assert(
  backgroundQml.includes('readonly property string basePath: root.monitorPath(outputName, root.displayedBackground, root.displayedBackground, root.displayedMonitorBackgrounds)') &&
    backgroundQml.includes('readonly property string oldPath: root.monitorPath(outputName, root.oldBackground, root.oldDurableBackground, root.displayedMonitorBackgrounds)') &&
    backgroundQml.includes('? root.monitorPath(outputName, root.incomingBackground, root.currentBackground, root.monitorBackgrounds)'),
  'the base and outgoing frames follow the monitor backgrounds on screen, the incoming frame the newest'
)
assert(
  /root\.displayedBackground = root\.currentBackground \|\| root\.incomingBackground\s*root\.displayedMonitorBackgrounds = root\.monitorBackgrounds/.test(backgroundQml) &&
    /displayedBackground = finalPath\s*displayedMonitorBackgrounds = monitorBackgrounds/.test(backgroundQml),
  'a finished or instant change puts the newest monitor backgrounds on screen'
)
assert(
  /function finishTransitionIfSettled\(\) \{[\s\S]*?if \(!panels\[i\]\.baseSettled\) return/.test(backgroundQml) &&
    /onReadyChanged: \{\s*if \(ready\) Qt\.callLater\(root\.finishTransitionIfSettled\)/.test(backgroundQml),
  'the transition frames stay up until every monitor has its base frame'
)
assert(
  backgroundQml.includes('!monitorsChange(fromPath || displayedBackground, fromDurable, path, finalPath)'),
  'a change no monitor would show switches without a reveal'
)
JS
