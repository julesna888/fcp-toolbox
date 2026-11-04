#!/usr/bin/env python3
"""FCP Toolbox: local footage search with CLIP. Runs fully offline.

  clipsearch.py index  <db.json> <ffmpeg> <list.txt>      list.txt: "path<TAB>duration_seconds" per line
  clipsearch.py search <db.json> "<query>" [limit] [folder]
  clipsearch.py describe <db.json> <vocab.json> <vocab_cache.npz> <paths.txt>   paths.txt: one clip path per line

Progress and results are printed as one JSON object per line.
"""
import hashlib
import json
import os
import subprocess
import sys

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS = os.path.join(HERE, "models")
MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32).reshape(1, 1, 3)
STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32).reshape(1, 1, 3)
SIZE = 224


def session(name):
    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    return ort.InferenceSession(os.path.join(MODELS, name), opts, providers=["CPUExecutionProvider"])


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def normalize(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-9)


def frame(ffmpeg, path, t):
    """One 224x224 RGB frame (resized, centre-cropped like CLIP does), or None."""
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-ss", "%.3f" % max(0.0, t), "-i", path, "-frames:v", "1",
           "-vf", "scale=%d:%d:force_original_aspect_ratio=increase:flags=bicubic,crop=%d:%d" % (SIZE, SIZE, SIZE, SIZE),
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
    if len(out) != SIZE * SIZE * 3:
        return None
    arr = np.frombuffer(out, dtype=np.uint8).reshape(SIZE, SIZE, 3).astype(np.float32) / 255.0
    return ((arr - MEAN) / STD).transpose(2, 0, 1)


def frame_times(duration):
    if duration <= 0.5:
        return [0.0]
    n = min(8, max(3, int(duration / 8)))
    return [duration * (i + 0.5) / n for i in range(n)]


def index(db_path, ffmpeg, list_path):
    db = {"version": 1, "items": {}}
    if os.path.exists(db_path):
        try:
            db = json.load(open(db_path))
        except Exception:
            pass
    items = [line.rstrip("\n").split("\t") for line in open(list_path, encoding="utf-8") if line.strip()]
    vision = session("vision.onnx")
    done = 0
    for path, duration in items:
        done += 1
        try:
            st = os.stat(path)
        except OSError:
            continue
        old = db["items"].get(path)
        if old and old["mtime"] == int(st.st_mtime) and old["size"] == st.st_size:
            emit({"done": done, "total": len(items), "path": path, "skipped": True})
            continue
        times, batch = [], []
        for t in frame_times(float(duration)):
            f = frame(ffmpeg, path, t)
            if f is not None:
                times.append(t)
                batch.append(f)
        if not batch:
            emit({"done": done, "total": len(items), "path": path, "error": "nessun fotogramma leggibile"})
            continue
        vecs = normalize(vision.run(None, {"pixel_values": np.stack(batch)})[0])
        db["items"][path] = {"mtime": int(st.st_mtime), "size": st.st_size, "times": times,
                             "vecs": [[round(float(x), 5) for x in v] for v in vecs]}
        emit({"done": done, "total": len(items), "path": path})
        if done % 20 == 0:
            tmp = db_path + ".tmp"
            json.dump(db, open(tmp, "w"))
            os.replace(tmp, db_path)
    tmp = db_path + ".tmp"
    json.dump(db, open(tmp, "w"))
    os.replace(tmp, db_path)
    emit({"finished": True, "clips": len(db["items"])})


def search(db_path, query, limit, folder):
    db = json.load(open(db_path))
    tok = Tokenizer.from_file(os.path.join(MODELS, "tokenizer_it.json"))
    tok.enable_truncation(max_length=128)
    enc = tok.encode(query)
    ids = np.array([enc.ids], dtype=np.int64)
    mask = np.array([enc.attention_mask], dtype=np.int64)
    out = session("text_it.onnx").run(["sentence_embedding"], {"input_ids": ids, "attention_mask": mask})[0]
    q = normalize(out)[0]
    results = []
    for path, item in db["items"].items():
        if folder and not path.startswith(folder):
            continue
        if not os.path.exists(path):
            continue
        scores = np.array(item["vecs"], dtype=np.float32) @ q
        i = int(scores.argmax())
        results.append({"path": path, "score": float(scores[i]), "time": item["times"][i]})
    results.sort(key=lambda r: -r["score"])
    emit({"results": results[:limit], "searched": len(results)})


def text_vectors(session_, tok, texts):
    vecs = []
    for t in texts:
        enc = tok.encode(t)
        ids = np.array([enc.ids], dtype=np.int64)
        mask = np.array([enc.attention_mask], dtype=np.int64)
        vecs.append(normalize(session_.run(["sentence_embedding"], {"input_ids": ids, "attention_mask": mask})[0])[0])
    return np.stack(vecs)


def describe(db_path, vocab_path, cache_path, paths_path):
    """For every clip prints the best CLIP score (over its frames) of each vocabulary phrase, in vocabulary order.
    The text vectors of the vocabulary are computed once and cached; the cache is tied to the vocabulary file's hash."""
    raw = open(vocab_path, "rb").read()
    digest = hashlib.sha1(raw).hexdigest()
    prompts = [e["prompt"] for e in json.loads(raw.decode("utf-8"))]
    vecs, cached = None, False
    try:
        c = np.load(cache_path)
        if str(c["hash"]) == digest and c["vecs"].shape[0] == len(prompts):
            vecs, cached = c["vecs"], True
    except Exception:
        pass
    if vecs is None:
        tok = Tokenizer.from_file(os.path.join(MODELS, "tokenizer_it.json"))
        tok.enable_truncation(max_length=128)
        vecs = text_vectors(session("text_it.onnx"), tok, prompts).astype(np.float32)
        tmp = cache_path + ".tmp.npz"
        np.savez(tmp, hash=np.array(digest), vecs=vecs)
        os.replace(tmp, cache_path)
    db = json.load(open(db_path))
    emit({"vocab": len(prompts), "cached": cached})
    for path in [l.rstrip("\n") for l in open(paths_path, encoding="utf-8") if l.strip()]:
        item = db["items"].get(path)
        if not item:
            emit({"path": path, "error": "clip non analizzata"})
            continue
        scores = (np.array(item["vecs"], dtype=np.float32) @ vecs.T).max(axis=0)
        emit({"path": path, "scores": [round(float(x), 4) for x in scores]})


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "index":
        index(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "search":
        search(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 20, sys.argv[5] if len(sys.argv) > 5 else "")
    elif cmd == "describe":
        describe(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
