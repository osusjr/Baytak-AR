#!/usr/bin/env python3
"""
Model benchmark for the blueprint-reading step (v18 symptom: every drawing
produced roughly the same kitchen). Sends each bench blueprint through the
app's EXACT prompt + image pipeline to each candidate NVIDIA-hosted model,
scores layout fidelity against ground truth, and measures cross-drawing
diversity (does the model actually read the drawing, or answer a default?).

Usage:  NVIDIA_API_KEY=nvapi-... python3 bench_models.py [--models a,b,c]
Writes: out/raw_<model>_<bp>.txt and prints a score table.
"""

import argparse
import base64
import io
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parent / "out"
ENDPOINT = "https://integrate.api.nvidia.com/v1/chat/completions"
BUDGET = 130 * 1024

MODELS = [
    "nvidia/nemotron-nano-12b-v2-vl",
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
    "meta/llama-4-maverick-17b-128e-instruct",
    "qwen/qwen3.5-397b-a17b",
    "qwen/qwen3.5-122b-a10b",
    "mistralai/mistral-small-4-119b-2603",
    "google/gemma-4-31b-it",
    "meta/llama-3.2-90b-vision-instruct",
]

# EXACT copy of the app's prompt (lib/services/blueprint_ai.dart _prompt)
PROMPT = """
You are a kitchen floor-plan reader. Analyze the attached blueprint image
and return the kitchen layout as JSON ONLY - no prose, no markdown fences.

Coordinate system: looking at the drawing, origin is the TOP-LEFT inside
corner of the room. x runs right (metres), z runs down (metres).
Walls: north = top edge, south = bottom, west = left, east = right.
Positions along north/south walls are x metres; along east/west walls are
z metres, both measured from that wall's origin end (west end for N/S,
north end for E/W).

Read printed dimensions when present (convert feet/inches to metres);
otherwise estimate from scale. Cabinet runs are the counter rectangles
against walls. Mark sink_at_m / range_at_m with the centre position of the
basin / cooktop ON that run, or null. A freestanding or peninsula counter
(bar) is the "island"; if the cooktop sits on it, set cooktop true, and
set seating to the side where stools/overhang are drawn. x_m,z_m are the
island's top-left corner.

Schema (all lengths in metres, numbers only):
{
 "width_m": 0.0,
 "depth_m": 0.0,
 "runs": [
   {"wall":"north|south|east|west","from_m":0.0,"to_m":0.0,
    "sink_at_m":null,"range_at_m":null,
    "fridge":"start|end|null","uppers":true}
 ],
 "island": {"present":false,"x_m":0.0,"z_m":0.0,"w_m":0.0,"d_m":0.0,
            "seating":"north|south|east|west","cooktop":false},
 "windows": [{"wall":"north","center_m":0.0,"width_m":0.0}],
 "palette": "warm_walnut|light_oak|dark_modern",
 "summary": "one short sentence describing the layout"
}

Choose the palette that suits the drawing's context: warm_walnut for
classic/family homes, light_oak for bright/small/modern spaces,
dark_modern for premium/contemporary.
"""


def prep_image(path):
    """Mirror of the app's _shrinkForAi."""
    raw = path.read_bytes()
    im = Image.open(io.BytesIO(raw)).convert("RGB")
    for max_dim, q in [(1600, 80), (1280, 72), (1024, 64), (900, 56),
                       (768, 50), (640, 45)]:
        frame = im
        if max(im.size) > max_dim:
            scale = max_dim / max(im.size)
            frame = im.resize((round(im.width * scale),
                               round(im.height * scale)))
        buf = io.BytesIO()
        frame.save(buf, "JPEG", quality=q)
        data = buf.getvalue()
        if len(data) <= BUDGET:
            return data
    return data


def extract_json(text):
    """Mirror of the app's extractJsonObject."""
    t = re.sub(r"<think>[\s\S]*?</think>", "", text).strip()
    t = re.sub(r"^```[a-zA-Z]*\s*", "", t)
    t = re.sub(r"```\s*$", "", t).strip()
    start = t.find("{")
    if start < 0:
        return t
    depth, in_str = 0, False
    i = start
    while i < len(t):
        c = t[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return t[start:i + 1]
        i += 1
    return t[start:]


def call(model, key, img_b64, timeout=75):
    body = json.dumps({
        "model": model,
        "max_tokens": 4096,
        "temperature": 0.2,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": PROMPT},
                {"type": "image_url",
                 "image_url": {"url": f"data:image/jpeg;base64,{img_b64}"}},
            ],
        }],
    }).encode()
    req = urllib.request.Request(ENDPOINT, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read())
        dt = time.time() - t0
        choice = data["choices"][0]
        return {"ok": True, "secs": dt,
                "finish": choice.get("finish_reason"),
                "text": choice["message"]["content"] or ""}
    except Exception as e:  # noqa: BLE001 - benchmark records all failures
        return {"ok": False, "secs": time.time() - t0, "error": f"{type(e).__name__}: {e}"[:160]}


