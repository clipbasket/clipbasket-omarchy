import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Three views in one panel: the clip list, the detail view for a single clip
// (reached from a row), and a settings page reached from the cog in the
// header. The list is a faithful port of the desktop app's popup --
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

  // The one place the version is written in this file. It has to match
  // manifest.json's "version" -- there is no way for QML to read the manifest,
  // so this is a copy by necessity and the only defence is that it is a single
  // copy.
  readonly property string pluginVersion: "1.0.0"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- View state
  property string query: ""
  property string filter: "all"
  property bool settingsOpen: false
  property bool detailOpen: false
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

  // ---- Detail view. Keyed by clip *id*, not by row index: pin, save and copy
  // all queue a reload that re-sorts the model underneath us, so the index is
  // re-resolved from the id after every list replace (see listProc below).
  // `detailClip` is the full record from `clipbasket-db get` -- the list
  // endpoint truncates `text`, which is exactly what this view exists to show.
  property int detailClipId: -1
  property int detailIndex: -1
  property var detailClip: null
  property bool detailLoading: false
  property string detailError: ""
  // Pinned/saved are mirrored here rather than read off `detailClip`: the
  // toggles below update the model optimistically and the fetched record would
  // otherwise stay stale until the next `get`.
  property bool detailPinned: false
  property bool detailSaved: false

  // ---- Copy-variant menu (panel-level overlay so the ListView cannot clip it).
  // Keyed by clip id, not row index: a search debounce or a post-mutation
  // reload re-sorts the model while the menu is open, and an index captured at
  // open time would then point at whatever row had moved into that slot -- so
  // "Copy as Markdown" would run against a different clip than the one the
  // user opened the menu on.
  property int menuClipId: -1
  property real menuX: 0
  property real menuY: 0
  property var menuActions: []

  // Settings state. Names, defaults and semantics come from
  // settings.schema.json; unknown keys in the file are preserved on write.
  property string globalShortcut: ""
  property int maxClips: 1000
  property bool ignoreConfidentialCopies: true
  property bool closePanelAfterAction: true
  property bool pasteSelectedClipImmediately: false
  // Assumed present until the probe says otherwise, so the row does not flash
  // "install wtype" on every open for the people who have it.
  property bool wtypeAvailable: true
  // The opposite default: an Open action that does nothing is worse than one
  // that appears a frame late, so it stays hidden until the probe confirms it.
  property bool xdgOpenAvailable: false

  // Chip label -> backend `--filter` value. Order and wording mirror
  // PopupHeader.tsx exactly; there is deliberately no "Pinned" chip because
  // pins are a section, not a filter.
  readonly property var filterKeys: ["all", "text", "url", "image", "files", "saved"]
  readonly property var filterLabels: ["All", "Text", "Links", "Images", "Files", "Saved"]

  readonly property string settingsDir: "${XDG_CONFIG_HOME:-$HOME/.config}/clipbasket"
  readonly property string settingsPath: root.settingsDir + "/settings.json"
  // The compositor owns SUPER + CTRL + V, so "is Clipbasket the default?" is
  // not a setting in settings.json -- the truth is the managed block in
  // bindings.lua, and `clipbasket-omarchy` is the only thing allowed to write
  // it. `make-default` leaves this marker behind; `restore-default` removes it.
  readonly property string stateDir: "${XDG_STATE_HOME:-$HOME/.local/state}/clipbasket"
  readonly property string defaultStatePath: root.stateDir + "/make-default.json"
  readonly property string cliPath: root.pluginDir + "/bin/clipbasket-omarchy"
  // Same derivation as cliPath: the helper ships beside the rest of bin/.
  readonly property string safefilePath: root.pluginDir + "/bin/clipbasket-safefile"
  property bool isDefaultShortcut: false
  property bool shortcutBusy: false
  // Empty means "no compositor binding recorded yet"; the compositor owns it.
  readonly property string shortcutLabelText: root.globalShortcut.length > 0 ? root.globalShortcut : "Unbound"

  // ---- Nerd Font glyphs. ALWAYS \uXXXX escapes: literal PUA codepoints get
  // stripped in transit and an empty `text: ""` collapses the item silently.
  readonly property string glyphBrand:    "\uf0ea"  // clipboard
  readonly property string glyphCog:      "\uf013"  // cog
  readonly property string glyphBack:     "\uf053"  // chevron-left
  readonly property string glyphForward:  "\uf054"  // chevron-right
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
  readonly property string glyphOpen:     "\uf08e"  // external-link
  readonly property string glyphReveal:   "\uf07c"  // folder-open-o
  readonly property string glyphExpand:   "\uf065"  // expand

  // Every subtle surface in this panel was white at a low alpha, which is an
  // invisible no-op on Omarchy's light themes -- the Toggle's off state
  // disappeared completely, and the search field lost its border. Derived from
  // the theme's own foreground instead, so an overlay is always the opposite of
  // whatever it sits on.
  function fg(a) {
    return Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, a);
  }

  // Armed-delete tint. Omarchy's palette exposes no danger role, so this is
  // derived rather than named: a light foreground means a dark theme and wants
  // the light red, while a dark foreground means a light theme, where #ff9b90
  // is a pale wash nobody would read as a warning.
  readonly property color dangerTint: root.barForeground.hslLightness > 0.5
    ? "#ff9b90"
    : "#b3261e"

  // Style carries no documented monospace token; probing for one keeps us on a
  // token if the theme grows it, and otherwise falls back to Fontconfig's
  // generic alias rather than naming a font that may not be installed.
  readonly property string monoFamily: Style.font.mono || Style.font.familyMono || "monospace"

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

  // A failing invocation prints this instead of the data it could not fetch.
  // It has to be valid JSON -- every caller parses -- and it must not be
  // mistakable for a legitimate result, which is why it is not `[]`: an empty
  // array from a missing clipbasket-db, a missing sqlite3 or an unreadable
  // database renders as "Ready when you are", telling the user their history is
  // empty when the truth is that nothing could be read.
  readonly property string dbErrorSentinel: '{"clipbasketError":"unavailable"}'

  function isDbError(parsed) {
    return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
        && parsed.clipbasketError === "unavailable";
  }

  // Every invocation is wrapped so a missing binary degrades to a reported
  // failure instead of throwing: stderr is dropped and the sentinel is echoed.
  function dbCmd(args) {
    return "export PATH=" + shq(root.pluginDir + "/bin") + ":$PATH; "
         + "clipbasket-db " + args + " 2>/dev/null || printf %s " + shq(root.dbErrorSentinel);
  }

  // encodeURI leaves #, ? and + alone because they are legal URI syntax, which
  // is exactly wrong for a filename: a thumbnail of "Screenshot #3.png" becomes
  // a URL with a fragment and silently renders nothing. Each segment is encoded
  // separately so the separators survive and everything else is escaped.
  function fileUrl(path) {
    if (!path) return "";
    var p = String(path);
    if (p.indexOf("file://") === 0) return p;
    var parts = p.split("/");
    for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i]);
    return "file://" + parts.join("/");
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

  // The list trades precision for scannability; the detail view has room for
  // the unambiguous stamp, like formatAbsoluteDateTime in the desktop popup.
  function formatAbsolute(ts) {
    if (!ts) return "";
    return Qt.formatDateTime(new Date(ts), "MMM d, yyyy  ·  h:mm AP");
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
      urlDomain: String(clip.url_domain || ""),
      // Absent on an older CLI, which simply degrades to the URL-only
      // Markdown rule this build shipped with.
      hasHtml: clip.has_html === true,
      sourceApp: String(clip.source_app || ""),
      sizeBytes: root.num(clip.size_bytes, 0),
      createdAt: root.createdMs(clip)
    };
  }

  function appendPage(clips, replace, requestedLimit) {
    if (replace) {
      clipModel.clear();
      root.loadedCount = 0;
      root.pinnedCount = 0;
    }
    var sorted = root.sortPage(clips);
    for (var i = 0; i < sorted.length; i++) {
      clipModel.append(root.toRow(sorted[i]));
    }
    root.loadedCount += clips.length;
    root.hasMore = clips.length >= requestedLimit;
    root.recomputePinnedCount();
  }

  // ---- item 15: pinned rows are counted from the model, never accumulated.
  // Incrementing on append alone went stale the moment a row was deleted or
  // unpinned, and the count pill is the only thing telling the user how many
  // pins the section holds.
  function recomputePinnedCount() {
    var n = 0;
    for (var i = 0; i < clipModel.count; i++) {
      if (clipModel.get(i).section === "Pinned") n += 1;
    }
    root.pinnedCount = n;
  }

  property int pinnedCount: 0

  // ------------------------------------------------------------- data loads

  property bool replaceOnNextPage: true

  function listArgs(offset, limit) {
    var args = "list --limit " + limit + " --offset " + offset + " --filter " + root.filter;
    if (root.query.length > 0) args += " --query " + root.shq(root.query);
    return args;
  }

  // `count` has to be told the same filter and query as `list`, or its
  // `filtered` total describes the whole history instead of what is on screen
  // -- searching for one clip among sixteen reported "16 matches".
  function countArgs() {
    var args = "count --filter " + root.filter;
    if (root.query.length > 0) args += " --query " + root.shq(root.query);
    return args;
  }

  // Every list request carries a sequence number that the shell echoes back on
  // its own first line, and a response whose sequence is not the current one is
  // dropped. Killing a Process does not cancel the StdioCollector that is
  // already collecting for it, so without this a page-2 response could arrive
  // after a new search had reset the query and be applied as if it were page 1
  // of the new one.
  property int listSeq: 0
  property var listRequest: null

  function sendList(replace, offset, limit, keepScroll) {
    root.listSeq += 1;
    root.listRequest = {
      seq: root.listSeq,
      replace: replace === true,
      limit: limit,
      keepScroll: keepScroll === true ? clipList.contentY : -1
    };
    if (listProc.running) listProc.running = false;
    listProc.command = ["sh", "-c",
      "printf '%s\\n' " + root.listSeq + "; " + root.dbCmd(root.listArgs(offset, limit))];
    listProc.running = true;
  }

  // `keepDepth` is for the reload that follows a mutation: pin, save and delete
  // all re-sort the list underneath us, and re-reading only the first page
  // would throw away every row the user had scrolled to and send them back to
  // the top. Ask for as many rows as are already on screen instead.
  function reload(keepDepth) {
    var deep = keepDepth === true && root.loadedCount > root.pageSize;
    root.replaceOnNextPage = true;
    root.loading = true;
    root.sendList(true, 0, deep ? root.loadedCount : root.pageSize, deep);
    countProc.command = ["sh", "-c", root.dbCmd(root.countArgs())];
    countProc.running = true;
  }

  function loadMore() {
    if (root.loadingMore || root.loading || !root.hasMore || listProc.running) return;
    root.loadingMore = true;
    root.replaceOnNextPage = false;
    root.sendList(false, root.loadedCount, root.pageSize, false);
  }

  function refresh() {
    root.reload();
    settingsProbe.running = true;
    root.probeDefaultShortcut();
    if (!toolProbe.running) toolProbe.running = true;
  }
  function openFromHotkey() { root.controller.show(); }

  onOpenedChanged: {
    if (root.opened) {
      // Panel-open reset, matching the desktop popup: filter back to all,
      // search cleared, selection on the first row, search field focused.
      root.suspendReloads = true;
      root.settingsOpen = false;
      root.resetDetail();
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
      root.resetDetail();
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
        // First line is the sequence number this request was sent with; the
        // rest is the payload.
        var raw = String(text);
        var nl = raw.indexOf("\n");
        var seq = nl >= 0 ? parseInt(raw.substring(0, nl), 10) : NaN;
        var body = nl >= 0 ? raw.substring(nl + 1) : raw;
        var req = root.listRequest;
        // A response for a request that has already been superseded describes a
        // query, filter or offset that is no longer on screen. Drop it whole:
        // applying it would replace the current results with stale rows.
        if (!req || !isFinite(seq) || seq !== req.seq) return;

        root.loading = false;
        root.loadingMore = false;
        var wasReplace = req.replace;
        var parsed = null;
        try { parsed = JSON.parse(String(body).trim()); } catch (e) { parsed = null; }
        if (parsed === null || !Array.isArray(parsed)) {
          if (wasReplace) { clipModel.clear(); root.loadedCount = 0; root.pinnedCount = 0; }
          // Unconditional: a failed page-2 fetch that leaves hasMore true is
          // retried on every scroll delta for as long as the user keeps
          // scrolling.
          root.hasMore = false;
          root.warning = root.isDbError(parsed)
            ? "Clipbasket can't read your history"
            : "Unable to load clips";
          root.loaded = true;
          return;
        }
        root.warning = "";
        root.appendPage(parsed, wasReplace, req.limit);
        root.loaded = true;
        if (wasReplace) {
          // Pin toggles and copies both re-sort the model, so an open detail
          // view is re-bound by clip id instead of by its stale row index. A
          // clip that no longer exists (deleted, or trimmed by maxClips) sends
          // the panel back to the list rather than showing a dead record.
          var keep = root.detailOpen ? root.indexOfClipId(root.detailClipId) : -1;
          if (root.detailOpen && keep < 0) root.closeDetail();
          if (keep >= 0) {
            root.detailIndex = keep;
            var kept = clipModel.get(keep);
            root.detailPinned = kept.pinned === true;
            root.detailSaved = kept.saved === true;
            clipList.currentIndex = keep;
            clipList.positionViewAtIndex(keep, ListView.Contain);
          } else if (req.keepScroll >= 0) {
            // A reload after pin/save/delete re-read everything the user had
            // scrolled to, so put them back where they were rather than at the
            // top of a list they have to scroll through again.
            clipList.currentIndex = clipModel.count > 0
              ? Math.min(clipList.currentIndex < 0 ? 0 : clipList.currentIndex, clipModel.count - 1)
              : -1;
            clipList.contentY = Math.max(0,
              Math.min(req.keepScroll, Math.max(0, clipList.contentHeight - clipList.height)));
          } else {
            clipList.currentIndex = clipModel.count > 0 ? 0 : -1;
            clipList.positionViewAtBeginning();
          }
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
          // A failed count must not read as "0 clips"; keeping the last known
          // numbers is the honest degradation, and the warning line above
          // already says the history could not be read.
          if (root.isDbError(c)) return;
          root.totalCount = root.num(c.total, 0);
          root.matchingCount = root.num(c.filtered, root.totalCount);
        } catch (e) { /* leave the previous counts alone */ }
      }
    }
  }

  // `get` returns the untruncated record for one clip. Kept off the action
  // queue so opening the detail view never waits behind a pending mutation.
  Process {
    id: detailProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.detailOpen) return;
        var parsed = null;
        try { parsed = JSON.parse(String(text).trim()); } catch (e) { parsed = null; }
        if (!parsed || typeof parsed !== "object" || root.isDbError(parsed)) {
          root.detailLoading = false;
          root.detailClip = null;
          root.detailError = root.isDbError(parsed)
            ? "Clipbasket can't read your history."
            : "Unable to load this clip.";
          return;
        }
        // A fast Enter-Escape-Enter run can land an older response after the
        // view has moved on; the id is the only thing that can tell. Leaving
        // the loading flag alone keeps the placeholder up for the live request.
        if (root.num(parsed.id, -1) !== root.detailClipId) return;
        root.detailLoading = false;
        root.detailError = "";
        root.detailClip = parsed;
        root.detailPinned = parsed.pinned === true;
        root.detailSaved = parsed.saved === true;
      }
    }
  }

  // HTML -> Markdown is the CLI's job; QML never parses HTML. A clip with no
  // HTML answers with a JSON error object, which is why the payload is read
  // back here instead of being piped straight into wl-copy.
  property int markdownClipId: -1

  Process {
    id: markdownProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var id = root.markdownClipId;
        root.markdownClipId = -1;
        var md = "";
        try {
          var parsed = JSON.parse(String(text).trim());
          if (parsed && typeof parsed.markdown === "string") md = parsed.markdown;
        } catch (e) { md = ""; }
        if (md.length === 0) {
          // Belt and braces: a URL clip whose HTML failed to convert still has
          // the link form the desktop app falls back to.
          md = root.markdownFor(root.rowAt(root.indexOfClipId(id)));
        }
        if (md.length === 0) {
          root.showNotice("Clipbasket couldn't convert this clip to Markdown.");
          return;
        }
        root.finishMarkdown(md);
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
        // the sections contiguous instead of patching rows in place. `true`
        // re-reads to the depth already on screen and restores the scroll
        // position, so pinning row 80 does not collapse the list to 50 rows.
        if (root.opened) root.reload(true);
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

  function indexOfClipId(id) {
    if (id < 0) return -1;
    for (var i = 0; i < clipModel.count; i++) {
      if (clipModel.get(i).clipId === id) return i;
    }
    return -1;
  }

  // A clip is openable if it is a link, or a text clip whose entire payload is
  // one bare URL -- the capture classifier is deliberately conservative, so a
  // copied address with an unusual scheme or a trailing character lands as
  // text, and refusing to open it would be a distinction only the database
  // cares about.
  //
  // Matched with indexOf rather than a regular expression on purpose: Qt
  // 6.9's qmllint allocates without bound on a regex literal reached from a
  // loop body, and this file is linted. There is no reason to hand it one.
  readonly property var openableSchemes: ["https://", "http://", "ftp://"]

  function urlForRow(row) {
    if (!row) return "";
    var t = String(row.payload || "").trim();
    if (t.length === 0 || t.length > 2048) return "";
    // A URL with whitespace in it is a sentence that begins with a URL.
    if (t.indexOf(" ") >= 0 || t.indexOf("\n") >= 0 || t.indexOf("\t") >= 0) return "";
    if (row.kind === "url") return t;
    if (row.kind !== "text") return "";
    var lower = t.toLowerCase();
    for (var i = 0; i < root.openableSchemes.length; i++) {
      var scheme = root.openableSchemes[i];
      if (lower.indexOf(scheme) === 0 && t.length > scheme.length) return t;
    }
    return "";
  }

  function canOpenUrl(row) {
    return root.xdgOpenAvailable && root.urlForRow(row).length > 0;
  }

  // Detached, and never waited on: xdg-open blocks for as long as the handler
  // takes to start, which for a cold browser is seconds, and actionProc is a
  // serialised queue that everything else is behind. The `command -v` guard
  // stays in the command as well as in the caller, because the binary can be
  // removed between the probe and the click.
  function openExternally(target) {
    if (!target) return;
    root.runAction("command -v xdg-open >/dev/null 2>&1 && "
                   + "setsid xdg-open " + root.shq(target) + " >/dev/null 2>&1 &", false);
  }

  function openUrl(index) {
    var url = root.urlForRow(root.rowAt(index));
    if (url.length === 0 || !root.xdgOpenAvailable) return;
    root.clearTransientState();
    root.openExternally(url);
    if (root.closePanelAfterAction) root.close();
    else root.showNotice("Opening link…");
  }

  // Reveal is Open pointed at the parent directory -- there is no portable
  // "select this file in the file manager" on Linux, and opening the folder is
  // what every desktop actually does with the request.
  function openFilePath(path, reveal) {
    if (!path || !root.xdgOpenAvailable) return;
    var target = String(path);
    if (reveal) {
      var trimmed = target;
      while (trimmed.length > 1 && trimmed.charAt(trimmed.length - 1) === "/") {
        trimmed = trimmed.substring(0, trimmed.length - 1);
      }
      var cut = trimmed.lastIndexOf("/");
      target = cut > 0 ? trimmed.substring(0, cut) : "/";
    }
    root.clearTransientState();
    root.openExternally(target);
    if (root.closePanelAfterAction) root.close();
    else root.showNotice(reveal ? "Opening folder…" : "Opening file…");
  }

  function copyOneFilePath(path) {
    if (!path) return;
    root.clearTransientState();
    root.runAction(root.copyTextCommand(String(path)), false);
    if (root.closePanelAfterAction) root.close();
    else root.showNotice("Full path copied.");
  }

  function copyTextCommand(value) {
    return "printf %s " + root.shq(value) + " | wl-copy";
  }

  function copyClip(index) {
    var row = root.rowAt(index);
    if (!row) return;
    root.clearTransientState();
    // `copy` also bumps created_at, so an open panel has to re-read.
    root.runAction(root.dbCmd("copy " + row.clipId), !root.closePanelAfterAction);
    if (root.closePanelAfterAction) {
      root.close();
      // Auto-paste only ever runs after the panel is gone, otherwise the
      // synthetic Ctrl+V lands in the panel instead of the focused window.
      // The wtype guard stays in the command as well as in the setting: the
      // binary can be uninstalled between the probe and the keystroke.
      if (root.pasteSelectedClipImmediately && root.wtypeAvailable) {
        root.runAction("command -v wtype >/dev/null 2>&1 && sleep 0.12 && wtype -M ctrl -P v -p v -m ctrl", false);
      }
    } else {
      root.showNotice("Copied.");
    }
  }

  // The desktop app derives Markdown by running turndown over the clip's
  // stored HTML flavor. Here the conversion belongs to `clipbasket-db
  // markdown`; this stays the fallback for a URL clip that has no HTML, which
  // is the one rule that can be honoured losslessly without any HTML at all.
  function markdownFor(row) {
    if (!row || row.kind !== "url") return "";
    var url = row.payload;
    if (!url) return "";
    var label = row.urlTitle || row.urlDomain || url;
    return "[" + label + "](" + url + ")";
  }

  // Offered whenever the clip has an HTML flavor, plus the URL case that
  // predates it. Shared by the row's variant menu and the detail view so the
  // two can never disagree about when the action exists.
  function supportsMarkdown(row) {
    if (!row) return false;
    if (row.hasHtml === true) return true;
    return row.kind === "url" && String(row.payload || "").length > 0;
  }

  function copyMarkdown(index) {
    var row = root.rowAt(index);
    if (!row) return;
    root.clearTransientState();
    if (row.hasHtml === true) {
      root.markdownClipId = row.clipId;
      if (markdownProc.running) markdownProc.running = false;
      markdownProc.command = ["sh", "-c", root.dbCmd("markdown " + row.clipId)];
      markdownProc.running = true;
      return;
    }
    var md = root.markdownFor(row);
    if (!md) { root.showNotice("Clipbasket couldn't convert this clip to Markdown."); return; }
    root.finishMarkdown(md);
  }

  function finishMarkdown(md) {
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
    // The section role decides which header the row sits under and feeds the
    // pinned count pill, so it has to move with the pin rather than wait for
    // the reload -- otherwise the row stays visually in "Now" until the
    // response lands, and the pill is wrong in the meantime.
    clipModel.setProperty(index, "section",
      next ? "Pinned" : root.sectionFor({ pinned: false, created_at: row.createdAt }));
    root.recomputePinnedCount();
    if (root.detailOpen && row.clipId === root.detailClipId) root.detailPinned = next;
    root.runAction(root.dbCmd("pin " + row.clipId + (next ? " --on" : " --off")), true);
  }

  function toggleSaved(index) {
    var row = root.rowAt(index);
    if (!row) return;
    var next = !row.saved;
    root.clearTransientState();
    clipModel.setProperty(index, "saved", next);
    if (root.detailOpen && row.clipId === root.detailClipId) root.detailSaved = next;
    root.runAction(root.dbCmd("save " + row.clipId + (next ? " --on" : " --off")), true);
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
    root.recomputePinnedCount();
    // Selection takes over the removed row's index, clamped to the last row.
    clipList.currentIndex = clipModel.count === 0 ? -1 : Math.min(index, clipModel.count - 1);
    root.runAction(root.dbCmd("delete " + id), true);
  }

  // ----------------------------------------------------------- copy variants

  function menuActionsFor(row) {
    var actions = [];
    if (!row) return actions;
    if (root.canOpenUrl(row)) actions.push({ id: "open", label: "Open in browser" });
    if (root.supportsMarkdown(row)) actions.push({ id: "markdown", label: "Copy as Markdown" });
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
    root.menuClipId = row.clipId;
    root.menuX = point.x;
    root.menuY = point.y + Style.space(4);
  }

  function closeMenu() { root.menuClipId = -1; root.menuActions = []; }

  function invokeMenuAction(actionId) {
    // Re-resolved at invoke time, so the action lands on the clip the menu was
    // opened for even if the list has re-sorted since.
    var index = root.indexOfClipId(root.menuClipId);
    root.closeMenu();
    if (index < 0) return;
    if (actionId === "open") root.openUrl(index);
    else if (actionId === "markdown") root.copyMarkdown(index);
    else if (actionId === "file-full") root.copyFileVariant(index, "full");
    else if (actionId === "file-name") root.copyFileVariant(index, "name");
    else if (actionId === "file-parent") root.copyFileVariant(index, "parent");
  }

  // ---------------------------------------------------------- detail view

  // Everything the detail view renders is derived from the fetched record by
  // the same toRow() the list uses, so title/secondary/glyph rules can never
  // drift between the two views.
  readonly property var detailRow: root.detailClip ? root.toRow(root.detailClip) : null
  readonly property string detailKind: root.detailRow ? root.detailRow.kind : ""
  readonly property string detailTitle: root.detailRow ? root.detailRow.title : ""
  readonly property string detailText: root.detailRow ? root.detailRow.payload : ""
  readonly property string detailMime: root.detailRow ? root.detailRow.mime : ""
  readonly property string detailImagePath: root.detailRow ? root.detailRow.imagePath : ""
  readonly property int detailImageW: root.detailRow ? root.detailRow.imageWidth : 0
  readonly property int detailImageH: root.detailRow ? root.detailRow.imageHeight : 0
  readonly property string detailSourceApp: root.detailRow ? root.detailRow.sourceApp : ""
  readonly property string detailWhen: root.detailRow ? root.formatAbsolute(root.detailRow.createdAt) : ""
  readonly property bool detailHasMarkdown: root.supportsMarkdown(root.detailRow)

  readonly property string detailDimensions:
    root.detailImageW > 0 && root.detailImageH > 0
      ? root.detailImageW + " × " + root.detailImageH
      : ""

  readonly property var detailFiles: {
    if (!root.detailRow || root.detailRow.kind !== "files") return [];
    var items = root.fileItems(root.detailRow);
    var out = [];
    for (var i = 0; i < items.length; i++) {
      var p = String(items[i].path || "");
      if (p.length > 0) out.push(p);
    }
    return out;
  }

  // One entry per copied path, split into the parts the row renders. The flat
  // `detailFiles` list above still feeds the whole-list copy variants, which
  // are unchanged.
  readonly property var detailFileRows: {
    if (!root.detailRow || root.detailRow.kind !== "files") return [];
    var items = root.fileItems(root.detailRow);
    var out = [];
    for (var i = 0; i < items.length; i++) {
      var full = String(items[i].path || "");
      if (full.length === 0) continue;
      var trimmed = full;
      while (trimmed.length > 1 && trimmed.charAt(trimmed.length - 1) === "/") {
        trimmed = trimmed.substring(0, trimmed.length - 1);
      }
      var cut = trimmed.lastIndexOf("/");
      out.push({
        path: full,
        name: String(items[i].name || (cut >= 0 ? trimmed.substring(cut + 1) : trimmed)),
        parent: cut > 0 ? trimmed.substring(0, cut) : "/",
        isDirectory: items[i].is_directory === true
      });
    }
    return out;
  }

  // ---- Image lightbox. Detail-local: dismissing it returns to the clip, not
  // to the list, so it is a mode of the detail view rather than a third view.
  property bool lightboxOpen: false
  readonly property bool detailHasImage:
    root.detailKind === "image" && root.detailImagePath.length > 0

  function toggleLightbox() {
    if (!root.detailHasImage) return;
    root.lightboxOpen = !root.lightboxOpen;
  }

  readonly property string detailSize: {
    if (!root.detailRow) return "";
    var s = root.humanSize(root.detailRow.sizeBytes);
    if (s.length > 0) return s;
    // Text and URL clips carry no size_bytes in the CLI contract, so the
    // character count is the only size signal they have.
    var n = root.detailText.length;
    return n > 0 ? n + (n === 1 ? " character" : " characters") : "";
  }

  readonly property string detailStateLabel: {
    if (!root.detailRow) return "";
    return (root.detailPinned ? "Pinned" : "Not pinned")
      + "  ·  " + (root.detailSaved ? "Saved" : "Not saved");
  }

  readonly property string detailKindLabel: {
    switch (root.detailKind) {
      case "url":   return "Link";
      case "image": return "Image";
      case "files": return root.detailFiles.length === 1 ? "File" : "Files";
      case "text":  return "Text";
    }
    return "";
  }

  function openDetail(index) {
    var row = root.rowAt(index);
    if (!row) return;
    root.clearTransientState();
    root.settingsOpen = false;
    root.detailIndex = index;
    root.detailClipId = row.clipId;
    root.detailPinned = row.pinned === true;
    root.detailSaved = row.saved === true;
    root.detailClip = null;
    root.detailError = "";
    root.detailLoading = true;
    root.lightboxOpen = false;
    root.detailOpen = true;
    // Inspecting a row is also selecting it, so leaving the list is a no-op
    // for the selection the user comes back to.
    clipList.currentIndex = index;
    if (detailProc.running) detailProc.running = false;
    detailProc.command = ["sh", "-c", root.dbCmd("get " + row.clipId)];
    detailProc.running = true;
    // The view has to exist before it can hold focus -- and by the time this
    // runs the panel may have been closed, or the detail view already left,
    // in which case forcing focus into a hidden view steals it from whatever
    // has it now.
    Qt.callLater(function () {
      if (!root.detailOpen) return;
      detailBody.contentY = 0;
      detailView.forceActiveFocus();
    });
  }

  function resetDetail() {
    root.lightboxOpen = false;
    root.detailOpen = false;
    root.detailClip = null;
    root.detailError = "";
    root.detailLoading = false;
    root.detailIndex = -1;
    root.detailClipId = -1;
  }

  function closeDetail() {
    if (!root.detailOpen) return;
    root.resetDetail();
    // The list keeps whatever currentIndex it had; only focus travels back.
    Qt.callLater(function () { searchInput.forceActiveFocus(); });
  }

  // deleteClip() only removes the row once its confirmation (if the clip is
  // protected) is satisfied, so "did the clip survive" is the honest test for
  // whether the detail view still has anything to show.
  function deleteFromDetail() {
    if (root.detailIndex < 0) return;
    var id = root.detailClipId;
    root.deleteClip(root.detailIndex);
    if (root.indexOfClipId(id) < 0) root.closeDetail();
  }

  function scrollSettings(delta) {
    var max = Math.max(0, settingsView.contentHeight - settingsView.height);
    settingsView.contentY = Math.min(max, Math.max(0, settingsView.contentY + delta));
  }

  function scrollDetail(delta) {
    var max = Math.max(0, detailBody.contentHeight - detailBody.height);
    detailBody.contentY = Math.min(max, Math.max(0, detailBody.contentY + delta));
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
    // Escape and Tab belong to PanelKeyCatcher (close, and switch panels). They
    // are never accepted here, at any depth, so they keep bubbling to it.
    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      // Two overlays swallow Escape to dismiss themselves rather than the whole
      // panel. With neither of them up it is never accepted here, so the close
      // path through PanelKeyCatcher is exactly as it was.
      if (event.key === Qt.Key_Escape) {
        if (root.menuClipId >= 0) { root.closeMenu(); return true; }
        if (root.lightboxOpen) { root.lightboxOpen = false; return true; }
      }
      return false;
    }
    if (root.settingsOpen) return root.handleSettingsKey(event);
    if (root.detailOpen) return root.handleDetailKey(event);
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
        // Enter copies -- this is the product's primary keystroke, and it is
        // what the desktop app binds it to. Inspecting a clip is Right or `i`.
        if (clipModel.count > 0) root.copyClip(clipList.currentIndex);
        return true;
      case Qt.Key_Right:
        // Same guard as Home/End: the search field's own cursor keys win while
        // there is text to move through.
        if (searchInput.activeFocus && searchInput.text.length > 0) return false;
        if (clipModel.count > 0) root.openDetail(clipList.currentIndex);
        return true;
      case Qt.Key_I:
        // The desktop app's second inspect key. Only reachable when the search
        // field does not have focus, because there it is just the letter i --
        // a shortcut that eats typing is worse than one nobody finds.
        if (searchInput.activeFocus) return false;
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return false;
        if (clipModel.count > 0) root.openDetail(clipList.currentIndex);
        return true;
      case Qt.Key_Delete:
      case Qt.Key_Backspace:
        // Plain Delete/Backspace must still edit the search text. Deleting a
        // clip needs either an empty search box or an explicit Ctrl.
        if ((event.modifiers & Qt.ControlModifier) || searchInput.text.length === 0) {
          // Auto-repeat is never a considered decision to delete. Held down,
          // the key destroys roughly fifteen clips a second and there is no
          // undo; the repeats are swallowed rather than passed on so they
          // cannot fall through to the search field either.
          if (event.isAutoRepeat) return true;
          if (clipModel.count > 0) root.deleteClip(clipList.currentIndex);
          return true;
        }
        return false;
    }
    return false;
  }

  // Settings-page keys. The page is a Flickable with no focusable rows, so the
  // navigation keys scroll it; without this they fall through to the list
  // behind and move a selection the user cannot see.
  function handleSettingsKey(event) {
    switch (event.key) {
      case Qt.Key_Left:     root.settingsOpen = false; return true;
      case Qt.Key_Down:     root.scrollSettings(Style.space(48)); return true;
      case Qt.Key_Up:       root.scrollSettings(-Style.space(48)); return true;
      case Qt.Key_PageDown: root.scrollSettings(settingsView.height * 0.9); return true;
      case Qt.Key_PageUp:   root.scrollSettings(-settingsView.height * 0.9); return true;
      case Qt.Key_Home:     settingsView.contentY = 0; return true;
      case Qt.Key_End:      root.scrollSettings(settingsView.contentHeight); return true;
    }
    return false;
  }

  // Detail-view keys. Escape also reaches PanelKeyCatcher.onCloseRequested when
  // focus sits in one of the selectable text blocks, and both paths land on
  // closeDetail(), so the view closes either way.
  function handleDetailKey(event) {
    // With the lightbox up, every key belongs to it. Anything not listed is
    // swallowed rather than passed through: the detail view behind is not what
    // the keys would appear to be acting on, and Delete in particular must not
    // reach a clip the user cannot currently see.
    if (root.lightboxOpen) {
      switch (event.key) {
        case Qt.Key_Space:
        case Qt.Key_Left:
        case Qt.Key_Return:
        case Qt.Key_Enter:
          root.lightboxOpen = false;
          return true;
      }
      return true;
    }
    switch (event.key) {
      case Qt.Key_Space:
        // Space is the desktop app's quick-look key. Only bound where there is
        // something to look at.
        if (root.detailHasImage) { root.toggleLightbox(); return true; }
        return false;
      case Qt.Key_Escape:
      case Qt.Key_Left:
        root.closeDetail(); return true;
      case Qt.Key_Return:
      case Qt.Key_Enter:
        root.copyClip(root.detailIndex); return true;
      case Qt.Key_Down:     root.scrollDetail(Style.space(48)); return true;
      case Qt.Key_Up:       root.scrollDetail(-Style.space(48)); return true;
      case Qt.Key_PageDown: root.scrollDetail(detailBody.height * 0.9); return true;
      case Qt.Key_PageUp:   root.scrollDetail(-detailBody.height * 0.9); return true;
      case Qt.Key_Home:     detailBody.contentY = 0; return true;
      case Qt.Key_End:      root.scrollDetail(detailBody.contentHeight); return true;
      case Qt.Key_Delete:
        // See handleNavKey: a held Delete must not walk the whole history.
        if (event.isAutoRepeat) return true;
        root.deleteFromDetail(); return true;
      case Qt.Key_Backspace:
        // Backspace is a reading-position key inside the selectable text
        // blocks, so deleting from here needs the explicit modifier.
        if (event.modifiers & Qt.ControlModifier) {
          if (event.isAutoRepeat) return true;
          root.deleteFromDetail();
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
      maxClips: root.maxClips,
      ignoreConfidentialCopies: root.ignoreConfidentialCopies,
      closePanelAfterAction: root.closePanelAfterAction,
      pasteSelectedClipImmediately: root.pasteSelectedClipImmediately
    });
    var dir = "\"" + root.settingsDir + "\"";
    var file = "\"" + root.settingsPath + "\"";
    // The write is handed to clipbasket-safefile rather than done with a shell
    // redirection. `mkdir`, `mktemp` and `mv` all act on pathnames, and the
    // `[ -L ]` guard in front of them was a check-to-use window: between the
    // test and the rename, a process running as this user can replace the
    // directory with a symlink and the settings land somewhere else. The
    // helper opens every component with O_NOFOLLOW, verifies the descriptor,
    // and renames relative to it, so there is no pathname left to re-point.
    //
    // jq still does the merging, exactly as before -- only where its output
    // lands has changed, and the payload above is untouched.
    root.runAction(
      root.shq(root.safefilePath) + " ensure-dir " + dir + " --mode 755 && "
      + "{ jq -e . " + file + " 2>/dev/null || printf '{}'; } "
      + "| jq --argjson patch " + root.shq(payload) + " '. * $patch' "
      + "| " + root.shq(root.safefilePath) + " write " + dir + " settings.json --mode 600",
      false);
  }

  // pasteSelectedClipImmediately requires closePanelAfterAction: pasting into
  // the focused window while the panel still holds focus pastes into the panel.
  // It also requires wtype, which is what actually performs the keystroke --
  // without it the setting can only ever describe something that will not
  // happen, so it is turned off rather than left on and silently inert.
  function normalizeSettings() {
    if (root.pasteSelectedClipImmediately
        && (!root.closePanelAfterAction || !root.wtypeAvailable)) {
      root.pasteSelectedClipImmediately = false;
    }
  }

  // Wayland has no system-wide synthetic-input API, so auto-paste is only as
  // real as wtype, and opening a link or a file is only as real as xdg-open.
  // Probed rather than assumed: a setting has to be able to say "unavailable",
  // which is a different statement from "off", and an action that cannot work
  // should not be offered at all. One process for both -- at ~3ms a fork this
  // is on the panel-open path.
  Process {
    id: toolProbe
    command: ["sh", "-c",
      "command -v wtype    >/dev/null 2>&1 && printf 1 || printf 0; "
      + "command -v xdg-open >/dev/null 2>&1 && printf 1 || printf 0"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var flags = String(text).trim();
        root.wtypeAvailable = flags.charAt(0) === "1";
        root.xdgOpenAvailable = flags.charAt(1) === "1";
        root.normalizeSettings();
      }
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
          if ("globalShortcut" in s) root.globalShortcut = String(s.globalShortcut || "");
          // Clamped on the way in too, so a hand-edited file out of range is
          // corrected rather than carried around.
          if ("maxClips" in s) root.maxClips = Math.max(50, Math.min(100000, Math.round(root.num(s.maxClips, root.maxClips))));
          if ("ignoreConfidentialCopies" in s) root.ignoreConfidentialCopies = s.ignoreConfidentialCopies === true;
          if ("closePanelAfterAction" in s) root.closePanelAfterAction = s.closePanelAfterAction === true;
          if ("pasteSelectedClipImmediately" in s) root.pasteSelectedClipImmediately = s.pasteSelectedClipImmediately === true;
          root.normalizeSettings();
        } catch (e) {}
      }
    }
  }

  function probeDefaultShortcut() {
    if (!defaultStateProbe.running) defaultStateProbe.running = true;
  }

  // Both directions go through the CLI: it backs bindings.lua up, writes only
  // between its own markers, and `restore-default` re-enables Omarchy's
  // clipboard only if `make-default` was what disabled it. Reproducing any of
  // that here would be a second, worse implementation of it.
  function setDefaultShortcut(want) {
    if (root.shortcutBusy) return;
    root.shortcutBusy = true;
    shortcutProc.command = ["sh", "-c",
      root.shq(root.cliPath) + (want ? " make-default" : " restore-default")
      + " --no-reload >/dev/null 2>&1"
      + " && { hyprctl reload >/dev/null 2>&1 || true; }"];
    shortcutProc.running = true;
  }

  Process {
    id: defaultStateProbe
    command: ["sh", "-c", "[ -f \"" + root.defaultStatePath + "\" ] && printf 1 || printf 0"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.isDefaultShortcut = String(text).trim() === "1"
    }
  }

  Process {
    id: shortcutProc
    running: false
    onExited: function (exitCode) {
      root.shortcutBusy = false;
      // Re-read rather than assume: the toggle springs back on its own if the
      // CLI refused (no bindings.lua, no hyprctl, nothing to restore).
      root.probeDefaultShortcut();
      settingsProbe.running = true;
      if (exitCode !== 0) root.showNotice("Couldn't change the shortcut. Run clipbasket-omarchy doctor.");
    }
  }

  // ------------------------------------------------------------ empty states

  readonly property string emptyTitle: {
    if (root.warning.length > 0) return root.warning;
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
    if (root.warning.length > 0) return "clipbasket-db could not be run, or the database could not be opened. Run clipbasket-omarchy doctor.";
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
  // `checked` is a one-way binding onto the state that owns it, and the
  // control never assigns to it. Flipping it here would overwrite the binding
  // -- permanently, since a QML binding is destroyed by an assignment -- and
  // the switch would then be unable to reflect a change it did not make: a
  // rejected write, a settings file edited in a terminal, a value clamped on
  // the way in. The handler receives what was asked for and the owner decides.
  component Toggle: Rectangle {
    id: sw
    property bool checked: false
    property bool interactive: true
    signal toggled(bool next)
    width: Style.space(38)
    height: Style.space(20)
    radius: height / 2
    color: checked ? root.barForeground : root.fg(0.14)
    Behavior on color { ColorAnimation { duration: 120 } }

    Rectangle {
      width: parent.height - 4
      height: width
      radius: width / 2
      y: 2
      x: sw.checked ? parent.width - width - 2 : 2
      color: sw.checked ? Color.background : root.fg(0.75)
      Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }

    opacity: sw.interactive ? 1 : 0.4

    MouseArea {
      anchors.fill: parent
      enabled: sw.interactive
      onClicked: sw.toggled(!sw.checked)
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

  // ---- Labelled, selectable field card used by the detail view. Hides itself
  // when there is nothing to say, so each kind's grid falls out of one list.
  component DetailField: Item {
    id: fld
    property string label: ""
    property string value: ""
    property bool mono: false
    visible: fld.value.length > 0
    width: parent ? parent.width - Style.space(28) : 0
    x: Style.space(14)
    height: fld.visible ? fldCol.implicitHeight + Style.space(14) : 0

    Rectangle {
      anchors.fill: parent
      radius: 8
      color: root.fg(0.05)
      border.width: 1
      border.color: root.fg(0.10)
    }

    Column {
      id: fldCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        text: fld.label.toUpperCase()
        color: root.barForeground
        opacity: 0.4
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // TextEdit rather than Text: the whole point of this view is being able
      // to read *and* take the content, so every value is selectable.
      TextEdit {
        width: parent.width
        text: fld.value
        readOnly: true
        selectByMouse: true
        wrapMode: Text.Wrap
        color: root.barForeground
        font.family: fld.mono ? root.monoFamily : Style.font.family
        font.pixelSize: Style.font.body
      }
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
      color: actArea.containsMouse ? root.fg(0.10) : "transparent"
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
    contentHeight: panel.fittedContentHeight(Math.min(Style.space(600),
      root.settingsOpen ? settingsColumn.implicitHeight
      : root.detailOpen ? detailView.desiredHeight
      : clipView.desiredHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.menuClipId >= 0) root.closeMenu();
        else if (root.detailOpen) root.closeDetail();
        else if (root.settingsOpen) root.settingsOpen = false;
        else root.close();
      }
      onTabRequested: function (direction) { root.switchPanel(direction); }

      // Navigation for the case where the key catcher, rather than the search
      // field, owns active focus. One handler rather than a signal per key:
      // PageUp, PageDown, Home, End and Backspace have no dedicated attached
      // signal, so with the per-key form they only ever worked while the search
      // field held focus -- which is not where focus is once the settings page
      // or the detail view is open.
      //
      // handleNavKey never accepts Escape, Tab or Backtab, so PanelKeyCatcher's
      // own close and panel-switch handling still sees them.
      Keys.onPressed: function (event) { event.accepted = root.handleNavKey(event); }

      // ================= CLIP LIST =================
      Item {
        id: clipView
        anchors.fill: parent
        visible: !root.settingsOpen && !root.detailOpen

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
            color: root.fg(0.05)
            border.width: 1
            border.color: root.fg(searchInput.activeFocus ? 0.22 : 0.10)

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
                color: selected ? root.barForeground : root.fg(0.05)
                border.width: 1
                border.color: root.fg(selected ? 0 : 0.12)

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
                color: root.fg(0.08)
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
            readonly property bool rowHasHtml: model.hasHtml
            readonly property var visual: root.visualSize(model.imageWidth, model.imageHeight)
            readonly property bool hasVariants: rowKind === "files"
              || root.supportsMarkdown({ kind: rowKind, payload: rowPayload, hasHtml: rowHasHtml })

            width: ListView.view ? ListView.view.width : 0
            // Deliberately constant: ListView estimates contentHeight from the
            // delegates it has built, and the panel's own height is derived
            // from contentHeight. A varying row height turns that into a
            // feedback loop that visibly jitters the popup.
            height: Style.space(62)
            color: selected ? root.fg(0.07) : "transparent"

            // Row body opens the detail view, as the desktop app's row does.
            // Copying stays an explicit act: the Copy button in the rail, or
            // Ctrl+Enter from the keyboard.
            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              onEntered: clipList.currentIndex = clipRow.rowIndex
              onClicked: root.openDetail(clipRow.rowIndex)
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
                color: root.fg(0.06)
                border.width: 1
                border.color: root.fg(0.10)
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
                // Clip content is data, never markup: a copied "<b>" or "<h2>" must not
                // render as rich text.
                textFormat: Text.PlainText
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
                // Clip content is data, never markup: a copied "<b>" or "<h2>" must not
                // render as rich text.
                textFormat: Text.PlainText
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
                  visible: clipRow.selected || root.menuClipId === clipRow.clipId

                  // Explicit "open the detail view" affordance. The row body
                  // does the same thing, but a chevron is the only visible
                  // sign that a row leads somewhere.
                  RowAction {
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: root.glyphForward
                    onActivated: root.openDetail(clipRow.rowIndex)
                  }

                  RowAction {
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: root.glyphTrash
                    tint: clipRow.armed ? root.dangerTint : root.barForeground
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
                          if (root.menuClipId === clipRow.clipId) root.closeMenu();
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

      // ---- Image lightbox, drawn at panel level so it gets the whole surface
      // instead of the detail body's scroll viewport. It is a mode of the
      // detail view, not a view of its own: dismissing it returns to the clip.
      Rectangle {
        visible: root.lightboxOpen && root.detailHasImage
        z: 60
        anchors.fill: parent
        color: Color.background

        MouseArea {
          anchors.fill: parent
          onClicked: root.lightboxOpen = false
        }

        Image {
          anchors.fill: parent
          anchors.margins: Style.space(14)
          anchors.bottomMargin: Style.space(30)
          // Only loaded while it is up: this decodes at four times the
          // preview's resolution and there is no reason to hold it otherwise.
          source: root.lightboxOpen ? root.fileUrl(root.detailImagePath) : ""
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: false
          // Bounded: a 8000px screenshot decoded at full size to fill a 400px
          // panel is most of a gigabyte for no visible gain.
          sourceSize.width: 2048
          sourceSize.height: 2048
          smooth: true
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(9)
          text: root.detailDimensions.length > 0
            ? root.detailDimensions + "  ·  Esc or click to close"
            : "Esc or click to close"
          color: root.barForeground
          opacity: 0.45
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // ---- Copy-variant menu, drawn at panel level so the ListView's clip
      // rectangle cannot cut it off.
      MouseArea {
        anchors.fill: parent
        visible: root.menuClipId >= 0
        onClicked: root.closeMenu()
        z: 50
      }

      Rectangle {
        visible: root.menuClipId >= 0
        z: 51
        x: Math.max(Style.space(8), Math.min(root.menuX - width + Style.space(24), keyCatcher.width - width - Style.space(8)))
        y: Math.min(root.menuY, keyCatcher.height - height - Style.space(8))
        width: Math.max(Style.space(150), menuColumn.implicitWidth + Style.space(16))
        height: menuColumn.implicitHeight + Style.space(8)
        radius: 8
        color: Color.background
        border.width: 1
        border.color: root.fg(0.16)

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
              color: itemArea.containsMouse ? root.fg(0.10) : "transparent"

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

      // ================= CLIP DETAIL =================
      // The third view, in the same slot as the list and settings. Header,
      // body and footer are anchored the way clipView does it, so only the
      // middle scrolls: the action rail can never end up out of reach, and the
      // body clips instead of painting past the panel's rounded background.
      Item {
        id: detailView
        anchors.fill: parent
        visible: root.detailOpen

        readonly property real maxBodyHeight: Style.space(440)
        readonly property real minBodyHeight: Style.space(120)
        readonly property real desiredHeight: detailHeader.implicitHeight + detailFooter.implicitHeight
          + Math.max(detailView.minBodyHeight,
                     Math.min(detailView.maxBodyHeight, detailContent.implicitHeight))

        // Focused by openDetail(). Keys land here first and route through the
        // same handleNavKey() the list and the search field use; anything left
        // unaccepted (Escape from inside a text block, Tab) keeps bubbling to
        // PanelKeyCatcher.
        Keys.onPressed: function (event) {
          if (root.handleNavKey(event)) event.accepted = true;
        }

        // ---- Header: back chevron, "Clip details", kind pill
        Column {
          id: detailHeader
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(6)

          Item { width: 1; height: Style.space(12) }

          Item {
            width: parent.width - Style.space(28)
            x: Style.space(14)
            height: Style.space(24)

            Item {
              id: detailBack
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: backRow.implicitWidth
              height: parent.height

              Row {
                id: backRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.glyphBack
                  color: root.barForeground
                  opacity: detailBackHover.containsMouse ? 0.9 : 0.5
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Clip details"
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              MouseArea {
                id: detailBackHover
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.closeDetail()
              }
            }

            Rectangle {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.detailKindLabel.length > 0
              width: kindLabel.implicitWidth + Style.space(14)
              height: Style.space(18)
              radius: 4
              color: root.fg(0.06)
              border.width: 1
              border.color: root.fg(0.12)

              Text {
                id: kindLabel
                anchors.centerIn: parent
                text: root.detailKindLabel.toUpperCase()
                color: root.barForeground
                opacity: 0.6
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            x: Style.space(14)
            width: parent.width - Style.space(28)
            visible: text.length > 0
            text: root.detailTitle
            // Clip content is data, never markup: a copied "<b>" or "<h2>" must not
            // render as rich text.
            textFormat: Text.PlainText
            color: root.barForeground
            opacity: 0.55
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Item { width: 1; height: Style.space(4) }
        }

        // ---- Body. Same containment rule as the settings page: a capped
        // panel height means the content must clip and scroll, never overflow.
        Flickable {
          id: detailBody
          anchors.top: detailHeader.bottom
          anchors.bottom: detailFooter.top
          anchors.left: parent.left
          anchors.right: parent.right
          clip: true
          contentWidth: width
          contentHeight: detailContent.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: detailContent
            width: parent.width
            spacing: Style.space(6)

            Text {
              x: Style.space(14)
              width: parent.width - Style.space(28)
              visible: root.detailLoading || root.detailError.length > 0
              text: root.detailError.length > 0 ? root.detailError : "Loading clip…"
              color: root.detailError.length > 0 ? root.dangerTint : root.barForeground
              opacity: root.detailError.length > 0 ? 0.85 : 0.5
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            // ---- image: the picture itself, at a size worth calling a preview.
            // The slot's height follows the clip's own aspect ratio so a wide
            // screenshot does not reserve a square of empty panel.
            Item {
              x: Style.space(14)
              width: parent.width - Style.space(28)
              visible: root.detailKind === "image" && root.detailImagePath.length > 0
              height: visible
                ? (root.detailImageW > 0 && root.detailImageH > 0
                    ? Math.min(Style.space(240),
                               Math.round(root.detailImageH * Math.min(1, width / root.detailImageW)))
                    : Style.space(240))
                : 0

              Rectangle {
                anchors.fill: parent
                radius: 8
                color: root.fg(0.05)
                border.width: 1
                border.color: root.fg(0.10)
                clip: true

                Image {
                  anchors.fill: parent
                  anchors.margins: Style.space(4)
                  source: root.fileUrl(root.detailImagePath)
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  cache: false
                  sourceSize.width: 1024
                  sourceSize.height: 1024
                  smooth: true
                }

                MouseArea {
                  id: previewArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleLightbox()
                }

                // The picture is not obviously a button, so say so on hover.
                Rectangle {
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.margins: Style.space(6)
                  visible: previewArea.containsMouse
                  width: expandHint.implicitWidth + Style.space(14)
                  height: Style.space(20)
                  radius: height / 2
                  color: Color.background
                  opacity: 0.85

                  Text {
                    id: expandHint
                    anchors.centerIn: parent
                    text: root.glyphExpand + "  Space"
                    color: root.barForeground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // ---- text: the whole thing, monospaced, selectable, scrolled by
            // the Flickable above rather than truncated the way the list is.
            DetailField {
              label: "Text"
              mono: true
              value: root.detailKind === "text" ? root.detailText : ""
            }

            // ---- url
            DetailField {
              label: "URL"
              mono: true
              value: root.detailKind === "url" ? root.detailText : ""
            }
            DetailField {
              label: "Title"
              value: root.detailKind === "url" && root.detailRow ? root.detailRow.urlTitle : ""
            }
            DetailField {
              label: "Domain"
              value: root.detailKind === "url" && root.detailRow ? root.detailRow.urlDomain : ""
            }

            // ---- files: one row per entry, each carrying its own actions.
            // The whole-list copy variants stay where they were, on the row's
            // copy menu; these are the per-item ones, which is the only place
            // "open this file" can sensibly live.
            Column {
              x: Style.space(14)
              width: parent.width - Style.space(28)
              spacing: Style.space(4)
              visible: root.detailFileRows.length > 0

              Text {
                text: root.detailFileRows.length === 1 ? "FILE" : "FILES"
                color: root.barForeground
                opacity: 0.35
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.detailFileRows

                delegate: Rectangle {
                  id: fileRow
                  required property var modelData

                  width: parent ? parent.width : 0
                  height: Style.space(42)
                  radius: 6
                  color: fileHover.hovered ? root.fg(0.08) : root.fg(0.04)

                  // Passive, so it keeps reporting while the pointer is over
                  // one of the action buttons -- a child MouseArea takes the
                  // hover grab, and a rail gated on that would vanish exactly
                  // when it was being aimed at.
                  HoverHandler { id: fileHover }

                  MouseArea {
                    id: fileArea
                    anchors.fill: parent
                    // The row itself opens the item, like the clip rows do.
                    onClicked: root.openFilePath(fileRow.modelData.path, false)
                    enabled: root.xdgOpenAvailable
                  }

                  Text {
                    id: fileGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    text: fileRow.modelData.isDirectory ? root.glyphFolder : root.glyphFile
                    // Clip content is data, never markup: a copied "<b>" or "<h2>" must not
                    // render as rich text.
                    textFormat: Text.PlainText
                    color: root.barForeground
                    opacity: 0.55
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }

                  Column {
                    anchors.left: fileGlyph.right
                    anchors.leftMargin: Style.space(9)
                    anchors.right: fileActions.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    Row {
                      width: parent.width
                      spacing: Style.space(6)

                      Text {
                        text: fileRow.modelData.name
                        // Clip content is data, never markup: a copied "<b>" or "<h2>" must not
                        // render as rich text.
                        textFormat: Text.PlainText
                        color: root.barForeground
                        elide: Text.ElideMiddle
                        width: Math.min(implicitWidth, parent.width - (dirBadge.visible ? dirBadge.width + Style.space(6) : 0))
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                      }

                      Rectangle {
                        id: dirBadge
                        anchors.verticalCenter: parent.verticalCenter
                        visible: fileRow.modelData.isDirectory
                        width: dirBadgeText.implicitWidth + Style.space(10)
                        height: Style.space(15)
                        radius: 3
                        color: root.fg(0.10)

                        Text {
                          id: dirBadgeText
                          anchors.centerIn: parent
                          text: "FOLDER"
                          color: root.barForeground
                          opacity: 0.6
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }

                    Text {
                      width: parent.width
                      text: fileRow.modelData.parent
                      // Clip content is data, never markup: a copied "<b>" or "<h2>" must not
                      // render as rich text.
                      textFormat: Text.PlainText
                      color: root.barForeground
                      opacity: 0.38
                      elide: Text.ElideMiddle
                      font.family: root.monoFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Row {
                    id: fileActions
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)
                    visible: fileHover.hovered

                    RowAction {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: root.xdgOpenAvailable
                      glyph: root.glyphOpen
                      tip: "Open"
                      onActivated: root.openFilePath(fileRow.modelData.path, false)
                    }

                    RowAction {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: root.xdgOpenAvailable
                      glyph: root.glyphReveal
                      tip: "Reveal in folder"
                      onActivated: root.openFilePath(fileRow.modelData.path, true)
                    }

                    RowAction {
                      anchors.verticalCenter: parent.verticalCenter
                      glyph: root.glyphFiles
                      tip: "Copy path"
                      onActivated: root.copyOneFilePath(fileRow.modelData.path)
                    }
                  }
                }
              }
            }

            DetailField { label: "Dimensions"; value: root.detailDimensions }
            DetailField { label: "Type"; value: root.detailMime }

            // ---- always present
            DetailField { label: "Source app"; value: root.detailSourceApp }
            DetailField { label: "Captured"; value: root.detailWhen }
            DetailField { label: "Size"; value: root.detailSize }
            DetailField { label: "State"; value: root.detailStateLabel }

            Item { width: 1; height: Style.space(8) }
          }
        }

        // ---- Footer: the same actions the row rail carries, plus the notice
        // slot, so the two-step delete confirmation is legible from here too.
        Column {
          id: detailFooter
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: 0

          Item {
            width: parent.width - Style.space(28)
            x: Style.space(14)
            height: Style.space(18)
            visible: root.notice.length > 0

            Text {
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              text: root.notice
              color: root.barForeground
              opacity: 0.7
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Item {
            width: parent.width - Style.space(28)
            x: Style.space(14)
            height: Style.space(34)

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              RowAction {
                anchors.verticalCenter: parent.verticalCenter
                glyph: root.glyphTrash
                tint: root.armedDeleteId === root.detailClipId ? root.dangerTint : root.barForeground
                restOpacity: root.armedDeleteId === root.detailClipId ? 1.0 : 0.45
                onActivated: root.deleteFromDetail()
              }

              RowAction {
                anchors.verticalCenter: parent.verticalCenter
                glyph: root.glyphPin
                restOpacity: root.detailPinned ? 0.9 : 0.45
                onActivated: root.togglePinned(root.detailIndex)
              }

              RowAction {
                anchors.verticalCenter: parent.verticalCenter
                glyph: root.detailSaved ? root.glyphSaved : root.glyphUnsaved
                restOpacity: root.detailSaved ? 0.9 : 0.45
                onActivated: root.toggleSaved(root.detailIndex)
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.canOpenUrl(root.detailRow)
                width: openLabel.implicitWidth + Style.space(20)
                height: Style.space(24)
                radius: height / 2
                color: openArea.containsMouse ? root.fg(0.10) : "transparent"
                border.width: 1
                border.color: root.fg(0.16)

                Text {
                  id: openLabel
                  anchors.centerIn: parent
                  text: root.glyphOpen + "  Open"
                  color: root.barForeground
                  opacity: 0.85
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: openArea
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.openUrl(root.detailIndex)
                }
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.detailHasMarkdown
                width: mdLabel.implicitWidth + Style.space(20)
                height: Style.space(24)
                radius: height / 2
                color: mdArea.containsMouse ? root.fg(0.10) : "transparent"
                border.width: 1
                border.color: root.fg(0.16)

                Text {
                  id: mdLabel
                  anchors.centerIn: parent
                  text: "Copy as Markdown"
                  color: root.barForeground
                  opacity: 0.85
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: mdArea
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.copyMarkdown(root.detailIndex)
                }
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: detailCopyLabel.implicitWidth + Style.space(22)
                height: Style.space(24)
                radius: height / 2
                color: root.barForeground

                Text {
                  id: detailCopyLabel
                  anchors.centerIn: parent
                  text: root.detailKind === "image" ? "Copy image" : "Copy"
                  color: Color.background
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.copyClip(root.detailIndex)
                }
              }
            }
          }

          Item { width: 1; height: Style.space(8) }
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
          title: "Global shortcut"
          subtitle: "Owned by the compositor on Wayland — this mirrors the managed block in bindings.lua"
          Rectangle {
            width: shortcutText.implicitWidth + Style.space(16)
            height: Style.space(22)
            radius: 4
            color: root.fg(0.06)
            border.width: 1
            border.color: root.fg(0.12)
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

        SettingRow {
          title: "Use Clipbasket for Super+Ctrl+V"
          subtitle: root.isDefaultShortcut
            ? "Clipbasket owns the key. Turning this off gives it back to Omarchy's clipboard, exactly as it was."
            : "Omarchy's clipboard owns the key. Turning this on hands it to Clipbasket and steps Omarchy's overlay aside."
          Toggle {
            checked: root.isDefaultShortcut
            interactive: !root.shortcutBusy
            onToggled: function (next) { root.setDefaultShortcut(next); }
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
            color: root.fg(0.06)
            border.width: 1
            border.color: root.fg(maxInput.activeFocus ? 0.25 : 0.12)
            TextInput {
              id: maxInput
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: String(root.maxClips)
              color: root.barForeground
              horizontalAlignment: Text.AlignRight
              // Digits only, but no range validator: IntValidator rejects an
              // out-of-range value instead of clamping it, so typing 5 left the
              // field showing 5 while the model kept 1000. The schema promises
              // clamping, so the clamp happens on commit and the field is told
              // what it actually became.
              validator: RegularExpressionValidator { regularExpression: /[0-9]{0,6}/ }
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              selectByMouse: true
              onEditingFinished: {
                var n = parseInt(maxInput.text, 10);
                if (!isFinite(n)) n = root.maxClips;
                root.maxClips = Math.max(50, Math.min(100000, n));
                maxInput.text = String(root.maxClips);
                root.persist();
              }
              // The `text:` binding above dies on the first keystroke, so the
              // field cannot follow root.maxClips on its own afterwards.
              Connections {
                target: root
                function onMaxClipsChanged() { maxInput.text = String(root.maxClips); }
              }
            }
          }
        }

        SettingRow {
          title: "Ignore confidential copies"
          subtitle: "Skip x-kde-passwordManagerHint and CLIPBOARD_STATE=sensitive"
          Toggle {
            checked: root.ignoreConfidentialCopies
            onToggled: function (next) { root.ignoreConfidentialCopies = next; root.persist(); }
          }
        }

        SectionHeader { text: "BEHAVIOR" }

        SettingRow {
          title: "Close popup after action"
          subtitle: "Hide the popup after selecting or copying a clip"
          Toggle {
            checked: root.closePanelAfterAction
            onToggled: function (next) {
              root.closePanelAfterAction = next;
              root.normalizeSettings();
              root.persist();
            }
          }
        }

        SettingRow {
          title: "Paste immediately"
          subtitle: !root.wtypeAvailable
            ? "Install wtype to enable automatic paste"
            : root.closePanelAfterAction
              ? "After picking a clip, paste it into the focused window"
              : "Auto-paste requires closing the popup first."
          Toggle {
            checked: root.pasteSelectedClipImmediately
            interactive: root.closePanelAfterAction && root.wtypeAvailable
            onToggled: function (next) {
              root.pasteSelectedClipImmediately = next;
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
            color: root.fg(0.06)
            Text {
              id: verText
              anchors.centerIn: parent
              text: root.pluginVersion
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
