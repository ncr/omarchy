import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Ui
import "MonitorBackgrounds.js" as MonitorBackgrounds

Item {
  id: root

  property var shell: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  // A theme switch names its next background before it has staged the rest of
  // the theme, so the incoming frame can decode while that work runs. A large
  // WebP takes ~130ms to decode at any sourceSize, which the reveal would
  // otherwise wait out after the transition arrives.
  property string preparedBackground: ""
  // The prepare and transition calls travel as separate IPC clients, so a
  // prepare can land after its transition. The path it names then must not be
  // decoded again.
  property string lastTransitionPath: ""
  // Native pixel size per wallpaper path, read from the file header before
  // the image loads. Decoding at screen size only saves memory for wallpapers
  // at least as large as the screen: with PreserveAspectCrop Qt scales the
  // decode up to cover sourceSize, so a smaller wallpaper would cost the
  // screen's worth of pixels instead of its own.
  property var nativeSizes: ({})
  property var sizeQueue: []
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1
  // Monitors that show their own background, by output name (see
  // MonitorBackgrounds.js). The base and outgoing frames follow the map that is
  // on screen, the incoming frame the newest one, so a change reveals like any
  // other background change.
  property var monitorBackgrounds: ({})
  property var displayedMonitorBackgrounds: ({})
  property bool monitorBackgroundsLoaded: false
  property bool monitorBackgroundsQueued: false
  property string oldDurableBackground: ""

  function isVideo(path) {
    return Util.isVideoPath(path)
  }

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshMonitorBackgrounds() {
    if (monitorBackgroundsProc.running) monitorBackgroundsQueued = true
    else monitorBackgroundsProc.running = true
  }

  function monitorPath(output, path, durable, backgrounds) {
    return MonitorBackgrounds.resolve(backgrounds, output, path, durable)
  }

  // Whether any connected monitor would show something else after the change.
  function monitorsChange(fromPath, fromDurable, path, durable) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var output = screens[i].name
      if (monitorPath(output, fromPath, fromDurable, displayedMonitorBackgrounds) !== monitorPath(output, path, durable, monitorBackgrounds)) return true
    }
    return false
  }

  function applyMonitorBackgrounds(backgrounds) {
    var first = !monitorBackgroundsLoaded
    monitorBackgroundsLoaded = true
    if (MonitorBackgrounds.same(backgrounds, monitorBackgrounds)) return
    monitorBackgrounds = backgrounds

    // Mid-reveal, the incoming frame already follows the new map.
    if (incomingBackground && revealProgress < 1) return
    if (first || !displayedBackground || !monitorsChange(displayedBackground, displayedBackground, displayedBackground, displayedBackground)) {
      displayedMonitorBackgrounds = backgrounds
      return
    }
    transitionBackground(displayedBackground, displayedBackground, displayedBackground, false, true)
  }

  function setBackground(path, instant) {
    transitionBackground("", path, path, instant, false)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path || (!force && finalPath === currentBackground)) return
    var fromDurable = displayedBackground
    if (path !== preparedBackground) preparedBackground = ""
    preparedBackgroundTimer.stop()
    lastTransitionPath = path
    // The incoming frame gates the reveal, so its size is read first.
    requestNativeSize(path)
    requestNativeSize(fromPath || displayedBackground)
    requestNativeSize(finalPath)
    currentBackground = finalPath
    backgroundVersion += 1
    revealStartedVersion = -1

    revealAnimation.stop()
    finishingTransition = false

    // Video frames are not fed through the image-only reveal stack. Switching
    // instantly also avoids decoding two full videos during a transition. A
    // change no monitor would show, as when every monitor keeps its own
    // background, has nothing to reveal either.
    if (instant || !displayedBackground || isVideo(path) || isVideo(displayedBackground) ||
        !monitorsChange(fromPath || displayedBackground, fromDurable, path, finalPath)) {
      oldBackground = ""
      incomingBackground = ""
      preparedBackground = ""
      displayedBackground = finalPath
      displayedMonitorBackgrounds = monitorBackgrounds
      revealProgress = 1
      return
    }

    oldDurableBackground = fromDurable
    oldBackground = fromPath || displayedBackground
    incomingBackground = path
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    // Background polling can advance backgroundVersion while a theme switch is
    // pending; the latest theme payload should still apply.
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Color.loadColors(pendingColorsRaw)
    // Color.loadShell also refreshes Style so the type scale flips with the
    // background reveal instead of waiting for a separate reload path.
    Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  function startReveal(panel) {
    if (!incomingBackground) return
    panel.maskReady = true
    if (revealStartedVersion === backgroundVersion) return
    revealStartedVersion = backgroundVersion
    applyPendingTheme()
    revealAnimation.restart()
  }

  function prepareBackground(path) {
    path = String(path || "").trim()
    // Only a still that is not already on screen is worth decoding ahead.
    if (!path || isVideo(path) || path === lastTransitionPath || path === displayedBackground) return
    requestNativeSize(path)
    preparedBackground = path
    preparedBackgroundTimer.restart()
  }

  function requestNativeSize(path) {
    if (!path || isVideo(path) || nativeSizes[path] !== undefined || sizeQueue.indexOf(path) !== -1) return
    sizeQueue = sizeQueue.concat([path])
    probeNextSize()
  }

  function probeNextSize() {
    if (sizeProbe.running || sizeQueue.length === 0) return
    sizeProbe.path = sizeQueue[0]
    sizeProbe.command = ["magick", "identify", "-ping", "-format", "%w %h", sizeProbe.path]
    sizeProbe.running = true
  }

  // Monitors can end a reveal on different files, so the transition frames
  // stay up until every monitor's base frame is ready.
  function finishTransitionIfSettled() {
    if (!finishingTransition) return
    var panels = backgroundPanels.instances
    for (var i = 0; i < panels.length; i++) {
      if (!panels[i].baseSettled) return
    }
    incomingBackground = ""
    oldBackground = ""
    preparedBackground = ""
    finishingTransition = false
    pruneNativeSizes()
  }

  // Each theme switch names fresh snapshot paths, so keep only the sizes of
  // the wallpapers still in play.
  function pruneNativeSizes() {
    var kept = {}
    var paths = [displayedBackground, incomingBackground, oldBackground, preparedBackground]
      .concat(MonitorBackgrounds.paths(monitorBackgrounds, [displayedBackground]))
    for (var i = 0; i < paths.length; i++) {
      if (paths[i] && nativeSizes[paths[i]] !== undefined) kept[paths[i]] = nativeSizes[paths[i]]
    }
    nativeSizes = kept
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    var payload = JSON.stringify({ source: "themes" })

    // A cloned background may not summon the picker in-process, so it takes
    // the IPC route instead.
    if (!root.shell || !root.shell.summon("omarchy.image-picker", payload))
      Util.execArgv(["omarchy-shell", "shell", "summon", "omarchy.image-picker", payload])
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: sizeProbe
    property string path: ""
    stdout: StdioCollector { id: sizeProbeOut }
    onExited: function(exitCode) {
      var parts = String(sizeProbeOut.text || "").trim().split(/\s+/)
      var width = exitCode === 0 ? parseInt(parts[0], 10) : 0
      var height = exitCode === 0 ? parseInt(parts[1], 10) : 0
      var known = Object.assign({}, root.nativeSizes)
      // An unreadable header records 0x0, which decodes at screen size.
      known[path] = { width: width > 0 ? width : 0, height: height > 0 ? height : 0 }
      root.nativeSizes = known
      root.sizeQueue = root.sizeQueue.filter(function(queued) { return queued !== sizeProbe.path })
      root.probeNextSize()
    }
  }

  Process {
    id: monitorBackgroundsProc
    command: [root.omarchyPath + "/shell/plugins/background/monitor-backgrounds.sh"]
    stdout: StdioCollector {
      onStreamFinished: root.applyMonitorBackgrounds(MonitorBackgrounds.parse(text))
    }
    onExited: {
      if (!root.monitorBackgroundsQueued) return
      root.monitorBackgroundsQueued = false
      root.refreshMonitorBackgrounds()
    }
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
    }
  }

  ShellIpc {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
      root.refreshMonitorBackgrounds()
    }

    function refreshMonitors(): void {
      root.refreshMonitorBackgrounds()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
      // A monitor's folder may sit inside the theme that just changed.
      root.refreshMonitorBackgrounds()
    }

    function prepare(path: string): void {
      root.prepareBackground(path)
    }
  }

  // A prepared frame that no transition claims, say from a theme switch that
  // failed after naming it, must not hold its decoded texture indefinitely.
  Timer {
    id: preparedBackgroundTimer
    interval: 5000
    repeat: false
    onTriggered: root.preparedBackground = ""
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: Style.duration(420)
    easing.type: Easing.InOutCubic
    onFinished: {
      if (root.incomingBackground) {
        var panels = backgroundPanels.instances
        var before = []
        for (var i = 0; i < panels.length; i++) before.push(panels[i].basePath)
        root.displayedBackground = root.currentBackground || root.incomingBackground
        root.displayedMonitorBackgrounds = root.monitorBackgrounds
        root.finishingTransition = true
        // A base frame that moves to a file already decoded is ready at once
        // and reports no change. One that keeps its path keeps the incoming
        // frame up, as it always has, since that frame may hold newer pixels.
        for (i = 0; i < panels.length; i++) {
          if (panels[i].basePath !== before[i]) {
            Qt.callLater(root.finishTransitionIfSettled)
            break
          }
        }
      }
      root.revealProgress = 1
    }
  }

  Component.onCompleted: {
    refreshMonitorBackgrounds()
    refreshBackground()
  }

  Variants {
    id: backgroundPanels
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. A still
      // wallpaper costs nothing to keep enabled. OWE manages video layers.
      updatesEnabled: true

      property bool maskReady: false

      // What this monitor shows in each frame: the shared background, or its own.
      readonly property string outputName: modelData.name
      readonly property string basePath: root.monitorPath(outputName, root.displayedBackground, root.displayedBackground, root.displayedMonitorBackgrounds)
      readonly property string oldPath: root.monitorPath(outputName, root.oldBackground, root.oldDurableBackground, root.displayedMonitorBackgrounds)
      // A prepared frame is a snapshot that a folder cannot match by name, so a
      // monitor with its own background leaves it undecoded.
      readonly property string incomingPath: root.incomingBackground
        ? root.monitorPath(outputName, root.incomingBackground, root.currentBackground, root.monitorBackgrounds)
        : (root.monitorBackgrounds[outputName] ? "" : root.preparedBackground)
      // A monitor that keeps its own background through a change has nothing
      // to reveal, and decodes no transition frames.
      readonly property bool revealing: incomingPath !== oldPath
      readonly property bool baseSettled: base.ready || !basePath || root.isVideo(basePath)

      onBasePathChanged: root.requestNativeSize(basePath)
      onOldPathChanged: root.requestNativeSize(oldPath)
      onIncomingPathChanged: root.requestNativeSize(incomingPath)
      Component.onCompleted: root.requestNativeSize(basePath)

      // Decode the wallpaper at the size this screen can show, not the size
      // it was shipped at. With PreserveAspectCrop Qt takes sourceSize as the
      // area to cover, so this is the smallest decode that still fills the
      // screen. Stock wallpapers go up to 10456x3455 (144 MB as RGBA); a
      // 1080p laptop paid all of that for the 8 MB it can display, and paid
      // it up to three times over during a transition. The images wait for
      // the window's size and the wallpaper's native size so nothing is ever
      // decoded at native size first, and a wallpaper smaller than the screen
      // is decoded at its own size rather than scaled up to cover the screen.
      readonly property bool sized: width > 0 && height > 0
      readonly property int decodeWidth: sized ? Math.ceil(width * screen.devicePixelRatio) : 0
      readonly property int decodeHeight: sized ? Math.ceil(height * screen.devicePixelRatio) : 0

      function decodeSize(path) {
        if (!sized || !path) return Qt.size(0, 0)
        var native = root.nativeSizes[path]
        if (native === undefined) return Qt.size(0, 0)
        if (native.width > 0 && (native.width < decodeWidth || native.height < decodeHeight)) return Qt.size(native.width, native.height)
        return Qt.size(decodeWidth, decodeHeight)
      }

      function maybeStartReveal() {
        if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
        if (incomingFrame.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
          if (incomingFrame.status !== Image.Ready) return
          root.startReveal(panel)
        })
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // OWE owns video backgrounds. This layer draws stills, and stays empty
      // behind a video so OWE's own layer shows through.
      BackgroundMedia {
        id: base
        anchors.fill: parent
        path: panel.basePath
        constrainDecode: true
        decodeSize: panel.decodeSize(panel.basePath)
        // Later, so every panel's baseSettled has caught up with this change.
        onReadyChanged: {
          if (ready) Qt.callLater(root.finishTransitionIfSettled)
        }
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        readonly property size decode: panel.decodeSize(panel.oldPath)
        source: decode.width > 0 && panel.revealing ? root.imageUrl(panel.oldPath) : ""
        sourceSize.width: decode.width
        sourceSize.height: decode.height
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: root.oldBackground !== "" && root.revealProgress < 1
        onStatusChanged: panel.maybeStartReveal()
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: root.incomingBackground !== "" && incomingFrame.status === Image.Ready && (root.revealProgress >= 1 || panel.maskReady)
        layer.enabled: root.incomingBackground !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          anchors.fill: parent
          // The same URL and size as a prepared frame keeps its decoded
          // image, so a transition to it can reveal at once.
          readonly property string framePath: panel.incomingPath
          readonly property size decode: panel.decodeSize(framePath)
          source: decode.width > 0 && panel.revealing ? root.imageUrl(framePath) : ""
          sourceSize.width: decode.width
          sourceSize.height: decode.height
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: panel.maybeStartReveal()
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
