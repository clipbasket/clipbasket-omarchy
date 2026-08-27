#!/usr/bin/env python3
"""clipbasket-caption's engine — describe images in a short sentence.

Run through the ``clipbasket-caption`` wrapper, which selects a Python that has
``transformers`` + ``optimum[onnxruntime]`` + ``torch``. Heavy imports are
deferred until a caption is actually generated, so ``pending`` and argument
errors stay fast.

Captions are written through ``clipbasket-db set-caption``, which folds them
into the search index and titles a photo that has no text of its own. This
module only ever reads image files that are direct children of ``images/``.
"""

import argparse
import json
import os
import subprocess
import sys

MODEL = os.environ.get("CLIPBASKET_CAPTION_MODEL", "Xenova/vit-gpt2-image-captioning")
MAX_TOKENS = int(os.environ.get("CLIPBASKET_CAPTION_MAX_TOKENS", "20"))


def state_dir():
    base = os.environ.get("CLIPBASKET_STATE_DIR")
    if base:
        return base
    xdg = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(xdg, "clipbasket")


def db_path():
    return os.environ.get("CLIPBASKET_DB") or os.path.join(state_dir(), "clips.db")


def image_dir():
    return os.path.join(state_dir(), "images")


def db_cli():
    return os.environ.get("CLIPBASKET_DB_CLI") or os.path.join(
        os.path.dirname(os.path.realpath(__file__)), "clipbasket-db"
    )


def model_cache():
    xdg = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    d = os.path.join(xdg, "clipbasket", "clip-models")
    os.makedirs(d, exist_ok=True)
    return d


def _under_image_dir(path):
    if not path:
        return None
    rp = os.path.realpath(path)
    if os.path.dirname(rp) == os.path.realpath(image_dir()) and os.path.isfile(rp):
        return rp
    return None


def _pending(cur, args):
    import sqlite3  # noqa

    if args.id is not None:
        rows = cur.execute(
            "SELECT id, image_path FROM clips WHERE id=? AND kind='image'", (args.id,)
        ).fetchall()
    elif args.all:
        rows = cur.execute(
            "SELECT id, image_path FROM clips WHERE kind='image' AND image_path IS NOT NULL "
            "ORDER BY created_at DESC"
        ).fetchall()
    else:
        rows = cur.execute(
            "SELECT id, image_path FROM clips WHERE kind='image' AND image_path IS NOT NULL "
            "AND caption IS NULL ORDER BY created_at DESC"
        ).fetchall()
    if args.limit:
        rows = rows[: args.limit]
    out = []
    for cid, path in rows:
        rp = _under_image_dir(path)
        if rp:
            out.append((cid, rp))
    return out


def _store(cid, caption):
    subprocess.run(
        [db_cli(), "set-caption", str(cid), "--caption", caption],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def _clean(text):
    text = " ".join(text.split()).strip()
    if text and text[0].islower():
        text = text[0].upper() + text[1:]
    return text


def _connect():
    import sqlite3

    con = sqlite3.connect(db_path())
    cols = [r[1] for r in con.execute("PRAGMA table_info(clips)").fetchall()]
    if "caption" not in cols:
        con.execute("ALTER TABLE clips ADD COLUMN caption TEXT")
        con.commit()
    return con


def cmd_caption(args):
    con = _connect()
    todo = _pending(con.cursor(), args)
    if not todo:
        print(json.dumps({"captioned": 0}))
        return 0

    from optimum.onnxruntime import ORTModelForVision2Seq
    from transformers import AutoImageProcessor, AutoTokenizer
    from PIL import Image

    model = ORTModelForVision2Seq.from_pretrained(
        MODEL, subfolder="onnx", use_io_binding=False, cache_dir=model_cache()
    )
    processor = AutoImageProcessor.from_pretrained(MODEL, use_fast=True, cache_dir=model_cache())
    tokenizer = AutoTokenizer.from_pretrained(MODEL, cache_dir=model_cache())

    n = 0
    for cid, path in todo:
        try:
            img = Image.open(path).convert("RGB")
        except Exception:
            continue
        pv = processor(images=img, return_tensors="pt").pixel_values
        out = model.generate(pixel_values=pv, max_new_tokens=MAX_TOKENS, num_beams=1)
        caption = _clean(tokenizer.batch_decode(out, skip_special_tokens=True)[0])
        if caption:
            _store(cid, caption)
            n += 1
    print(json.dumps({"captioned": n}))
    return 0


def cmd_pending(args):
    con = _connect()
    (total,) = con.execute(
        "SELECT count(*) FROM clips WHERE kind='image' AND image_path IS NOT NULL"
    ).fetchone()
    (done,) = con.execute(
        "SELECT count(*) FROM clips WHERE kind='image' AND caption IS NOT NULL"
    ).fetchone()
    print(json.dumps({"images": total, "captioned": done, "pending": total - done}))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="clipbasket-caption")
    sub = p.add_subparsers(dest="cmd", required=True)

    pc = sub.add_parser("caption", help="describe images that have no caption yet")
    pc.add_argument("--all", action="store_true", help="re-caption every image")
    pc.add_argument("--id", type=int, default=None, help="caption one clip id")
    pc.add_argument("--limit", type=int, default=0)
    pc.set_defaults(func=cmd_caption)

    pp = sub.add_parser("pending", help="how many images still need a caption")
    pp.set_defaults(func=cmd_pending)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
