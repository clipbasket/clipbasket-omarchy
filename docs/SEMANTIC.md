# Semantic image search (optional add-on)

Clipbasket's built-in search finds images by the **text inside them** (OCR) and
by **visual similarity** (perceptual hash). This optional add-on adds the third
axis: **natural-language search of what an image depicts** — "a photo of a
beach", "a login screen", "a bar chart" — including photos that contain no text
at all.

It works by embedding every stored image and your query into the shared
**CLIP ViT-B/32** space and ranking images by cosine similarity. Everything runs
locally on the CPU; nothing is uploaded.

It is **opt-in and never required.** A stock Clipbasket install does not ship a
neural-network runtime — that would break the "git clone and run" promise — so
this feature is a clean no-op until you install the small runtime below, exactly
like `pandoc` for *Copy as Markdown* or `tesseract` for OCR.

## Why it is not on by default

The runtime it needs (`onnxruntime` via [`fastembed`](https://github.com/qdrant/fastembed))
is not in the Arch repositories and does not ship with the plugin. Rather than
bundle a per-architecture native library (which every marketplace security
review would have to vet), Clipbasket lets you install it yourself, once.

## Install

You need a Python with `fastembed`. The default location Clipbasket looks for is
a venv at `~/.local/share/clipbasket/clip-venv`:

```sh
# A stable Python 3.10–3.12 works well; onnxruntime has no wheels for very new
# Python yet. If your system python3 is too new, get one with mise/pyenv:
#   mise install python@3.12 && PY=$(mise where python@3.12)/bin/python3
PY=python3   # or the one from the line above

"$PY" -m venv ~/.local/share/clipbasket/clip-venv
~/.local/share/clipbasket/clip-venv/bin/pip install fastembed
```

That is it. `clipbasket-omarchy doctor` will then show:

```
PASS  Semantic image search (CLIP)       add-on ready
```

Point Clipbasket at a different interpreter with `CLIPBASKET_EMBED_PYTHON=/path/to/python`
if you keep `fastembed` somewhere else.

The CLIP model (~350 MB, ViT-B/32 vision + text ONNX) downloads once on first
use into `~/.local/share/clipbasket/clip-models`.

## Use

Index your existing images once (new copies are indexed automatically in the
background afterwards):

```sh
clipbasket-embed index --all        # embed every image
clipbasket-embed pending            # {"images":N,"embedded":M,"pending":N-M}
```

Then search by meaning:

```sh
clipbasket-db semantic "a qr code to scan"
clipbasket-db semantic "a cryptocurrency price chart" --limit 5 --min-score 0.2
# or call the add-on directly:
clipbasket-embed search "a chat conversation"
```

Each result is `{id, score, kind, preview, image_path, thumb_path}`, best match
first. `score` is cosine similarity in the CLIP space (roughly 0.2–0.35 for a
good match on screenshots; real photos separate much more strongly).

## How it fits together

| axis | tool | finds |
| --- | --- | --- |
| text in the image | `tesseract` (OCR) | screenshots by their words |
| visual look-alikes | ImageMagick (dHash) | near-duplicates, re-encodings |
| **what it depicts** | **this add-on (CLIP)** | **images by natural-language meaning** |

- Embeddings are 512 float32, L2-normalised, stored in `clips.clip_embed`
  (schema v5). Search is a brute-force cosine over the stored images — for a
  history of a few thousand clips this is well under a millisecond in NumPy, so
  no vector index or extra dependency is needed.
- `bin/clipbasket-embed` is a thin wrapper that finds the interpreter and
  serialises indexing with a lock; `bin/clipbasket_embed.py` is the engine.
- Capture hands each new image to `clipbasket-embed index --id N` in the
  background (detached, low priority) **only when the add-on is installed**.
- Removing a clip removes its embedding with the row; re-run `index --all`
  after installing to backfill older images.

## Environment overrides

| variable | default |
| --- | --- |
| `CLIPBASKET_EMBED_PYTHON` | `~/.local/share/clipbasket/clip-venv/bin/python` |
| `CLIPBASKET_EMBED` | `1` (`0` disables background indexing at capture) |
| `CLIPBASKET_CLIP_IMAGE_MODEL` | `Qdrant/clip-ViT-B-32-vision` |
| `CLIPBASKET_CLIP_TEXT_MODEL` | `Qdrant/clip-ViT-B-32-text` |
