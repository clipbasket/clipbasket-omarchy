# Data

Everything Clipbasket stores lives in one SQLite database and two asset
directories, and `bin/clipbasket-db` is the only thing that touches them. The
QML panel, the capture watchers and the CLI all go through its subcommands, so
this file is the contract between them.

```
$XDG_STATE_HOME/clipbasket/          (default ~/.local/state/clipbasket)
├── clips.db          the history
├── images/           full-size clipboard images, content-addressed
├── thumbs/           their thumbnails
├── suppress          one-shot self-capture token
├── .fts              1 if this sqlite3 has FTS5, 0 if search falls back to LIKE
└── .schema-vN        fast-path stamp: the schema is known to be at version N
```

Override the directory with `CLIPBASKET_STATE_DIR`, or the database file alone
with `CLIPBASKET_DB`.

---

## The `clips` table

| column | type | notes |
| --- | --- | --- |
| `id` | INTEGER PK | autoincrement; stable for the life of the row |
| `kind` | TEXT | `text`, `url`, `image` or `files` |
| `preview` | TEXT | one line, at most 180 characters, derived on insert |
| `text` | TEXT | the plain-text payload — what a normal paste produces |
| `html` | TEXT | the `text/html` clipboard flavour, when the source offered one |
| `hash` | TEXT UNIQUE | the dedupe key |
| `source_app` | TEXT | focused window's class at the moment of the copy |
| `created_at` | INTEGER | unix seconds; also the sort key |
| `pinned` | INTEGER | 0/1 — floats to the top, exempt from pruning |
| `saved` | INTEGER | 0/1 — exempt from pruning and from `clear` |
| `image_path` | TEXT | absolute path under `images/` |
| `thumb_path` | TEXT | absolute path under `thumbs/`, or the original |
| `image_width` / `image_height` | INTEGER | pixels, when they could be read |
| `url_domain` | TEXT | pretty domain for a `url` clip |
| `url_title` | TEXT | reserved; nothing writes it yet |
| `file_count` | INTEGER | number of entries in `files_json` |
| `files_json` | TEXT | JSON array of `{path, name, extension, is_directory}` |
| `mime` | TEXT | the offer's MIME type, for images and file lists |
| `size_bytes` | INTEGER | payload size for images |
| `searchable` | TEXT | the concatenation search runs over |

Search uses an FTS5 external-content table (`clips_fts`) kept in sync by three
triggers. FTS5 is not compiled into every sqlite3 build, so it is created
opportunistically; when it is missing, search degrades to `LIKE` over
`searchable` and `clipbasket-db info` reports `"fts5": false`.

### Schema versions

`SCHEMA_VERSION` in `bin/clipbasket-db` is the current version, and it is
written to `PRAGMA user_version` on the database file. `clipbasket-db info`
reports it.

| version | change |
| --- | --- |
| 1 | initial schema |
| 2 | added `clips.html` |

Migrations are **additive and in place**. A user's history is already on disk,
so no step may drop or rebuild the `clips` table. The sequence on every run is:

1. **Fast path.** If `clips.db` and `$STATE_DIR/.schema-vN` both exist, the
   schema is known to be current and nothing is checked. This costs no forks,
   which matters because `list` is on the panel's keystroke path.
2. Otherwise `migrate_schema` reads `PRAGMA user_version` from the *existing*
   file — before anything stamps a new one — and applies each step below that
   version. It does nothing at all if the file is new or has no `clips` table,
   because `base_schema` is about to create it complete.
3. Each step goes through `add_column`, which checks `pragma_table_info` rather
   than trusting `user_version`. A database that was restored from a backup,
   hand-edited, or half-migrated by an interrupted run converges anyway, and
   re-running a migration is a no-op rather than a duplicate-column error.
4. `base_schema` runs (`CREATE TABLE IF NOT EXISTS`, indexes, and
   `PRAGMA user_version=N`), then the FTS table and triggers are recreated and
   the index rebuilt.
5. Old `.schema-v*` stamps are removed and the new one is written.

An upgraded binary therefore takes the slow path exactly once. Older binaries
keep working against a newer database: an unknown column is simply not selected.

