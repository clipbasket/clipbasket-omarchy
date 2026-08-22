import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Two views in one panel: the clip list, and a settings page reached from the
// cog in the header. The list is a faithful port of the desktop app's popup --
// same row anatomy (leading visual, title, secondary line, time + action rail),
// same time sections, same filter set, same delete-confirmation rule -- driven
// by the `clipbasket-db` CLI instead of Tauri commands.
//
// Only settings that mean something on Linux/Wayland are present; macOS-only
// concepts (Accessibility permission, app-managed updates, app-owned theming)
// are deliberately absent, with a note saying why.
Panel {
  id: root
  moduleName: "clipbasket.clipboard"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- View state
  property string query: ""
  property string filter: "all"
  property bool settingsOpen: false
  property bool loading: false
  property bool loaded: false
  property string warning: ""
  property string notice: ""

  // ---- Paging
  readonly property int pageSize: 50
  property int loadedCount: 0
  property bool hasMore: false
  property bool loadingMore: false

  // ---- Counts (footer status line)
  property int totalCount: 0
  property int matchingCount: 0

  // ---- Delete confirmation (armed by clip id, like the desktop app)
  property int armedDeleteId: -1

  // ---- Copy-variant menu (panel-level overlay so the ListView cannot clip it)
  property int menuClipRow: -1
  property real menuX: 0
  property real menuY: 0
  property var menuActions: []

  // Settings state. Names, defaults and semantics come from
  // settings.schema.json; unknown keys in the file are preserved on write.
  property bool launchAtLogin: true
  property string globalShortcut: ""
  property int maxClips: 1000
  property bool ignoreConfidentialCopies: true
  property bool closePanelAfterAction: true
  property bool openAtCursorOnShortcut: false
  property bool pasteSelectedClipImmediately: false

  // Chip label -> backend `--filter` value. Order and wording mirror
  // PopupHeader.tsx exactly; there is deliberately no "Pinned" chip because
  // pins are a section, not a filter.
  readonly property var filterKeys: ["all", "text", "url", "image", "files", "saved"]
  readonly property var filterLabels: ["All", "Text", "Links", "Images", "Files", "Saved"]

  readonly property string settingsDir: "${XDG_CONFIG_HOME:-$HOME/.config}/clipbasket"
  readonly property string settingsPath: root.settingsDir + "/settings.json"
  // Empty means "no compositor binding recorded yet"; the compositor owns it.
  readonly property string shortcutLabelText: root.globalShortcut.length > 0 ? root.globalShortcut : "Unbound"

  // ---- Nerd Font glyphs. ALWAYS \uXXXX escapes: literal PUA codepoints get
  // stripped in transit and an empty `text: ""` collapses the item silently.
  readonly property string glyphBrand:    "\uf0ea"  // clipboard
  readonly property string glyphCog:      "\uf013"  // cog
  readonly property string glyphBack:     "\uf053"  // chevron-left
  readonly property string glyphSearch:   "\uf002"  // magnifier
  readonly property string glyphChevron:  "\uf078"  // chevron-down
  readonly property string glyphText:     "\uf15c"  // file-text-o
  readonly property string glyphLink:     "\uf0c1"  // link
  readonly property string glyphImage:    "\uf03e"  // picture-o
  readonly property string glyphFiles:    "\uf0c5"  // files-o
  readonly property string glyphFile:     "\uf15b"  // file
  readonly property string glyphFolder:   "\uf07b"  // folder
  readonly property string glyphPdf:      "\uf1c1"  // file-pdf-o
  readonly property string glyphPin:      "\uf08d"  // thumb-tack
  readonly property string glyphSaved:    "\uf02e"  // bookmark (solid)
  readonly property string glyphUnsaved:  "\uf097"  // bookmark-o
  readonly property string glyphTrash:    "\uf014"  // trash-o

  // ---------------------------------------------------------------- helpers

  function shq(value) { return "'" + String(value).replace(/'/g, "'\\''") + "'"; }

  // The CLI ships in the plugin's own bin/ (owned by the service agent) but may
  // also be on PATH once packaged. Prefer the local copy, fall back to PATH.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."));
    if (u.indexOf("file://") === 0) u = u.substring(7);
    while (u.length > 1 && u.charAt(u.length - 1) === "/") u = u.substring(0, u.length - 1);
    return decodeURIComponent(u);
  }

  // Every invocation is wrapped so a missing binary degrades to a usable empty
  // state instead of throwing: stderr is dropped and `fallback` is echoed.
  function dbCmd(args, fallback) {
    return "export PATH=" + shq(root.pluginDir + "/bin") + ":$PATH; "
         + "clipbasket-db " + args + " 2>/dev/null || printf %s " + shq(fallback);
  }

  function fileUrl(path) {
    if (!path) return "";
    var p = String(path);
    if (p.indexOf("file://") === 0) return p;
    return "file://" + encodeURI(p);
  }

  function num(value, fallback) {
    var n = Number(value);
    return isFinite(n) ? n : fallback;
  }

  // created_at is documented as unix seconds; tolerate milliseconds so a
  // contract drift shows up as a wrong section, never as 1970.
  function createdMs(clip) {
    var raw = root.num(clip.created_at, 0);
    return raw > 1e12 ? raw : raw * 1000;
  }

  function humanSize(bytes) {
    var b = root.num(bytes, 0);
    if (b <= 0) return "";
    var units = ["B", "KB", "MB", "GB"];
    var i = 0;
    while (b >= 1024 && i < units.length - 1) { b = b / 1024; i++; }
    return (i === 0 ? Math.round(b) : (Math.round(b * 10) / 10)) + " " + units[i];
  }

  // ------------------------------------------------------- display mapping
  // Mirrors popupUtils.ts: clipDisplayTitle / clipListSecondaryText / clipMeta.

  function displayTitle(clip) {
    if (clip.kind === "url" && clip.url_title) return String(clip.url_title);
    var t = clip.preview || clip.text || "";
    return String(t).replace(/\s+/g, " ").trim();
  }

  function displaySecondary(clip) {
    if (clip.kind === "url") {
      // Title in the primary line means the URL itself is the useful context;
      // otherwise the domain is all there is to add.
      if (clip.url_title) return String(clip.text || clip.url_domain || "");
      return String(clip.url_domain || "");
    }
    if (clip.kind === "files") {
      var n = root.num(clip.file_count, 0);
      return n === 1 ? "1 file" : n + " files";
    }
    if (clip.kind === "image") {
      // The desktop app renders no secondary line for images (its dimension
      // detail is appended to the title). The CLI exposes mime/size instead,
      // which is the closest equivalent signal we actually have.
      var bits = [];
      var m = String(clip.mime || "");
      if (m.indexOf("/") >= 0) bits.push(m.split("/")[1].toUpperCase());
      var sz = root.humanSize(clip.size_bytes);
      if (sz) bits.push(sz);
      return bits.join("  ·  ");
    }
    return "";
  }

  readonly property real leadingSlot: Style.space(44)
  readonly property real leadingMin: Style.space(36)

  function visualSize(w, h) {
    var max = root.leadingSlot;
    var min = root.leadingMin;
    if (!w || !h || w <= 0 || h <= 0) return Qt.size(max, max);
    var ratio = Math.min(Math.max(w / h, 0.72), 1.8);
    if (ratio >= 1) return Qt.size(max, Math.max(min, Math.round(max / ratio)));
    return Qt.size(Math.max(min, Math.round(max * ratio)), max);
  }

  function kindGlyph(clip) {
    switch (clip.kind) {
      case "url":   return root.glyphLink;
      case "image": return root.glyphImage;
      case "files":
        if (root.num(clip.file_count, 0) > 1) return root.glyphFiles;
        if (clip.mime === "inode/directory") return root.glyphFolder;
        if (clip.mime === "application/pdf") return root.glyphPdf;
        return root.glyphFile;
      default:      return root.glyphText;
    }
  }

  // groupClipsByTime(): pins bypass the time buckets entirely and form an
  // always-on-top section. Labels are stored sentence-case and uppercased at
  // render time, exactly as the web UI does it in CSS.
  function sectionFor(clip) {
    if (clip.pinned) return "Pinned";
    var ts = root.createdMs(clip);
    var now = Date.now();
    var midnight = new Date();
    midnight.setHours(0, 0, 0, 0);
    var todayStart = midnight.getTime();
    if (ts >= now - 3600000) return "Now";
    if (ts >= todayStart) return "Earlier today";
    if (ts >= todayStart - 86400000) return "Yesterday";
    if (ts >= now - 7 * 86400000) return "Last week";
    return "Older";
  }

  // formatTime(): clock time today, "Yesterday, <time>" yesterday, otherwise
  // "<Mon> <d>, <time>". Never a relative "2m"/"3h".
  function formatTime(ts) {
    var d = new Date(ts);
    var now = new Date();
    var sameDay = d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
    var y = new Date(now.getTime() - 86400000);
    var isYesterday = d.getFullYear() === y.getFullYear() && d.getMonth() === y.getMonth() && d.getDate() === y.getDate();
    var time = Qt.formatDateTime(d, "h:mm AP");
    if (sameDay) return time;
    if (isYesterday) return "Yesterday, " + time;
    return Qt.formatDateTime(d, "MMM d, h:mm AP");
  }

  // -------------------------------------------------------------- the model

  ListModel { id: clipModel }

  // Backend order is (pinned DESC, created_at DESC, id DESC). We re-apply it
  // per page so a backend that has not settled its ordering still produces
  // contiguous sections, which is what ListView section headers require.
  function sortPage(clips) {
    return clips.slice().sort(function (a, b) {
      var ap = a.pinned ? 1 : 0, bp = b.pinned ? 1 : 0;
      if (ap !== bp) return bp - ap;
      var at = root.createdMs(a), bt = root.createdMs(b);
      if (at !== bt) return bt - at;
      return root.num(b.id, 0) - root.num(a.id, 0);
    });
  }

  function toRow(clip) {
    var thumb = clip.thumb_path || (clip.kind === "image" ? clip.image_path : null);
    return {
      clipId: root.num(clip.id, -1),
      kind: String(clip.kind || "text"),
      title: root.displayTitle(clip),
      secondary: root.displaySecondary(clip),
      timeLabel: root.formatTime(root.createdMs(clip)),
      section: root.sectionFor(clip),
      thumb: root.fileUrl(thumb),
      glyph: root.kindGlyph(clip),
      pinned: clip.pinned === true,
      saved: clip.saved === true,
      payload: String(clip.text || ""),
      imagePath: String(clip.image_path || ""),
      mime: String(clip.mime || ""),
      files: clip.files ? JSON.stringify(clip.files) : "",
      imageWidth: root.num(clip.image_width, 0),
      imageHeight: root.num(clip.image_height, 0),
      fileCount: root.num(clip.file_count, 0),
      urlTitle: String(clip.url_title || ""),
      urlDomain: String(clip.url_domain || "")
    };
  }

  function appendPage(clips, replace) {
    if (replace) {
      clipModel.clear();
      root.loadedCount = 0;
      root.pinnedCount = 0;
    }
    var sorted = root.sortPage(clips);
    for (var i = 0; i < sorted.length; i++) {
      var row = root.toRow(sorted[i]);
      if (row.section === "Pinned") root.pinnedCount += 1;
      clipModel.append(row);
    }
    root.loadedCount += clips.length;
    root.hasMore = clips.length >= root.pageSize;
  }

  property int pinnedCount: 0

  // ------------------------------------------------------------- data loads

  property bool replaceOnNextPage: true

  function listArgs(offset) {
    var args = "list --limit " + root.pageSize + " --offset " + offset + " --filter " + root.filter;
    if (root.query.length > 0) args += " --query " + root.shq(root.query);
    return args;
  }

  function reload() {
    if (listProc.running) listProc.running = false;
    root.replaceOnNextPage = true;
    root.loading = true;
    listProc.command = ["sh", "-c", root.dbCmd(root.listArgs(0), "[]")];
    listProc.running = true;
    countProc.command = ["sh", "-c", root.dbCmd("count", "{}")];
    countProc.running = true;
  }

  function loadMore() {
    if (root.loadingMore || root.loading || !root.hasMore || listProc.running) return;
    root.loadingMore = true;
    root.replaceOnNextPage = false;
    listProc.command = ["sh", "-c", root.dbCmd(root.listArgs(root.loadedCount), "[]")];
    listProc.running = true;
  }

  function refresh() { root.reload(); settingsProbe.running = true; }
  function openFromHotkey() { root.controller.show(); }

  onOpenedChanged: {
    if (root.opened) {
      // Panel-open reset, matching the desktop popup: filter back to all,
      // search cleared, selection on the first row, search field focused.
      root.suspendReloads = true;
      root.settingsOpen = false;
      root.armedDeleteId = -1;
      root.closeMenu();
      root.notice = "";
      root.warning = "";
      root.filter = "all";
      searchInput.text = "";
      root.query = "";
      searchDebounce.stop();
      root.suspendReloads = false;
      root.refresh();
      // Focus after the panel window has actually been mapped; forcing it in
      // the same tick as `opened` lands before the surface exists.
      Qt.callLater(function () { searchInput.forceActiveFocus(); searchInput.selectAll(); });
    } else {
      root.settingsOpen = false;
      root.closeMenu();
    }
  }

  // 80 ms debounce, same as the renderer's search debounce.
  Timer {
    id: searchDebounce
    interval: 80
    onTriggered: root.reload()
  }

  property bool suspendReloads: false
  onFilterChanged: if (root.opened && !root.suspendReloads) root.reload()

  Process {
    id: listProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var wasReplace = root.replaceOnNextPage;
        root.loading = false;
        root.loadingMore = false;
        var parsed = null;
        try { parsed = JSON.parse(String(text).trim()); } catch (e) { parsed = null; }
        if (parsed === null || !Array.isArray(parsed)) {
          if (wasReplace) { clipModel.clear(); root.loadedCount = 0; root.pinnedCount = 0; root.hasMore = false; }
          root.warning = "Unable to load clips";
          root.loaded = true;
          return;
        }
        root.warning = "";
        root.appendPage(parsed, wasReplace);
        root.loaded = true;
        if (wasReplace) {
          clipList.currentIndex = clipModel.count > 0 ? 0 : -1;
          clipList.positionViewAtBeginning();
        }
      }
    }
  }

  Process {
    id: countProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var c = JSON.parse(String(text).trim());
          root.totalCount = root.num(c.total, 0);
          root.matchingCount = root.num(c.filtered, root.totalCount);
        } catch (e) { /* leave the previous counts alone */ }
      }
    }
  }

  // One serialised action channel with a tiny queue: bar.run() gives no
  // completion signal, and mutations must be followed by a refresh.
  property var actionQueue: []
  property bool actionRefreshPending: false

  function runAction(shellCommand, thenRefresh) {
    var q = root.actionQueue.slice();
    q.push({ cmd: shellCommand, refresh: thenRefresh === true });
    root.actionQueue = q;
    root.pumpActions();
  }

  function pumpActions() {
    if (actionProc.running || root.actionQueue.length === 0) return;
    var q = root.actionQueue.slice();
    var next = q.shift();
    root.actionQueue = q;
    if (next.refresh) root.actionRefreshPending = true;
    actionProc.command = ["sh", "-c", next.cmd];
    actionProc.running = true;
  }

  Process {
    id: actionProc
    running: false
    onExited: {
      if (root.actionQueue.length > 0) {
        root.pumpActions();
      } else if (root.actionRefreshPending) {
        root.actionRefreshPending = false;
        // Counts and pin ordering both change under us; a full reload keeps
        // the sections contiguous instead of patching rows in place.
        if (root.opened) root.reload();
      }
    }
  }

  // 4 s transient footer notice, same duration as ACTION_NOTICE_DURATION_MS.
  Timer { id: noticeTimer; interval: 4000; onTriggered: root.notice = "" }
  function showNotice(message) { root.notice = message; noticeTimer.restart(); }

  // Armed delete expires after 4 s, same as DELETE_CONFIRMATION_DURATION_MS.
  Timer { id: armTimer; interval: 4000; onTriggered: root.armedDeleteId = -1 }

  function clearTransientState() {
    root.notice = "";
    noticeTimer.stop();
    root.armedDeleteId = -1;
    armTimer.stop();
    root.closeMenu();
  }

  // ------------------------------------------------------------- clip actions

  function rowAt(index) {
    if (index < 0 || index >= clipModel.count) return null;
    return clipModel.get(index);
  }

  function copyTextCommand(value) {
    return "printf %s " + root.shq(value) + " | wl-copy";
  }

  function copyClip(index) {
    var row = root.rowAt(index);
    if (!row) return;
    root.clearTransientState();
    // `copy` also bumps created_at, so an open panel has to re-read.
    root.runAction(root.dbCmd("copy " + row.clipId, ""), !root.closePanelAfterAction);
    if (root.closePanelAfterAction) {
      root.close();
      // Auto-paste only ever runs after the panel is gone, otherwise the
      // synthetic Ctrl+V lands in the panel instead of the focused window.
      // No-ops silently when wtype is not installed.
      if (root.pasteSelectedClipImmediately) {
        root.runAction("command -v wtype >/dev/null 2>&1 && sleep 0.12 && wtype -M ctrl -P v -p v -m ctrl", false);
      }
    } else {
      root.showNotice("Copied.");
    }
  }

  // The desktop app derives Markdown by running turndown over the clip's
  // stored HTML flavor. The CLI contract carries no HTML, so the only rule we
  // can honour losslessly is the link form for URL clips.
  function markdownFor(row) {
    if (!row || row.kind !== "url") return "";
    var url = row.payload;
    if (!url) return "";
    var label = row.urlTitle || row.urlDomain || url;
    return "[" + label + "](" + url + ")";
  }

  function copyMarkdown(index) {
    var row = root.rowAt(index);
    var md = root.markdownFor(row);
    root.clearTransientState();
    if (!md) { root.showNotice("Clipbasket couldn't convert this clip to Markdown."); return; }
    root.runAction(root.copyTextCommand(md), false);
    if (root.closePanelAfterAction) root.close();
    else root.showNotice("Markdown copied.");
  }

  function fileItems(row) {
    if (!row) return [];
    try {
      var parsed = JSON.parse(String(row.files || "null"));
      if (Array.isArray(parsed)) return parsed;
    } catch (e) {}
    // No structured file list: fall back to one path per line of the payload.
    return String(row.payload).split("\n")
      .filter(function (line) { return line.trim().length > 0; })
      .map(function (line) { return { path: line.trim() }; });
  }

  function copyFileVariant(index, mode) {
    var row = root.rowAt(index);
    var items = root.fileItems(row);
    root.clearTransientState();
    if (items.length === 0) return;
    var out = [];
    var seen = {};
    for (var i = 0; i < items.length; i++) {
      var full = String(items[i].path || "");
      if (!full) continue;
      var trimmed = full.replace(/\/+$/, "");
      if (mode === "name") {
        out.push(items[i].name || trimmed.substring(trimmed.lastIndexOf("/") + 1));
      } else if (mode === "parent") {
        // Dedup while preserving order, like the desktop app's parent mode.
        var cut = trimmed.lastIndexOf("/");
        var parent = cut > 0 ? trimmed.substring(0, cut) : "/";
        if (!seen[parent]) { seen[parent] = true; out.push(parent); }
      } else {
        out.push(full);
      }
    }
    if (out.length === 0) return;
    root.runAction(root.copyTextCommand(out.join("\n")), false);
    if (root.closePanelAfterAction) root.close();
    else root.showNotice(mode === "name" ? "File name copied." : mode === "parent" ? "Parent folder copied." : "Full path copied.");
  }

  function togglePinned(index) {
    var row = root.rowAt(index);
    if (!row) return;
    var next = !row.pinned;
    root.clearTransientState();
    clipModel.setProperty(index, "pinned", next);
    root.runAction(root.dbCmd("pin " + row.clipId + (next ? " --on" : " --off"), ""), true);
  }

  function toggleSaved(index) {
    var row = root.rowAt(index);
    if (!row) return;
    var next = !row.saved;
    root.clearTransientState();
    clipModel.setProperty(index, "saved", next);
    root.runAction(root.dbCmd("save " + row.clipId + (next ? " --on" : " --off"), ""), true);
  }

  // Two-step confirmation only for protected clips (saved or pinned), exactly
  // like isDeleteProtectedClip in the desktop popup.
  function deleteClip(index) {
    var row = root.rowAt(index);
    if (!row) return;
    var protectedClip = row.pinned || row.saved;
    if (protectedClip && root.armedDeleteId !== row.clipId) {
      root.closeMenu();
      root.armedDeleteId = row.clipId;
      armTimer.restart();
      root.showNotice(row.saved && row.pinned
        ? "Saved and pinned clip. Click delete again to permanently remove it."
        : row.saved
          ? "Saved clip. Click delete again to permanently remove it."
          : "Pinned clip. Click delete again to permanently remove it.");
      return;
    }
    root.clearTransientState();
    var id = row.clipId;
    clipModel.remove(index);
    root.loadedCount = Math.max(0, root.loadedCount - 1);
    // Selection takes over the removed row's index, clamped to the last row.
    clipList.currentIndex = clipModel.count === 0 ? -1 : Math.min(index, clipModel.count - 1);
    root.runAction(root.dbCmd("delete " + id, ""), true);
  }

  // ----------------------------------------------------------- copy variants

  function menuActionsFor(row) {
    var actions = [];
    if (!row) return actions;
    if (row.kind === "url" && row.payload.length > 0) actions.push({ id: "markdown", label: "Copy as Markdown" });
    if (row.kind === "files") {
      actions.push({ id: "file-full", label: "Copy full path" });
      actions.push({ id: "file-name", label: "Copy file name" });
      actions.push({ id: "file-parent", label: "Copy parent folder" });
    }
    return actions;
  }

  function openMenu(index, item) {
    var row = root.rowAt(index);
    var actions = root.menuActionsFor(row);
    if (actions.length === 0) return;
    var point = item.mapToItem(keyCatcher, 0, item.height);
    root.menuActions = actions;
    root.menuClipRow = index;
    root.menuX = point.x;
    root.menuY = point.y + Style.space(4);
  }

  function closeMenu() { root.menuClipRow = -1; root.menuActions = []; }

  function invokeMenuAction(actionId) {
    var index = root.menuClipRow;
    root.closeMenu();
    if (index < 0) return;
    if (actionId === "markdown") root.copyMarkdown(index);
    else if (actionId === "file-full") root.copyFileVariant(index, "full");
    else if (actionId === "file-name") root.copyFileVariant(index, "name");
    else if (actionId === "file-parent") root.copyFileVariant(index, "parent");
  }

  // ------------------------------------------------------- keyboard handling

  function moveSelection(delta) {
    if (clipModel.count === 0) return;
    // Clamped, never wrapping -- matches handleKeyDown in usePopupModel.ts.
    var next = Math.min(Math.max(clipList.currentIndex + delta, 0), clipModel.count - 1);
    clipList.currentIndex = next;
    clipList.positionViewAtIndex(next, ListView.Contain);
  }

  function selectAbsolute(index) {
    if (clipModel.count === 0) return;
    var next = Math.min(Math.max(index, 0), clipModel.count - 1);
    clipList.currentIndex = next;
    clipList.positionViewAtIndex(next, ListView.Contain);
  }

  // Shared by the search field and the key catcher so navigation works no
  // matter which of the two currently owns focus. Returns true when handled.
  function handleNavKey(event) {
    if (root.settingsOpen) return false;
    if (root.menuClipRow >= 0 && event.key === Qt.Key_Escape) { root.closeMenu(); return true; }
    switch (event.key) {
      case Qt.Key_Down:     root.moveSelection(1); return true;
      case Qt.Key_Up:       root.moveSelection(-1); return true;
      case Qt.Key_PageDown: root.moveSelection(6); return true;
      case Qt.Key_PageUp:   root.moveSelection(-6); return true;
      case Qt.Key_Home:
        if (searchInput.activeFocus && searchInput.text.length > 0) return false;
        root.selectAbsolute(0); return true;
      case Qt.Key_End:
        if (searchInput.activeFocus && searchInput.text.length > 0) return false;
        root.selectAbsolute(clipModel.count - 1); return true;
      case Qt.Key_Return:
      case Qt.Key_Enter:
        if (clipModel.count > 0) root.copyClip(clipList.currentIndex);
        return true;
      case Qt.Key_Delete:
      case Qt.Key_Backspace:
        // Plain Delete/Backspace must still edit the search text. Deleting a
        // clip needs either an empty search box or an explicit Ctrl.
        if ((event.modifiers & Qt.ControlModifier) || searchInput.text.length === 0) {
          if (clipModel.count > 0) root.deleteClip(clipList.currentIndex);
          return true;
        }
        return false;
    }
    return false;
  }

  // -------------------------------------------------------------- settings io

  function persist() {
    // The schema promises unknown keys survive a write, so this merges through
    // jq rather than overwriting the document.
    var payload = JSON.stringify({
      launchAtLogin: root.launchAtLogin,
      maxClips: root.maxClips,
      ignoreConfidentialCopies: root.ignoreConfidentialCopies,
      closePanelAfterAction: root.closePanelAfterAction,
      openAtCursorOnShortcut: root.openAtCursorOnShortcut,
      pasteSelectedClipImmediately: root.pasteSelectedClipImmediately
    });
    var dir = "\"" + root.settingsDir + "\"";
    var file = "\"" + root.settingsPath + "\"";
    root.runAction(
      "mkdir -p " + dir + " && tmp=$(mktemp) && "
      + "{ jq -e . " + file + " 2>/dev/null || printf '{}'; } "
      + "| jq --argjson patch " + root.shq(payload) + " '. * $patch' > \"$tmp\" "
      + "&& mv \"$tmp\" " + file, false);
  }

  // pasteSelectedClipImmediately requires closePanelAfterAction: pasting into
  // the focused window while the panel still holds focus pastes into the panel.
  function normalizeSettings() {
    if (root.pasteSelectedClipImmediately && !root.closePanelAfterAction) {
      root.pasteSelectedClipImmediately = false;
    }
  }

  Process {
    id: settingsProbe
    command: ["sh", "-c", "cat \"" + root.settingsPath + "\" 2>/dev/null || printf '{}'"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var s = JSON.parse(String(text).trim());
          if ("launchAtLogin" in s) root.launchAtLogin = s.launchAtLogin === true;
          if ("globalShortcut" in s) root.globalShortcut = String(s.globalShortcut || "");
          if ("maxClips" in s) root.maxClips = root.num(s.maxClips, root.maxClips);
          if ("ignoreConfidentialCopies" in s) root.ignoreConfidentialCopies = s.ignoreConfidentialCopies === true;
          if ("closePanelAfterAction" in s) root.closePanelAfterAction = s.closePanelAfterAction === true;
          if ("openAtCursorOnShortcut" in s) root.openAtCursorOnShortcut = s.openAtCursorOnShortcut === true;
          if ("pasteSelectedClipImmediately" in s) root.pasteSelectedClipImmediately = s.pasteSelectedClipImmediately === true;
          root.normalizeSettings();
        } catch (e) {}
      }
    }
  }

  // ------------------------------------------------------------ empty states

  readonly property string emptyTitle: {
    if (root.warning.length > 0) return "Unable to load clips";
    if (root.query.length > 0) return "No matching clips";
    switch (root.filter) {
      case "saved": return "You don't have any saved clips";
      case "url":   return "No links yet";
      case "text":  return "No text clips yet";
      case "image": return "No image clips yet";
      case "files": return "No file clips yet";
    }
    return "Ready when you are";
  }

  readonly property string emptyDetail: {
    if (root.warning.length > 0) return "Is clipbasket-db installed and on PATH?";
    if (root.query.length > 0) return "";
    if (root.filter === "saved") return "Save clips to keep them handy here.";
    if (root.filter === "all") return "Copy anything — text, links, images and files land here automatically.";
    return "";
  }

  readonly property string countLabel: {
    if (root.loading && !root.loaded) return "";
    if (root.query.length > 0 || root.filter !== "all") {
      if (root.matchingCount <= 0) return "";
      return root.matchingCount + (root.matchingCount === 1 ? " match" : " matches");
    }
    if (root.totalCount <= 0) return "";
    return root.totalCount + (root.totalCount === 1 ? " clip" : " clips");
  }

  // ---- Reusable toggle, styled after the macOS switches in the real product.
  component Toggle: Rectangle {
    id: sw
    property bool checked: false
    signal toggled
    width: Style.space(38)
    height: Style.space(20)
    radius: height / 2
    color: checked ? root.barForeground : Qt.rgba(1, 1, 1, 0.14)
    Behavior on color { ColorAnimation { duration: 120 } }

    Rectangle {
      width: parent.height - 4
      height: width
      radius: width / 2
      y: 2
      x: sw.checked ? parent.width - width - 2 : 2
      color: sw.checked ? Color.background : Qt.rgba(1, 1, 1, 0.75)
      Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: { sw.checked = !sw.checked; sw.toggled(); }
    }
  }

  // ---- Reusable settings row
  component SettingRow: Item {
    property string title: ""
    property string subtitle: ""
    default property alias control: holder.data
    width: parent ? parent.width - Style.space(28) : 0
    x: Style.space(14)
    height: Math.max(Style.space(34), col.implicitHeight + Style.space(10))

    Column {
      id: col
      anchors.left: parent.left
      anchors.right: holder.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1
      Text {
        width: parent.width
        text: parent.parent.title
        color: root.barForeground
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width
        visible: text.length > 0
        text: parent.parent.subtitle
        color: root.barForeground
        opacity: 0.4
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Item {
      id: holder
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  component SectionHeader: Text {
    color: root.barForeground
    opacity: 0.4
    x: Style.space(14)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // ---- Small icon button used by the row action rail.
  component RowAction: Item {
    id: act
    property string glyph: ""
    property real restOpacity: 0.45
    property color tint: root.barForeground
    property string tip: ""
    signal activated
    width: Style.space(22)
    height: Style.space(22)

    Rectangle {
      anchors.fill: parent
      radius: 6
      color: actArea.containsMouse ? Qt.rgba(1, 1, 1, 0.10) : "transparent"
    }

    Text {
      anchors.centerIn: parent
      text: act.glyph
      color: act.tint
      opacity: actArea.containsMouse ? 1.0 : act.restOpacity
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: actArea
      anchors.fill: parent
      hoverEnabled: true
      onClicked: act.activated()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(Math.min(Style.space(600), root.settingsOpen ? settingsColumn.implicitHeight : clipView.desiredHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.menuClipRow >= 0) root.closeMenu();
        else if (root.settingsOpen) root.settingsOpen = false;
        else root.close();
      }
      onTabRequested: function (direction) { root.switchPanel(direction); }

      // Fallback navigation for the case where the key catcher, rather than
      // the search field, owns active focus. These are distinct signals from
      // Keys.onPressed, so PanelKeyCatcher's own Esc/Tab handling is untouched.
      Keys.onUpPressed: function (event) { event.accepted = root.handleNavKey(event); }
      Keys.onDownPressed: function (event) { event.accepted = root.handleNavKey(event); }
      Keys.onReturnPressed: function (event) { event.accepted = root.handleNavKey(event); }
      Keys.onEnterPressed: function (event) { event.accepted = root.handleNavKey(event); }
      Keys.onDeletePressed: function (event) { event.accepted = root.handleNavKey(event); }

      // ================= CLIP LIST =================
      Item {
        id: clipView
        anchors.fill: parent
        visible: !root.settingsOpen

        readonly property real maxListHeight: Style.space(440)
        readonly property real minListHeight: Style.space(120)
        readonly property real desiredHeight: listHeader.implicitHeight + listFooter.implicitHeight
          + Math.max(clipView.minListHeight, Math.min(clipView.maxListHeight, clipList.contentHeight + Style.space(6)))

        // ---- Header: brand, settings cog, search, filter chips
        Column {
          id: listHeader
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(10)

          Item { width: 1; height: Style.space(12) }

          Item {
            width: parent.width - Style.space(28)
            x: Style.space(14)
            height: Style.space(22)

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.glyphBrand
                color: root.barForeground
                opacity: 0.85
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Clipbasket"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.glyphCog
              color: root.barForeground
              opacity: cogArea.containsMouse ? 0.95 : 0.45
              font.family: Style.font.family
              font.pixelSize: Style.font.body

              MouseArea {
                id: cogArea
                anchors.fill: parent
                anchors.margins: -8
                hoverEnabled: true
                onClicked: { root.closeMenu(); root.settingsOpen = true; }
              }
            }
          }

          Rectangle {
            width: parent.width - Style.space(28)
            x: Style.space(14)
            height: Style.space(30)
            radius: height / 2
            color: Qt.rgba(1, 1, 1, 0.05)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, searchInput.activeFocus ? 0.22 : 0.10)

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.glyphSearch
                color: root.barForeground
                opacity: 0.4
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              TextInput {
                id: searchInput
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(36)
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                selectByMouse: true
                clip: true
                // Escape is deliberately NOT intercepted: the desktop popup
                // closes on Escape even while the search field has focus, so
                // the event must keep bubbling to PanelKeyCatcher.
                Keys.onPressed: function (event) {
                  if (root.handleNavKey(event)) event.accepted = true;
                }
                onTextChanged: {
                  root.query = text;
                  searchDebounce.restart();
                }
                Text {
                  anchors.fill: parent
                  visible: searchInput.text.length === 0
                  text: "Search"
                  color: root.barForeground
                  opacity: 0.35
                  font: searchInput.font
                  verticalAlignment: Text.AlignVCenter
                }
              }
            }
          }

          Row {
            x: Style.space(14)
            spacing: Style.space(6)

            Repeater {
              model: root.filterKeys.length

              Rectangle {
                readonly property string key: root.filterKeys[index]
                readonly property bool selected: root.filter === key
                height: Style.space(22)
                width: chipText.implicitWidth + Style.space(18)
                radius: height / 2
                color: selected ? root.barForeground : Qt.rgba(1, 1, 1, 0.05)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, selected ? 0 : 0.12)

                Text {
                  id: chipText
                  anchors.centerIn: parent
                  text: root.filterLabels[index]
                  color: parent.selected ? Color.background : root.barForeground
                  opacity: parent.selected ? 1 : 0.7
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: {
                    root.clearTransientState();
                    root.filter = parent.key;
                    searchInput.forceActiveFocus();
                  }
                }
              }
            }
          }

          Item { width: 1; height: Style.space(2) }
        }

        // ---- The list itself
        ListView {
          id: clipList
          anchors.top: listHeader.bottom
          anchors.bottom: listFooter.top
          anchors.left: parent.left
          anchors.right: parent.right
          clip: true
          model: clipModel
          currentIndex: -1
          highlightMoveDuration: 0
          cacheBuffer: Style.space(400)
          boundsBehavior: Flickable.StopAtBounds
          visible: clipModel.count > 0

          section.property: "section"
          section.criteria: ViewSection.FullString
          section.delegate: Item {
            width: ListView.view ? ListView.view.width : 0
            height: Style.space(24)

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: String(section).toUpperCase()
                color: root.barForeground
                opacity: 0.4
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              // Only the pinned section carries a count pill, matching the
              // desktop popup's single badged group header.
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: String(section) === "Pinned" && root.pinnedCount > 0
                width: pinCount.implicitWidth + Style.space(10)
                height: Style.space(15)
                radius: height / 2
                color: Qt.rgba(1, 1, 1, 0.08)
                Text {
                  id: pinCount
                  anchors.centerIn: parent
                  text: String(root.pinnedCount)
                  color: root.barForeground
                  opacity: 0.55
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Page in as the user approaches the end, via --limit/--offset.
          onContentYChanged: {
            if (root.hasMore && !root.loadingMore && contentHeight > 0
                && contentY + height > contentHeight - Style.space(240)) {
              root.loadMore();
            }
          }

          delegate: Rectangle {
            id: clipRow

            // Hoist every role once so nested scopes never have to resolve
            // `model.*` through a shadowed context.
            readonly property int rowIndex: index
            readonly property int clipId: model.clipId
            readonly property string rowKind: model.kind
            readonly property string rowTitle: model.title
            readonly property string rowSecondary: model.secondary
            readonly property string rowTime: model.timeLabel
            readonly property string rowThumb: model.thumb
            readonly property string rowGlyph: model.glyph
            readonly property bool rowPinned: model.pinned
            readonly property bool rowSaved: model.saved
            readonly property bool selected: ListView.isCurrentItem
            readonly property bool armed: root.armedDeleteId === clipId
            readonly property string rowPayload: model.payload
            readonly property string rowFiles: model.files
            readonly property var visual: root.visualSize(model.imageWidth, model.imageHeight)
            readonly property bool hasVariants: (rowKind === "url" && rowPayload.length > 0) || rowKind === "files"

            width: ListView.view ? ListView.view.width : 0
            // Deliberately constant: ListView estimates contentHeight from the
            // delegates it has built, and the panel's own height is derived
            // from contentHeight. A varying row height turns that into a
            // feedback loop that visibly jitters the popup.
            height: Style.space(62)
            color: selected ? Qt.rgba(1, 1, 1, 0.07) : "transparent"

            // Row body opens copy directly. The desktop app opens an inspector
            // here instead; this build has no detail sheet, so the primary
            // action is promoted to the row.
            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              onEntered: clipList.currentIndex = clipRow.rowIndex
              onClicked: root.copyClip(clipRow.rowIndex)
            }

            // ---- Leading visual: thumbnail for image clips, kind tile otherwise
            Item {
              id: leading
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              width: root.leadingSlot
              height: root.leadingSlot

              Rectangle {
                anchors.centerIn: parent
                // Thumbnails keep enough of their aspect ratio to make
                // landscape vs portrait feel intentional; glyph tiles are a
                // fixed square.
                width: thumbImage.visible ? clipRow.visual.width : Style.space(40)
                height: thumbImage.visible ? clipRow.visual.height : Style.space(40)
                radius: 8
                color: Qt.rgba(1, 1, 1, 0.06)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.10)
                clip: true

                Image {
                  id: thumbImage
                  anchors.fill: parent
                  visible: clipRow.rowThumb.length > 0 && status === Image.Ready
                  source: clipRow.rowThumb
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  sourceSize.width: 96
                  sourceSize.height: 96
                  smooth: true
                }

                Text {
                  anchors.centerIn: parent
                  visible: !thumbImage.visible
                  text: clipRow.rowGlyph
                  color: root.barForeground
                  opacity: 0.6
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // ---- Content: title, secondary line, then time + action rail
            Column {
              id: body
              anchors.left: leading.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: clipRow.rowTitle
                color: root.barForeground
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                width: parent.width
                visible: clipRow.rowSecondary.length > 0
                text: clipRow.rowSecondary
                color: root.barForeground
                opacity: 0.4
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Item {
                width: parent.width
                height: Style.space(24)

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: clipRow.rowTime
                  color: root.barForeground
                  opacity: 0.4
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                // The whole rail is selection/hover-only, as in the web popup.
                Row {
                  id: rail
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  visible: clipRow.selected || root.menuClipRow === clipRow.rowIndex

                  RowAction {
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: root.glyphTrash
                    tint: clipRow.armed ? "#ff9b90" : root.barForeground
                    restOpacity: clipRow.armed ? 1.0 : 0.45
                    onActivated: root.deleteClip(clipRow.rowIndex)
                  }

                  RowAction {
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: root.glyphPin
                    restOpacity: clipRow.rowPinned ? 0.9 : 0.45
                    onActivated: root.togglePinned(clipRow.rowIndex)
                  }

                  RowAction {
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: clipRow.rowSaved ? root.glyphSaved : root.glyphUnsaved
                    restOpacity: clipRow.rowSaved ? 0.9 : 0.45
                    onActivated: root.toggleSaved(clipRow.rowIndex)
                  }

                  // Split button: "Copy" is primary, the chevron opens the
                  // secondary copy variants (Markdown / file path forms).
                  Row {
                    id: copySplit
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    Rectangle {
                      width: copyLabel.implicitWidth + Style.space(16)
                      height: Style.space(22)
                      radius: height / 2
                      color: root.barForeground
                      // Square off the shared edge when the chevron is present.
                      Rectangle {
                        visible: clipRow.hasVariants
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.radius
                        color: parent.color
                      }

                      Text {
                        id: copyLabel
                        anchors.centerIn: parent
                        text: "Copy"
                        color: Color.background
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.copyClip(clipRow.rowIndex)
                      }
                    }

                    Rectangle {
                      visible: clipRow.hasVariants
                      width: Style.space(18)
                      height: Style.space(22)
                      radius: height / 2
                      color: root.barForeground
                      Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.radius
                        color: parent.color
                      }
                      Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 1
                        height: parent.height - Style.space(8)
                        color: Qt.rgba(0, 0, 0, 0.18)
                      }

                      Text {
                        anchors.centerIn: parent
                        text: root.glyphChevron
                        color: Color.background
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                          if (root.menuClipRow === clipRow.rowIndex) root.closeMenu();
                          else root.openMenu(clipRow.rowIndex, copySplit);
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ---- Empty / loading state, occupying the same slot as the list
        Item {
          anchors.top: listHeader.bottom
          anchors.bottom: listFooter.top
          anchors.left: parent.left
          anchors.right: parent.right
          visible: clipModel.count === 0

          Column {
            anchors.centerIn: parent
            width: parent.width - Style.space(48)
            spacing: Style.space(4)

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.loading && !root.loaded ? "Loading…" : root.emptyTitle
              color: root.barForeground
              opacity: 0.55
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              visible: text.length > 0 && !(root.loading && !root.loaded)
              text: root.emptyDetail
              color: root.barForeground
              opacity: 0.35
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ---- Footer: status slot on the left, shortcut on the right
        Column {
          id: listFooter
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: 0

          Item {
            width: parent.width - Style.space(28)
            x: Style.space(14)
            height: Style.space(24)

            Text {
              anchors.left: parent.left
              anchors.right: shortcutLabel.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              // Notices outrank persistent warnings, which outrank the count.
              text: root.notice.length > 0 ? root.notice
                  : root.warning.length > 0 ? root.warning
                  : root.countLabel
              color: root.barForeground
              opacity: root.notice.length > 0 ? 0.7 : 0.4
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              id: shortcutLabel
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.globalShortcut.length > 0
              text: root.globalShortcut
              color: root.barForeground
              opacity: 0.4
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Item { width: 1; height: Style.space(8) }
        }
      }

      // ---- Copy-variant menu, drawn at panel level so the ListView's clip
      // rectangle cannot cut it off.
      MouseArea {
        anchors.fill: parent
        visible: root.menuClipRow >= 0
        onClicked: root.closeMenu()
        z: 50
      }

      Rectangle {
        visible: root.menuClipRow >= 0
        z: 51
        x: Math.max(Style.space(8), Math.min(root.menuX - width + Style.space(24), keyCatcher.width - width - Style.space(8)))
        y: Math.min(root.menuY, keyCatcher.height - height - Style.space(8))
        width: Math.max(Style.space(150), menuColumn.implicitWidth + Style.space(16))
        height: menuColumn.implicitHeight + Style.space(8)
        radius: 8
        color: Color.background
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.16)

        Column {
          id: menuColumn
          anchors.centerIn: parent
          width: parent.width - Style.space(8)
          spacing: 0

          Repeater {
            model: root.menuActions

            Rectangle {
              width: parent.width
              height: Style.space(26)
              radius: 6
              color: itemArea.containsMouse ? Qt.rgba(1, 1, 1, 0.10) : "transparent"

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                color: root.barForeground
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: itemArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.invokeMenuAction(modelData.id)
              }
            }
          }
        }
      }

      // ================= SETTINGS =================
      // A Flickable, not a bare Column: contentHeight below is capped, and a
      // column taller than that cap would otherwise lay out past the panel's
      // rounded background — painting over the desktop and putting its last
      // rows out of reach. Clipping contains it; flicking makes it reachable.
      Flickable {
        id: settingsView
        anchors.fill: parent
        visible: root.settingsOpen
        clip: true
        contentWidth: width
        contentHeight: settingsColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

      Column {
        id: settingsColumn
        width: parent.width
        spacing: Style.space(8)

        Item { width: 1; height: Style.space(12) }

        Item {
          width: parent.width - Style.space(28)
          x: Style.space(14)
          height: Style.space(24)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.glyphBack
              color: root.barForeground
              opacity: backHover.containsMouse ? 0.9 : 0.5
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Settings"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          MouseArea {
            id: backHover
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.settingsOpen = false
          }
        }

        SectionHeader { text: "GENERAL" }

        SettingRow {
          title: "Launch at login"
          subtitle: "Started by Hyprland via exec-once"
          Toggle {
            checked: root.launchAtLogin
            onToggled: { root.launchAtLogin = checked; root.persist(); }
          }
        }

        SettingRow {
          title: "Global shortcut"
          subtitle: "Owned by the compositor on Wayland — set it in bindings.lua, or run clipbasket-omarchy make-default"
          Rectangle {
            width: shortcutText.implicitWidth + Style.space(16)
            height: Style.space(22)
            radius: 4
            color: Qt.rgba(1, 1, 1, 0.06)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.12)
            Text {
              id: shortcutText
              anchors.centerIn: parent
              text: root.shortcutLabelText
              color: root.barForeground
              opacity: 0.75
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        SectionHeader { text: "HISTORY" }

        SettingRow {
          title: "Maximum saved clips"
          subtitle: "500 ≈ 2 weeks, 1000 ≈ 1 month, 2000 ≈ 2 months"
          Rectangle {
            width: Style.space(76)
            height: Style.space(24)
            radius: 4
            color: Qt.rgba(1, 1, 1, 0.06)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, maxInput.activeFocus ? 0.25 : 0.12)
            TextInput {
              id: maxInput
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: String(root.maxClips)
              color: root.barForeground
              horizontalAlignment: Text.AlignRight
              validator: IntValidator { bottom: 50; top: 100000 }
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              selectByMouse: true
              onEditingFinished: { root.maxClips = parseInt(text) || root.maxClips; root.persist(); }
            }
          }
        }

        SettingRow {
          title: "Ignore confidential copies"
          subtitle: "Skip x-kde-passwordManagerHint and CLIPBOARD_STATE=sensitive"
          Toggle {
            checked: root.ignoreConfidentialCopies
            onToggled: { root.ignoreConfidentialCopies = checked; root.persist(); }
          }
        }

        SectionHeader { text: "BEHAVIOR" }

        SettingRow {
          title: "Close popup after action"
          subtitle: "Hide the popup after selecting or copying a clip"
          Toggle {
            checked: root.closePanelAfterAction
            onToggled: {
              root.closePanelAfterAction = checked;
              root.normalizeSettings();
              root.persist();
            }
          }
        }

        SettingRow {
          title: "Open at cursor on shortcut"
          subtitle: "Show the popup near the pointer instead of under the bar widget"
          Toggle {
            checked: root.openAtCursorOnShortcut
            onToggled: { root.openAtCursorOnShortcut = checked; root.persist(); }
          }
        }

        SettingRow {
          title: "Paste immediately"
          subtitle: root.closePanelAfterAction
            ? "After picking a clip, paste it into the focused window (needs wtype)"
            : "Auto-paste requires closing the popup first."
          Toggle {
            checked: root.pasteSelectedClipImmediately
            opacity: root.closePanelAfterAction ? 1 : 0.4
            onToggled: {
              if (!root.closePanelAfterAction) { checked = false; return; }
              root.pasteSelectedClipImmediately = checked;
              root.persist();
            }
          }
        }

        SectionHeader { text: "ABOUT" }

        SettingRow {
          title: "Version"
          subtitle: "clipbasket.clipboard — Clipbasket for Omarchy"
          Rectangle {
            width: verText.implicitWidth + Style.space(14)
            height: Style.space(20)
            radius: 4
            color: Qt.rgba(1, 1, 1, 0.06)
            Text {
              id: verText
              anchors.centerIn: parent
              text: "0.3.0"
              color: root.barForeground
              opacity: 0.7
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          x: Style.space(14)
          width: parent.width - Style.space(28)
          wrapMode: Text.WordWrap
          text: "Updates, theme and paste-permission settings are absent by design: pacman owns updates, Omarchy owns theming, and Wayland needs no accessibility grant."
          color: root.barForeground
          opacity: 0.35
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Item { width: 1; height: Style.space(10) }
      }
      }
    }
  }
}
