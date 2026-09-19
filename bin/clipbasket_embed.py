#!/usr/bin/env python3
"""clipbasket-embed's engine — CLIP image/text embeddings for semantic search.

Run through the ``clipbasket-embed`` wrapper, which selects a Python that has
``fastembed`` + ``onnxruntime`` installed. This module never imports those heavy
libraries until it actually needs them, so ``--help`` and argument errors stay
fast and dependency-free.

Vectors are L2-normalised CLIP ViT-B/32 embeddings (512 float32), stored as a
BLOB in ``clips.clip_embed``. Search is a brute-force cosine (a dot product of
normalised vectors) over the stored images — for a clipboard history of a few
thousand clips this is well under a millisecond in NumPy, so no vector index or
extra dependency is needed.
"""

import argparse
import json
import os
import sqlite3
import sys

MODEL_IMG = os.environ.get("CLIPBASKET_CLIP_IMAGE_MODEL", "Qdrant/clip-ViT-B-32-vision")
MODEL_TXT = os.environ.get("CLIPBASKET_CLIP_TEXT_MODEL", "Qdrant/clip-ViT-B-32-text")


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


def model_cache():
    xdg = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    d = os.path.join(xdg, "clipbasket", "clip-models")
    os.makedirs(d, exist_ok=True)
    return d


def connect():
    con = sqlite3.connect(db_path())
    # The column may not exist yet on a database an old clipbasket-db created;
    # add it here too so the add-on is self-sufficient. Idempotent.
    cols = [r[1] for r in con.execute("PRAGMA table_info(clips)").fetchall()]
    if "clip_embed" not in cols:
        con.execute("ALTER TABLE clips ADD COLUMN clip_embed BLOB")
        con.commit()
    return con


def _np():
    import numpy as np  # noqa: local import keeps --help dependency-free
    return np


def pack(vec):
    np = _np()
    v = np.asarray(vec, dtype=np.float32).reshape(-1)
    n = np.linalg.norm(v)
    if n > 0:
        v = v / n
    return v.astype(np.float32).tobytes()


def unpack(blob):
    np = _np()
    return np.frombuffer(blob, dtype=np.float32)


def _under_image_dir(path):
    """Only ever read files that are direct children of images/."""
    if not path:
        return None
    rp = os.path.realpath(path)
    if os.path.dirname(rp) == os.path.realpath(image_dir()) and os.path.isfile(rp):
        return rp
    return None


def cmd_index(args):
    con = connect()
    cur = con.cursor()
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
            "AND clip_embed IS NULL ORDER BY created_at DESC"
        ).fetchall()
    if args.limit:
        rows = rows[: args.limit]

    todo = []
    for cid, path in rows:
        rp = _under_image_dir(path)
        if rp:
            todo.append((cid, rp))
    if not todo:
        print(json.dumps({"indexed": 0}))
        return 0

    from fastembed import ImageEmbedding

    model = ImageEmbedding(MODEL_IMG, cache_dir=model_cache())
    paths = [p for _, p in todo]
    n = 0
    for (cid, _), emb in zip(todo, model.embed(paths)):
        cur.execute("UPDATE clips SET clip_embed=? WHERE id=?", (pack(emb), cid))
        n += 1
    con.commit()
    print(json.dumps({"indexed": n}))
    return 0


def cmd_search(args):
    con = connect()
    rows = con.execute(
        "SELECT id, clip_embed, kind, preview, image_path, thumb_path "
        "FROM clips WHERE clip_embed IS NOT NULL"
    ).fetchall()
    if not rows:
        print("[]")
        return 0

    np = _np()
    mat = np.stack([unpack(r[1]) for r in rows])  # (N, D), already normalised

    from fastembed import TextEmbedding

    tm = TextEmbedding(MODEL_TXT, cache_dir=model_cache())
    q = np.asarray(list(tm.embed([args.query]))[0], dtype=np.float32).reshape(-1)
    n = np.linalg.norm(q)
    if n > 0:
        q = q / n

    scores = mat @ q
    order = np.argsort(-scores)[: args.limit]
    out = []
    for i in order:
        s = float(scores[i])
        if s < args.min_score:
            continue
        r = rows[int(i)]
        out.append(
            {
                "id": r[0],
                "score": round(s, 4),
                "kind": r[2],
                "preview": r[3],
                "image_path": r[4],
                "thumb_path": r[5],
            }
        )
    print(json.dumps(out))
    return 0


def cmd_pending(args):
    con = connect()
    (total,) = con.execute(
        "SELECT count(*) FROM clips WHERE kind='image' AND image_path IS NOT NULL"
    ).fetchone()
    (done,) = con.execute(
        "SELECT count(*) FROM clips WHERE kind='image' AND clip_embed IS NOT NULL"
    ).fetchone()
    print(json.dumps({"images": total, "embedded": done, "pending": total - done}))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="clipbasket-embed", add_help=True)
    sub = p.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("index", help="embed images that lack a vector")
    pi.add_argument("--all", action="store_true", help="re-embed every image")
    pi.add_argument("--id", type=int, default=None, help="embed one clip id")
    pi.add_argument("--limit", type=int, default=0)
    pi.set_defaults(func=cmd_index)

    ps = sub.add_parser("search", help="rank images by a natural-language query")
    ps.add_argument("query")
    ps.add_argument("--limit", type=int, default=20)
    ps.add_argument("--min-score", type=float, default=0.18, dest="min_score")
    ps.set_defaults(func=cmd_search)

    pp = sub.add_parser("pending", help="how many images still need embedding")
    pp.set_defaults(func=cmd_pending)

    args = p.parse_args(argv)
    try:
        return args.func(args)
    except sqlite3.Error as exc:
        sys.stderr.write("clipbasket-embed: database error: %s\n" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