`clipbasket-db selftest` builds a real v1 database with rows, pinned and saved
flags, and an id sequence, migrates it, and asserts all of them survive.

---

## JSON contract

Every subcommand prints exactly one JSON document on stdout and never prompts.
Diagnostics go to stderr. Errors are `{"ok":false,"error":"…"}` with a non-zero
exit status.

### `list --limit N [--offset N] [--filter F] [--query STR]`

A JSON array of clip objects:

```json
{
  "id": 12, "kind": "text", "preview": "…", "text": "…",
  "text_truncated": false, "hash": "…", "source_app": "firefox",
  "created_at": 1787433886, "pinned": false, "saved": false,
  "image_path": null, "thumb_path": null,
  "image_width": null, "image_height": null,
  "url_domain": null, "url_title": null,
  "file_count": 0, "files": null,
  "mime": null, "size_bytes": null,
  "has_html": true
}
```

`text` is truncated to 2000 characters in a listing and `text_truncated` says
whether it was. **`list` never returns `html`** — one copied web page is larger
than a whole page of clips, and every listing would carry it. It returns
`has_html` instead, so the panel can decide whether to offer "Copy as Markdown"
without paying for the payload.

### `get <id>`

The same object with the full `text`, `text_truncated` always `false`, and one
extra field:

```json
{ "…": "…", "has_html": true, "html": "<h1>Wikipedia</h1>…" }
```

`null` for an id that does not exist.

### `markdown <id> [--base-url URL]`

```json
{ "markdown": "# Wikipedia\n\nLa **enciclopedia** [libre](/wiki/Libre)\n" }
```

Errors, in the CLI's usual shape:

| condition | output |
| --- | --- |
| clip has no HTML | `{"ok":false,"error":"clip 12 has no HTML flavour to convert"}` |
| no such clip | `{"ok":false,"error":"no clip with id 12"}` |
| id is not numeric | `{"ok":false,"error":"expected a numeric clip id, got: abc"}` |
| converter missing | `{"ok":false,"error":"clipbasket-html2md is not executable at …"}` |

Callers should gate on `has_html` rather than calling `markdown` speculatively.

When `--base-url` is not given and the clip is a `url` clip whose text is a
single-line URL, that URL becomes the base, so the relative `href`s a real page
is full of come out absolute. The Markdown comes back through the database
(`json_object` over `readfile`) rather than through a hand-rolled encoder, so
quotes, newlines and control characters are escaped by SQLite.

### `insert` (JSON clip on stdin)

`{"id":12,"deduped":false}`. `deduped` is true when the same hash was recorded
less than `CLIPBASKET_DEDUPE_WINDOW` seconds ago, in which case nothing was
written. Recognised input fields: `kind`, `text`, `html`, `preview`, `hash`,
`source_app`, `created_at`, `image_path`, `thumb_path`, `image_width`,
`image_height`, `url_domain`, `url_title`, `files`, `file_count`, `mime`,
`size_bytes`. Everything else is ignored, and an unknown `kind` becomes `text`.

On a hash conflict outside the dedupe window the row is updated. `html` is
overwritten, not coalesced: the dedupe hash covers the plain text only, so a
re-copy of the same words from a source that offers no markup must clear the
stale flavour rather than keep it attached to different provenance.

`insert` scrubs invalid UTF-8 out of the payload before any of it reaches
SQLite (`iconv -c -f UTF-8 -t UTF-8`, or an `LC_ALL=C` byte filter when iconv is
missing). SQLite stores whatever bytes it is handed and `json_object()` hands
them straight back, so one clip copied out of a latin-1 terminal would otherwise
make `JSON.parse` reject the entire page in the panel.

When no `hash` is supplied the fallback is `kind || char(31) || text`, with any
newline or carriage return in the text replaced by `char(31)` as well. It is
deliberately single-line: `copy` writes the hash to the suppression file and
the watcher reads it back, and a token truncated at a newline silently disarms
self-capture suppression.

### Search

