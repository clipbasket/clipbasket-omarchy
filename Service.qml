import QtQuick
import Quickshell
import Quickshell.Io

// Clipbasket's capture service: the two `wl-paste --watch` processes that feed
// bin/clipbasket-capture, and nothing else. No UI.
//
// This exists because `omarchy plugin add` is the whole install. It clones the
// repo, validates the manifest and toggles enabled over IPC -- it never runs
// plugin code, so there is no install hook in which to register a daemon. A
// clipboard manager whose capture depends on an install script the marketplace
// never runs is a bar widget with a permanently empty history.
//
// The lifecycle is the compositor's, exactly as in the first-party
// omarchy.clipboard (shell/plugins/clipboard/Clipboard.qml): `setpriv
// --pdeathsig TERM` has the kernel kill each watcher when the shell exits,
// however it exits. That is the entire lifecycle -- no pid file, no supervisor,
// no systemd unit, and no way to leave a watcher writing to the database after
// the shell that started it is gone.
Item {
  id: root

  // Injected by omarchy-shell's service loader, as in
  // shell/plugins/services/nightlight/Service.qml. Unused here; declared so the
  // injection has somewhere to land instead of warning.
  property var shell: null

  // Our own directory, resolved from this file's location rather than from
  // $OMARCHY_PATH: omarchy.clipboard can derive its capture script from the
  // shell root because it ships inside it, and we cannot -- we live in
  // ~/.config/omarchy/plugins/clipbasket.clipboard/, or wherever a developer
  // cloned us. Same derivation as Panel.qml's `pluginDir`; if you change one,
  // change both.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."));
    if (u.indexOf("file://") === 0) u = u.substring(7);
    while (u.length > 1 && u.charAt(u.length - 1) === "/") u = u.substring(0, u.length - 1);
    return decodeURIComponent(u);
  }

  readonly property string captureScript: root.pluginDir + "/bin/clipbasket-capture"
  readonly property string settingsPath:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/clipbasket/settings.json"

  // Retention and the confidential-copy skip. Both reach clipbasket-capture as
  // environment variables, and Process.environment is read once at spawn, so a
  // change to either is only picked up by restarting the watchers.
  //
  // Retention. clipbasket-capture prunes to CLIPBASKET_MAX_CLIPS after every
  // insert and defaults to 1000 when it is unset, which is why this has to be
  // passed through: without it the setting renders in the panel and does
  // nothing. Process.environment is read once at spawn, so a change to it is
  // only picked up by restarting the watchers.
  readonly property int defaultMaxClips: 1000
  property int maxClips: root.defaultMaxClips

  // Whether capture skips offers a password manager marked confidential.
  // Defaults on: a privacy default should never need to be discovered, and an
  // unreadable settings file must not quietly start recording passwords.
  property bool ignoreConfidentialCopies: true

  // A watcher that comes back up faster than this did not run, it failed.
  // Mirrors MIN_HEALTHY_SECONDS in the daemon this replaced.
  readonly property int minHealthyMs: 5000
  readonly property int baseRestartMs: 1000
  readonly property int maxRestartMs: 60000
  property int consecutiveFailures: 0

  // `watchersStarted` gates every exit handler: the stop half of a deliberate
  // restart must not be mistaken for a watcher dying.
  property bool watchersStarted: false
  property bool settingsResolved: false

  // Escape a path for `pkill -f`, which takes an extended regular expression.
  // The path is ours, but it is not a literal: an unescaped '.' in
  // "clipbasket.clipboard" would match any character, and a developer's clone
  // can sit under a directory whose name contains regex metacharacters.
  function rx(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  function watcherCommand(kind) {
    return ["setpriv", "--pdeathsig", "TERM",
            "wl-paste", "--type", kind, "--watch", root.captureScript, kind];
  }

  // Nothing starts until the retention setting has been read, so the common
  // case is one spawn with the right environment rather than a spawn at the
  // default followed by an immediate restart -- a restart drops any copy made
  // in the gap.
  function startWatchers() {
    if (root.watchersStarted || reapProc.running) return;
    reapProc.running = true;
  }

  function restartWatchers() {
    if (!root.watchersStarted) return;
    root.watchersStarted = false;
    root.consecutiveFailures = 0;
    restartTimer.stop();
    textWatcher.running = false;
    imageWatcher.running = false;
    reapProc.running = true;
  }

  function noteWatcherExit(startedAt) {
    var ranFor = Date.now() - startedAt;
    if (ranFor >= root.minHealthyMs) {
      // It worked and then the compositor went away. Ordinary; come straight
      // back.
      root.consecutiveFailures = 0;
    } else {
      root.consecutiveFailures = Math.min(root.consecutiveFailures + 1, 16);
    }
    restartTimer.interval = Math.min(
      root.baseRestartMs * Math.pow(2, root.consecutiveFailures),
      root.maxRestartMs);
    restartTimer.restart();
  }

  // maxClips lives in the same file the settings page writes, and is read back
  // here rather than passed in, so editing settings.json by hand works too.
  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applySettings(text())
    onLoadFailed: root.applySettings("{}")
    onFileChanged: reload()
  }

  function applySettings(raw) {
    var next = root.defaultMaxClips;
    var nextConfidential = true;
    try {
      var parsed = JSON.parse(String(raw));
      if (parsed && typeof parsed === "object") {
        if ("maxClips" in parsed) {
          var n = Number(parsed.maxClips);
          // Clamped, not rejected, to match settings.schema.json.
          if (isFinite(n) && n > 0) next = Math.max(50, Math.min(100000, Math.round(n)));
        }
        // Anything other than an explicit false leaves the privacy default on,
        // so a typo in the settings file cannot silently start recording
        // passwords.
        if ("ignoreConfidentialCopies" in parsed) {
          nextConfidential = parsed.ignoreConfidentialCopies !== false;
        }
      }
    } catch (e) {
      // A half-written or hand-broken settings file must not take capture down
      // with it; the defaults are working retention and privacy on, not a
      // failure.
    }

    var changed = next !== root.maxClips || nextConfidential !== root.ignoreConfidentialCopies;
    root.maxClips = next;
    root.ignoreConfidentialCopies = nextConfidential;
    root.settingsResolved = true;

    if (!root.watchersStarted) root.startWatchers();
    else if (changed) root.restartWatchers();
  }

  // Reap watchers left behind by a previous shell instance before starting
  // ours, so a shell restart never doubles them up. The pattern is built from
  // our own resolved capture path: it can never match omarchy.clipboard's
  // watchers, or a second Clipbasket checkout's.
  Process {
    id: reapProc
    command: ["pkill", "-f", "wl-paste .*--watch .*" + root.rx(root.captureScript)]
    onExited: {
      root.watchersStarted = true;
      textWatcher.running = true;
      imageWatcher.running = true;
    }
  }

  // `--type image`, not the first party's `image/png`: clipbasket-capture
  // classifies the whole offer itself and records image/jpeg and image/webp
  // copies too, and its second argument is the mode name it switches on, which
  // is "image".
  Process {
    id: textWatcher
    property double startedAt: 0
    command: root.watcherCommand("text")
    // Quickshell declares `environment` as a QVariantHash, and a QML object
    // literal can only ever produce a QVariantMap, so qmllint flags an
    // assignment that is correct and works at runtime. No QML expression yields
    // a QVariantHash, so the warning is suppressed rather than worked around.
    // qmllint disable incompatible-type
    environment: ({
      "CLIPBASKET_MAX_CLIPS": String(root.maxClips),
      "CLIPBASKET_IGNORE_CONFIDENTIAL": root.ignoreConfidentialCopies ? "1" : "0"
    })
    // qmllint enable incompatible-type
    onRunningChanged: if (textWatcher.running) textWatcher.startedAt = Date.now()
    onExited: if (root.watchersStarted) root.noteWatcherExit(textWatcher.startedAt)
  }

  Process {
    id: imageWatcher
    property double startedAt: 0
    command: root.watcherCommand("image")
    // Quickshell declares `environment` as a QVariantHash, and a QML object
    // literal can only ever produce a QVariantMap, so qmllint flags an
    // assignment that is correct and works at runtime. No QML expression yields
    // a QVariantHash, so the warning is suppressed rather than worked around.
    // qmllint disable incompatible-type
    environment: ({
      "CLIPBASKET_MAX_CLIPS": String(root.maxClips),
      "CLIPBASKET_IGNORE_CONFIDENTIAL": root.ignoreConfidentialCopies ? "1" : "0"
    })
    // qmllint enable incompatible-type
    onRunningChanged: if (imageWatcher.running) imageWatcher.startedAt = Date.now()
    onExited: if (root.watchersStarted) root.noteWatcherExit(imageWatcher.startedAt)
  }

  // A watcher that dies takes the history with it silently -- copying still
  // works, the panel still opens, the old clips are all still there, and
  // nothing new is ever recorded. Bring it back instead, backing off so a
  // missing wl-clipboard becomes a quiet failure rather than a spin.
  Timer {
    id: restartTimer
    interval: root.baseRestartMs
    repeat: false
    onTriggered: {
      if (!root.watchersStarted) return;
      if (!textWatcher.running) textWatcher.running = true;
      if (!imageWatcher.running) imageWatcher.running = true;
    }
  }

  // FileView answers with onLoaded or onLoadFailed, and either one starts the
  // watchers. This is the backstop for the case where it answers with neither:
  // capture must not be hostage to the settings file.
  Timer {
    id: settingsBackstop
    interval: 2000
    repeat: false
    running: true
    onTriggered: if (!root.settingsResolved) root.startWatchers()
  }
}
