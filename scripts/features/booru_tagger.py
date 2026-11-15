#!/usr/bin/env python3
"""WD14 tagger used by the booru_guess surprise feature.

Runs a SmilingWolf WD14 ONNX model on an image and prints character +
general tags as JSON to stdout (logs go to stderr):

    {"characters": {"yuuki_haru": 0.93, ...}, "general": {"1girl": 0.99, ...}}

Only stdout is parsed by booru_guess.sh — keep it pure JSON.
"""

import argparse
import csv
import json
import os
import sys


def die(msg):
    print(f"[booru_tagger] {msg}", file=sys.stderr)
    sys.exit(1)


def ensure_model(model_repo, model_dir):
    """Download model.onnx + selected_tags.csv into model_dir if missing."""
    onnx_path = os.path.join(model_dir, "model.onnx")
    csv_path = os.path.join(model_dir, "selected_tags.csv")
    if os.path.exists(onnx_path) and os.path.exists(csv_path):
        return
    if not model_repo:
        die("model files missing and no --model-repo given")
    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        die("huggingface_hub not installed (pip install huggingface_hub)")
    os.makedirs(model_dir, exist_ok=True)
    for fname in ("model.onnx", "selected_tags.csv"):
        print(f"[booru_tagger] downloading {model_repo}/{fname} ...", file=sys.stderr)
        hf_hub_download(model_repo, fname, local_dir=model_dir)


def preprocess(image_path, size):
    """WD14 preprocessing: white-composite, pad to square, resize, RGB->BGR."""
    from PIL import Image
    import numpy as np

    img = Image.open(image_path)
    if img.mode == "GIF":
        img.seek(0)  # first frame
    img = img.convert("RGBA")
    bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
    img = Image.alpha_composite(bg, img).convert("RGB")

    side = max(img.size)
    square = Image.new("RGB", (side, side), (255, 255, 255))
    square.paste(img, (0, 0))  # top-left anchor, WD14 convention
    square = square.resize((size, size), Image.LANCZOS)

    arr = np.asarray(square, dtype=np.float32)
    arr = arr[:, :, ::-1]  # RGB -> BGR (WD14 convention)
    return arr


def main():
    ap = argparse.ArgumentParser(description="WD14 booru tagger (JSON to stdout)")
    ap.add_argument("--image", required=True, help="path to the image")
    ap.add_argument("--model-dir", required=True, help="dir holding model.onnx + selected_tags.csv")
    ap.add_argument("--model-repo", default="",
                    help="HF repo id to download the model from when missing")
    ap.add_argument("--char-thresh", type=float, default=0.35)
    ap.add_argument("--gen-thresh", type=float, default=0.35)
    args = ap.parse_args()

    if not os.path.exists(args.image):
        die(f"image not found: {args.image}")
    ensure_model(args.model_repo, args.model_dir)

    # --- tag vocabulary ---
    names, cats = [], []
    csv_path = os.path.join(args.model_dir, "selected_tags.csv")
    try:
        with open(csv_path, newline="", encoding="utf-8") as f:
            for row in csv.reader(f):
                if not row or row[0] == "tag_id":
                    continue
                names.append(row[1])
                cats.append(int(row[2]))
    except OSError as e:
        die(f"cannot read {csv_path}: {e}")
    if not names:
        die(f"empty vocabulary: {csv_path}")

    # --- model ---
    try:
        import numpy as np
        import onnxruntime as ort
    except ImportError:
        die("onnxruntime/numpy not installed (pip install onnxruntime numpy)")

    sess = ort.InferenceSession(
        os.path.join(args.model_dir, "model.onnx"), providers=["CPUExecutionProvider"]
    )
    inp = sess.get_inputs()[0]
    size = inp.shape[1] if isinstance(inp.shape[1], int) else 0
    if not size or size < 64:  # guard against NCHW-shaped inputs
        size = 448

    x = preprocess(args.image, size)[None, ...]  # NHWC batch of one
    scores = sess.run(None, {inp.name: x})[0][0]
    probs = 1.0 / (1.0 + np.exp(-scores))

    characters, general = {}, {}
    for name, cat, p in zip(names, cats, probs):
        p = round(float(p), 4)
        if cat == 4 and p >= args.char_thresh:
            characters[name] = p
        elif cat == 0 and p >= args.gen_thresh:
            general[name] = p

    json.dump(
        {
            "characters": dict(sorted(characters.items(), key=lambda kv: -kv[1])),
            "general": dict(sorted(general.items(), key=lambda kv: -kv[1])),
        },
        sys.stdout,
    )
    print()


if __name__ == "__main__":
    main()