A search term is split on non-alphanumerics and every token becomes a *quoted*
prefix term: `a AND b` becomes `"a"* AND "and"* AND "b"*`. The quoting is not
optional — fts5 reads a bare `AND`, `OR`, `NOT` or `NEAR` as an operator, so an
unquoted token turned `NOT NULL` into a syntax error, which fell back to the
LIKE path where the already-tokenised term matched nothing at all. When a term
yields no tokens (punctuation only) the LIKE path is used directly.

The FTS5 probe is cached in `$STATE_DIR/.fts`. A cached *yes* is final; a
cached *no* is re-probed as soon as the `sqlite3` binary is newer than the
cache file, and `info` always re-probes, so an upgraded sqlite3 turns search
back on without the user deleting state by hand.

### File URIs

`copy` on a `files` clip emits one `file://` URI per line, each path
percent-encoded to the RFC 3986 unreserved set (`A-Z a-z 0-9 - . _ ~`) with `/`
left alone as the path separator. `/tmp/a b.txt` goes out as
`file:///tmp/a%20b.txt` and `/tmp/100%.txt` as `file:///tmp/100%25.txt`.

`clipbasket-capture` decodes the same way: a `%` followed by exactly two hex
digits is one byte, and any other `%` is the literal character. That pairing is
what makes a re-copied file list hash back to the clip it came from — an
unencoded space or `%` reached the receiving app as a different path, and the
watcher then recorded the echo as a brand new clip.

Internally the decoded list is NUL-delimited, never newline-delimited: `%0A` is
a legal escape and decodes to a newline inside a file name, which a
line-delimited list splits into two bogus paths and miscounts. The same applies
to `delete`'s doomed-asset list, which comes out of SQLite hex-encoded for the
same reason.

### Others

`pin`/`save` → `{"ok":true}` · `delete` → `{"ok":true}` ·
`clear` → `{"ok":true,"deleted":N}` · `count` → `{"total":N,"filtered":N}` ·
`prune --max N` → `{"deleted":N}` · `copy`/`touch`/`suppress` → `{"ok":true}` ·
`info` → app name, paths, `schema_version`, `fts5`, clip count, sqlite version.

---

## Capture

### `capture_files` status contract

`clipbasket-capture` runs two `wl-paste --watch` processes over the same
clipboard change, and only the offer's MIME list says which of them owns it.
`capture_files` reports which case it is in:

| status | meaning | caller |
| --- | --- | --- |
| `1` | not a local file list | fall through to the next kind |
| `0` | recorded, or deliberately skipped | this change is ours; stop |
| `2` | it *is* a file list and recording failed | this change is ours; stop |

Only `1` falls through. A failed insert used to be indistinguishable from "not
a file list", so the text watcher recorded the plain-text rendering of the same
paths as a second clip — with the one-shot suppression token already spent by
the file path that had just given up. Every capture path now consumes that
token immediately before its insert, once it knows it is the recorder.

When `wl-paste --list-types` returns nothing at all, the image watcher exits
without recording: both watchers are handed the same bytes on stdin, and with
no MIME list there is nothing that says those bytes are an image. The text
watcher still records them as text.

### Confidential offers

Password managers mark an offer with an extra MIME type rather than an env var
(`x-kde-passwordManagerHint`, and the `org.nspasteboard.*` markers on offers
bridged from macOS). Every marker is matched case-insensitively.

`CLIPBASKET_IGNORE_CONFIDENTIAL` defaults to `1`, which skips those offers. Set
it to `0` to record them anyway; the service passes the user's setting through.

### The pixel guard

Before any thumbnail is generated, the image's dimensions are read from the
header — `magick identify -ping -format '%w %h'` when ImageMagick is installed,
otherwise the PNG IHDR at bytes 16–23. An image over
`CLIPBASKET_MAX_IMAGE_DIMENSION` (16384, mirroring the desktop app's
`CLIPBOARD_IMAGE_MAX_DIMENSION`) on either side is not recorded. The byte cap
is not enough on its own: 64 MiB of PNG can still decode to a 100000×100000
bitmap, and the thumbnailer is the step that would decode it.