# ------------------------------------------------------------------ scoring
def norm_runs(runs):
    out = []
    for r in runs or []:
        if not isinstance(r, dict):
            continue
        out.append({
            "wall": str(r.get("wall", "")),
            "from": _num(r.get("from_m")),
            "to": _num(r.get("to_m")),
            "sink": _num(r.get("sink_at_m")),
            "range": _num(r.get("range_at_m")),
            "fridge": r.get("fridge") if r.get("fridge") in ("start", "end") else None,
        })
    return out


def _num(v):
    try:
        f = float(v)
        return None if f != f else f
    except (TypeError, ValueError):
        return None


def score(pred, truth):
    """0-100 layout fidelity."""
    s = 0.0
    w, d = _num(pred.get("width_m")) or 0, _num(pred.get("depth_m")) or 0
    dims_err = abs(w - truth["width_m"]) + abs(d - truth["depth_m"])
    s += 30 * max(0.0, 1 - max(0.0, dims_err - 0.3) / 1.7)

    truth_walls = {r["wall"] for r in truth["runs"]}
    pred_walls = {r["wall"] for r in norm_runs(pred.get("runs"))}
    union = truth_walls | pred_walls
    s += 25 * (len(truth_walls & pred_walls) / len(union) if union else 0)

    pruns = norm_runs(pred.get("runs"))

    def appliance(kind):
        tr = next((r for r in truth["runs"] if r.get(f"{kind}_at_m") is not None), None) \
            if kind != "fridge" else \
            next((r for r in truth["runs"] if r.get("fridge")), None)
        pr = next((r for r in pruns if r[kind if kind != "fridge" else "fridge"] is not None), None)
        if tr is None:
            return 10.0 if pr is None else 0.0
        if pr is None:
            return 0.0
        pts = 4.0 if pr["wall"] == tr["wall"] else 0.0
        if kind == "fridge":
            # right end of the right wall
            if pr["wall"] == tr["wall"] and pr["fridge"] == tr["fridge"]:
                pts += 6.0
        else:
            tpos, ppos = tr[f"{kind}_at_m"], pr[kind]
            if ppos is not None and pr["wall"] == tr["wall"]:
                err = abs(ppos - tpos)
                pts += 6.0 * max(0.0, 1 - max(0.0, err - 0.4) / 1.1)
        return pts

    s += appliance("sink") + appliance("range") + appliance("fridge")

    t_isl = truth["island"]["present"]
    p_isl = bool(isinstance(pred.get("island"), dict)
                 and pred["island"].get("present"))
    s += 15 if t_isl == p_isl else 0
    return round(s, 1)


def signature(pred):
    """Coarse layout signature for cross-drawing diversity checks."""
    w = _num(pred.get("width_m")) or 0
    d = _num(pred.get("depth_m")) or 0
    walls = tuple(sorted({r["wall"] for r in norm_runs(pred.get("runs"))}))
    isl = bool(isinstance(pred.get("island"), dict)
               and pred["island"].get("present"))
    return (round(w, 1), round(d, 1), walls, isl)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default=None)
    args = ap.parse_args()
    key = os.environ.get("NVIDIA_API_KEY", "")
    if not key:
        sys.exit("set NVIDIA_API_KEY")
    models = args.models.split(",") if args.models else MODELS

    truths = json.loads((OUT / "truths.json").read_text())
    images = {t["name"]: base64.b64encode(
        prep_image(OUT / f"{t['name']}.png")).decode() for t in truths}

    results = {}
    for model in models:
        row = {"scores": [], "secs": [], "sigs": [], "fails": []}
        for t in truths:
            r = call(model, key, images[t["name"]])
            tag = f"{model.replace('/', '_')}_{t['name']}"
            if not r["ok"]:
                (OUT / f"raw_{tag}.txt").write_text(r["error"])
                row["fails"].append(f"{t['name']}:{r['error'][:60]}")
                row["scores"].append(0.0)
                row["secs"].append(r["secs"])
                continue
            (OUT / f"raw_{tag}.txt").write_text(r["text"])
            try:
                pred = json.loads(extract_json(r["text"]))
                sc = score(pred, t)
                row["sigs"].append(signature(pred))
            except (ValueError, TypeError) as e:
                sc = 0.0
                row["fails"].append(f"{t['name']}:parse:{e}"[:70])
            row["scores"].append(sc)
            row["secs"].append(r["secs"])
            time.sleep(1.5)  # stay under the free-tier rate limit
        results[model] = row
        avg = sum(row["scores"]) / len(row["scores"])
        div = len(set(row["sigs"]))
        print(f"{model:48s} avg {avg:5.1f}  "
              f"scores {['%.0f' % s for s in row['scores']]}  "
              f"secs {['%.0f' % s for s in row['secs']]}  "
              f"distinct-layouts {div}/{len(row['sigs'])}"
              f"  fails {len(row['fails'])}")
        for f in row["fails"]:
            print(f"      ! {f}")

    (OUT / "bench_results.json").write_text(json.dumps(
        {m: {k: (v if k != "sigs" else [str(s) for s in v])
             for k, v in row.items()} for m, row in results.items()},
        indent=1))
    print("\nwrote bench_results.json")


if __name__ == "__main__":
    main()