The image and its thumbnail are written under staging names and renamed into
`images/` and `thumbs/` only once `record` has succeeded, so a failed insert
cannot leave an asset that no row references and no cleanup would ever find.

---

## The HTML flavour

A Wayland clipboard offer is a list of MIME types, and a copy out of a browser
advertises several renderings of the same selection: `text/html`,
`text/plain;charset=utf-8`, `TEXT`, and so on. Before this, `clipbasket-capture`
read only the plain text, so copying a Wikipedia page stored the flattened
`WikipediaLa enciclopedia libre Buscar e…` and there was nothing left to
convert.

`clipbasket-capture` now also reads `text/html` when the offer advertises it and
stores it in `clips.html`. Three rules, matching `captured_text_like_clip()` in
the macOS/Windows app, where `html_content` rides alongside `text_content`:

* **HTML is a flavour, not a kind.** A clip that carries HTML is still `text`
  (or `url`). The classification priority is unchanged — files beat image beats
  text — and a copy that carries an image is still recorded by the image
  watcher, HTML or not.
* **The plain text stays the clip's `text`.** An ordinary paste must produce
  exactly what it produced before. Only an explicit "Copy as Markdown" reaches
  for `html`.
* **The dedupe hash covers the plain text only.** Two copies of the same words
  are one clip whether or not the second carried markup.

The HTML is normalised like the plain text (CRLF stripped, invalid UTF-8
dropped) and capped at `CLIPBASKET_MAX_HTML_BYTES` (8 MiB, the Tauri app's
`CLIPBOARD_HTML_MAX_BYTES`). Over the cap the HTML is dropped and the clip is
still recorded with its plain text.

---

## HTML → Markdown

`bin/clipbasket-html2md` reads HTML on stdin and writes GitHub-Flavored
Markdown on stdout. It is **Python 3, standard library only** — no pip install,
no new pacman dependency, because the product promise is "git clone and run"
and Omarchy already ships python3.

```
wl-paste --type text/html | clipbasket-html2md --base-url https://example.com/
clipbasket-html2md --selftest        # every supported element, ~55 cases
clipbasket-html2md --builtin         # ignore pandoc even when it is installed
```

If `pandoc` is on `PATH` it is used (`pandoc -f html -t gfm --wrap=none`), since
it is strictly better than anything that fits in one file. It is never required,
and it is never installed on the user's behalf; the built-in converter is what
the tests pin down, and it is what runs on a stock Omarchy box. Set
`CLIPBASKET_HTML2MD_PANDOC=0` to force the built-in path.

The output rules mirror the turndown + turndown-plugin-gfm configuration the
macOS/Windows app runs in its webview (`src/markdown/htmlToMarkdown.ts`): ATX
headings, `-` bullets, fenced code blocks, `*` for emphasis.

### Handled

| | |
| --- | --- |
| headings | `<h1>`–`<h6>` → `#`–`######` |
| emphasis | `<strong>`/`<b>` → `**`, `<em>`/`<i>`/`<cite>`/`<var>` → `*`, `<del>`/`<s>`/`<strike>` → `~~` |
| code | `<code>`/`<kbd>`/`<samp>` inline, with the backtick fence widened when the content contains backticks |
| code blocks | `<pre>` fenced, language taken from a `language-`/`lang-`/`highlight-source-` class |
| links | `[text](href "title")`; `javascript:` targets dropped; an `<a>` with no `href` keeps its text |
| images | `![alt](src "title")`, including an image inside a link |
| lists | `<ul>`, `<ol start=N>`, arbitrarily nested, multi-paragraph items |
| task lists | `<li><input type=checkbox>` → `- [ ]` / `- [x]` |
| tables | GFM, with `align`/`text-align` alignment, `|` escaped in cells, `<caption>` lifted to a paragraph above, and an empty header row synthesised for a headerless table |
| quotes | `<blockquote>`, nested |
| rules | `<hr>` → `---` |
| breaks | `<br>` → two trailing spaces |
| entities | decoded (`&amp;`, `&nbsp;`, `&#233;`, …) |
| relative URLs | resolved against `--base-url`, or a `<base href>` in the document |

`<script>`, `<style>`, `<head>`, `<title>`, `<noscript>`, `<template>`, `<svg>`,
`<iframe>` and friends are dropped subtree and all. Markdown metacharacters in
text are backslash-escaped, following turndown's list, and a paragraph that
would otherwise start like a heading, a quote or a list item is escaped too.

Whitespace is where real pages go wrong, so: text nodes are collapsed to single
spaces, an element that renders as nothing produces no block at all, runs of
blank lines collapse to one, and trailing whitespace is stripped — except inside
code blocks and inline code, which are protected byte for byte, and except the
two spaces of a hard break.

`html.parser` is a tokenizer rather than a tree builder, so the parser adds the
implicit end tags a browser would have inserted: `<li>` closes an open `<li>`
but not one across a nested `<ul>` boundary, `<td>`/`<tr>` close their siblings,
and a block-level start tag closes an open `<p>`. Unclosed and stray tags never
lose content.

### Not handled

* **`rowspan`.** `colspan` pads the row with empty cells so columns line up;
  `rowspan` is ignored and the row will be short. Wikipedia infoboxes are built
  out of both and come out as lopsided tables.
* **Nested tables.** An inner table is flattened to one line of text inside its
  cell.
* **Definition lists.** `<dt>` becomes a paragraph and `<dd>` an indented one;
  GFM has no definition list syntax.
* **CSS.** `display:none`, `visibility:hidden` and `hidden` are not honoured, so
  markup a page hides is still converted. Only `text-align` is read, and only
  for table cells.
* **Character-set declarations.** Input is decoded as UTF-8 (with a BOM sniff
  for UTF-8/UTF-16); a `<meta charset>` naming something else is ignored. Every
  Wayland `text/html` offer in practice is UTF-8, and `clipbasket-capture` has
  already forced the stored HTML to valid UTF-8.

---

## Writing to predictable paths

Everything above lives at a path anyone can guess: `~/.local/state/clipbasket`
and a fixed set of names beneath it. That makes every write a place where
another process running as **the same user** can get in front of us — plant a
symlink at `images/`, at `suppress`, at `settings.json` — and have our bytes
land somewhere of its choosing.

Checking the path first does not fix this. `[ -L "$dir" ]` followed by a `cp`
is two operations on a name, and the name can be re-pointed in between; the
check passes, the write goes elsewhere, and nothing looks wrong. Checking
harder makes the window smaller, never zero. This is the classic TOCTOU shape
and it is what the marketplace review flagged on 2026-08-24.

So the check is not what protects the write. **`bin/clipbasket-safefile`** does.

### The contract

`clipbasket-safefile` is a small python3 helper (standard library only —
python3 is already required by `clipbasket-html2md`) that bash calls for every
privileged write. bash cannot do this itself: it has no `O_NOFOLLOW`, no
`openat`, and no way to hold a directory descriptor across commands.

| Command | What it binds |
| --- | --- |
| `ensure-dir <path> [--mode]` | Opens every component with `O_DIRECTORY\|O_NOFOLLOW`, creating missing parents as exact `0700` and applying the requested mode only to the leaf; `fstat`s each descriptor for "is a directory, owned by us" |
| `write <dir> <name> [--mode] [--max-bytes N]` | Streams at most `N` bytes (64 MiB by default) into an `O_CREAT\|O_EXCL\|O_NOFOLLOW` temp file inside the **verified descriptor**, `fchmod`s the exact mode despite `umask`, `fsync`s, then `renameat`s onto the final name |
| `read <dir> <name>` | `openat` with `O_NOFOLLOW`, `fstat` regular-and-owned, stream to stdout |
| `unlink <dir> <name>` | `unlinkat` relative to the verified descriptor; a planted symlink is removed *as the link*, never followed |

Exit codes: `0` success, `2` the file is not there (`read` only, silent, an
ordinary outcome), `3` **refused** — a symlink, a wrong file type or a wrong
owner was found where it must not be — and `1` for anything else. A `3` is
never retried or worked around by any caller.

The property that matters: after `open_dir` returns, the caller holds a
descriptor, not a name. Whatever happens to the pathname afterwards, the
`renameat` still lands in the directory that was verified. Substituting the
directory after the check no longer substitutes the destination — it just
means the attacker owns a directory nobody is writing to.

### What is bound where

| Write | Bound by |
| --- | --- |
| `clips.db`, and its `-wal` / `-shm` | **CWD pinning**: `clipbasket-db` `cd -P`s into the state directory once, confirms `$PWD` came back equal to the path it asked for (so no component was a symlink) and that `.` is owned by us, then opens the database as `./clips.db`. sqlite3 resolves against the held working directory, and the journal files follow the database into it. |
| `.fts-enabled`, `.fts-disabled`, `.schema-vN` markers | `safefile write` / `unlink`. The hot path never opens marker content: non-symlink, owned, regular-file existence is only an untrusted cache hint, so the FTS-enabled path stays fork-free without following a planted marker. The legacy `.fts` name is removed through `unlinkat`. |
| `suppress` (write and consume) | `safefile write` / `read` / `unlink` |
| `images/<hash>.<ext>`, `thumbs/<hash>.png` | Staged in `$TMPDIR`, published with `safefile write` |
| `settings.json` (CLI and panel) | `safefile write`, with jq still doing the merge |
| `make-default.json`, `backups/bindings.lua.*` | `safefile write` |
| `globalShortcut` mirrored into `settings.json` | `safefile write`, best-effort: a refusal warns rather than failing the keybinding change it followed |
| `bindings.lua` | Resolved **once** with `readlink -f`, required to remain inside the canonical `$XDG_CONFIG_HOME`, then replaced as mode `0644` with `safefile write` against the resolved directory |

The pathname checks (`ensure_private_dir`, `refuse_symlink`) are still there
and still run first. They are fast-fail UX: they turn the common mistake into a
clear message without paying for a subprocess. They are explicitly *not* the
security boundary, and every one of them is commented to say so.

The reuse tests are non-following too, which is subtler than it sounds: `[ -f
"$target" ]` follows symlinks, so a link planted at a content-addressed image
name used to read as "already stored", skip the write, and get recorded —
refusing nothing and logging nothing. Those tests now ask `[ -L ]` as well, so
anything that is not a real file goes down the write path where the helper
refuses it.

The read and cleanup sides use the same discipline. `copy` accepts an image
path only when its parent is exactly `images/`, then streams the single basename
through `safefile read`; an asset symlink therefore produces no clipboard
bytes. Deletion accepts only direct children of `images/` or `thumbs/` and
passes the basename to `safefile unlink`. A prefix-shaped value such as
`images/../precious` is ignored rather than unlinked.

### Bounded reads

A size limit that is checked after the whole stream has been buffered protects
the database and not the process. `wl-paste` hands over whatever the owning
application chooses to send, and that application is not ours: an owner offering
a gigabyte, or one that simply never closes the pipe, used to be read to
completion before being rejected.

Every producer read is now bounded at ingest by `bounded_cat`, which is
`head -c` with the limit **plus one**. The extra byte preserves each existing
`-gt LIMIT` test exactly: content of exactly the limit reads the limit and is
accepted, anything larger reads limit+1 and is rejected. `head` closing its
input also sends the producer `SIGPIPE`, which is what makes a non-terminating
one terminate rather than stream into a pipe nobody is draining.

| Read | Bound |
| --- | --- |
| the payload on stdin | `CLIPBASKET_MAX_TEXT_BYTES` or `CLIPBASKET_MAX_IMAGE_BYTES`, by watcher |
| `wl-paste --list-types` | `CLIPBASKET_MAX_TYPES_BYTES` (65536); an oversized partial type list is unclassifiable and the change is dropped before the confidential check |
| the `text/html` flavour | `CLIPBASKET_MAX_HTML_BYTES` |
| `text/uri-list`, both readers | `CLIPBASKET_MAX_URI_LIST_BYTES`, default `MAX_FILE_ITEMS * 4096 + 1`; raw bytes are staged at limit+1 and rejected before parsing, so a partial final path is never recorded |
| `hyprctl activewindow` | 256 bytes, before `awk` parses the client-controlled `initialClass` line |

ImageMagick receives a second, decoder-level envelope on both `identify -ping`
and thumbnail conversion: memory 256 MiB, map 256 MiB, area 64 MP and time 10
seconds. If the bounded header probe cannot determine dimensions, Clipbasket
stores the original but skips thumbnail decoding entirely.

### The boundary, stated plainly

This defends against a same-user process substituting a directory or a file at
a predictable path between our check and our use. It does **not** defend
against a process that can already write inside our `0700` directories, that
can `ptrace` us, or that can replace `clipbasket-safefile` itself. Nothing in
userspace can: a process running as you, with your permissions, that has
already got inside your data directory has won before any of this starts. The
threat this closes is the race, and the race is closed by binding to
descriptors rather than by checking names more times.

The capture suite covers the bounds with a producer that keeps writing and
records how far it got: it is cut off within a pipe buffer of the limit rather
than draining, the clip is rejected by the existing check, and a producer that
never closes is shown to return rather than hang.

`clipbasket-safefile --selftest` covers the descriptor binding: 29 cases including planted symlinks
at a directory component, at a write destination and at an unlink target,
wrong-owner refusal, exact modes under a restrictive `umask`, private
intermediate directories, bounded streaming, temp-file cleanup on both the
success and the refusal path, and an assertion that nothing appears behind any planted link. Each of
the three shell suites additionally asserts that its writes actually go
*through* the helper, by pointing `CLIPBASKET_SAFEFILE` at a path that does not
exist and requiring the write to fail.

## Testing

```
bin/clipbasket-db selftest        # 138 cases, incl. migration, copy/GC exploit regressions
bin/clipbasket-html2md --selftest #  66 cases, one per supported element
bin/clipbasket-capture --selftest #  69 cases, against stubbed producers and ImageMagick
bin/clipbasket-omarchy selftest   #  33 cases, against a sandboxed bindings.lua
```

`clipbasket-db selftest` runs entirely in a temp directory and never touches the
real history. It needs no Wayland session: `copy` is exercised through a stub
injected with `CLIPBASKET_WL_COPY`, and the test asserts on the arguments and
the stdin bytes the real `wl-copy` would have received — that a `files` clip
sends `file://` URIs on `--type text/uri-list`, and that an `image` clip sends
the image's **file bytes** on `--type image/png` rather than its preview string.

### Environment overrides

| variable | default |
| --- | --- |
| `CLIPBASKET_STATE_DIR` | `$XDG_STATE_HOME/clipbasket` |
| `CLIPBASKET_DB` | `$STATE_DIR/clips.db` |
| `CLIPBASKET_SQLITE` | `sqlite3` |
| `CLIPBASKET_WL_COPY` | `wl-copy` |
| `CLIPBASKET_HTML2MD` | `bin/clipbasket-html2md` next to `clipbasket-db` |
| `CLIPBASKET_HTML2MD_PANDOC` | unset; `0` forces the built-in converter |
| `CLIPBASKET_DEDUPE_WINDOW` | 300 (seconds) |
| `CLIPBASKET_LIST_TEXT_CHARS` | 2000 |
| `CLIPBASKET_MAX_TEXT_BYTES` | 8388608 |
| `CLIPBASKET_MAX_HTML_BYTES` | 8388608 |
| `CLIPBASKET_MAX_IMAGE_BYTES` | 67108864 |
| `CLIPBASKET_MAX_FILE_ITEMS` | 1024 |
| `CLIPBASKET_MAX_URI_LIST_BYTES` | `CLIPBASKET_MAX_FILE_ITEMS * 4096 + 1` |
| `CLIPBASKET_MAX_TYPES_BYTES` | 65536 |
| `CLIPBASKET_MAX_IMAGE_DIMENSION` | 16384 |
| `CLIPBASKET_MAX_CLIPS` | 1000 |
| `CLIPBASKET_IGNORE_CONFIDENTIAL` | 1 (`0` records confidential offers) |
| `CLIPBASKET_WL_PASTE` | `wl-paste` |
