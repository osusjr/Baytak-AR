#!/usr/bin/env python3
"""
Two-stage pipeline benchmark (build 20): stage 1 = a VISION model writes an
exhaustive measured description of the drawing; stage 2 = a TEXT reasoning
model turns that description into the app's strict LayoutPlan JSON.

Compares each two-stage combo against the single-stage baseline on the
four bench blueprints (incl. bp_ushape, the owner's real failing drawing).
Reuses the drawing/scoring helpers from bench_models.py.

Usage:
  python3 blueprints_bench.py                       # regenerate drawings
  NVIDIA_API_KEY=nvapi-... python3 bench_two_stage.py
"""

import base64
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

from bench_models import (ENDPOINT, OUT, extract_json, prep_image, score,
                          signature)

VISION_MODEL = "qwen/qwen3.5-397b-a17b"  # b19 benchmark winner

TEXT_MODELS = [
    "mistralai/mistral-large-3-675b-instruct-2512",
    "deepseek-ai/deepseek-v4-pro",
    "nvidia/nemotron-3-super-120b-a12b",
]

# EXACT copies of the app's b20 prompts (lib/services/blueprint_ai.dart).
SENSES = """
Distinguish carefully:
- A TALL or PANTRY unit is NOT a fridge. Only report a fridge where the
  drawing marks REF/FRIDGE or draws the dashed appliance box.
- A counter attached to a run or wall but extending into the room (bar,
  peninsula) is NEVER a wall run - it is the "island" object. Runs hug
  walls only.
- Edges drawn dashed/open are openings to other rooms - NOT walls; never
  put a run or window on them.
- w_m is always the x-extent (left-right on the drawing) and d_m the
  z-extent (top-bottom), for the room AND for the island."""

DESCRIBE_PROMPT = """\
You are a meticulous architectural surveyor. Describe this kitchen floor
plan drawing exhaustively and precisely, in metres. Do NOT design or
improve anything - report only what is actually drawn.

Cover, with measurements:
1. Overall room width (left-right) and depth (top-bottom). Use the printed
   dimension arrows verbatim; convert feet/inches to metres.
2. Each edge of the room (top/bottom/left/right): solid wall, or
   dashed/open (dashed means open to another space - NOT a wall).
3. Every counter/cabinet run: which edge it sits against, where it starts
   and ends measured from the top-left inside corner of the room, and its
   depth. Note tall/pantry units separately - they are NOT appliances.
4. Every appliance symbol: sink basins, cooktop (circles = burners),
   fridge (box marked REF, often dashed), oven. For each: which counter it
   is on and the centre position in metres.
5. Any freestanding or attached counter (island / peninsula / bar): the
   exact rectangle (top-left corner position, then width = left-right
   extent, depth = top-bottom extent), whether it is attached to a wall or
   a run, which side stools/overhang are drawn on, and whether the cooktop
   is on it.
6. Windows and door openings: which wall, centre position, width.
7. Any printed text, labels or clearance notes, verbatim.
8. Walkway widths between counters where the drawing shows them.

Write a numbered list. Numbers in metres with two decimals.
"""

PLAN_PROMPT = """\
You are a kitchen layout planner. Below is a surveyor's description of a
kitchen floor-plan drawing. Convert it into the JSON schema at the end.
Return JSON ONLY - no prose, no markdown fences.

Rules:
- Use the surveyor's measurements. Never invent runs, appliances or walls
  the surveyor did not report.
""" + SENSES + """
- Sanity-check before answering: counters are ~0.6 m deep; people need
  at least 0.9 m of walkway between facing counters and around islands;
  the island rectangle must not overlap any run. Prefer the printed
  clearances the surveyor quoted.

Coordinate system: origin is the TOP-LEFT inside corner of the room.
x runs right (metres), z runs down (metres). Walls: north = top edge,
south = bottom, west = left, east = right. Positions along north/south
walls are x metres; along east/west walls are z metres, both measured
from that wall's origin end (west end for N/S, north end for E/W).
The fridge is "start" when it sits at the run's origin end, "end"
otherwise. x_m,z_m are the island's top-left corner.

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

Choose the palette that suits the description: warm_walnut for
classic/family homes, light_oak for bright/small/modern spaces,
dark_modern for premium/contemporary.

Surveyor's description:
"""


OPENAI_ENDPOINT = "https://api.openai.com/v1/chat/completions"


def call_api(model, key, messages, max_tokens=4096, timeout=75):
    # gpt-* models route to OpenAI (OPENAI_API_KEY); GPT-5.x wants
    # max_completion_tokens and rejects non-default temperature
    openai = model.startswith("gpt-")
    if openai:
        key = os.environ.get("OPENAI_API_KEY", key)
    payload = {"model": model, "messages": messages}
    if openai:
        payload["max_completion_tokens"] = 16384
    else:
        payload["max_tokens"] = max_tokens
        payload["temperature"] = 0.2
    body = json.dumps(payload).encode()
    req = urllib.request.Request(OPENAI_ENDPOINT if openai else ENDPOINT,
                                 data=body, method="POST")
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read())
        choice = data["choices"][0]
        content = choice["message"]["content"] or ""
        # some reasoning models put the answer in reasoning_content
        if not content.strip():
            content = choice["message"].get("reasoning_content") or ""
        return {"ok": True, "secs": time.time() - t0, "text": content,
                "finish": choice.get("finish_reason")}
    except Exception as e:  # noqa: BLE001 - benchmark records all failures
        return {"ok": False, "secs": time.time() - t0,
                "error": f"{type(e).__name__}: {e}"[:160]}


def main():
    key = os.environ.get("NVIDIA_API_KEY", "")
    if not key:
        sys.exit("set NVIDIA_API_KEY")
    truths = json.loads((OUT / "truths.json").read_text())

    # ---------------- stage 1: one description per drawing (cached) -------
    descriptions = {}
    for t in truths:
        cache = OUT / f"describe_{t['name']}.txt"
        if cache.exists() and cache.stat().st_size > 200:
            descriptions[t["name"]] = cache.read_text()
            print(f"stage1 {t['name']}: cached ({cache.stat().st_size} B)")
            continue
        img64 = base64.b64encode(prep_image(OUT / f"{t['name']}.png")).decode()
        r = None
        for attempt in range(2):  # free tier hiccups - one retry
            r = call_api(VISION_MODEL, key, [{
                "role": "user",
                "content": [
                    {"type": "text", "text": DESCRIBE_PROMPT},
                    {"type": "image_url",
                     "image_url": {"url": f"data:image/jpeg;base64,{img64}"}},
                ],
            }], max_tokens=8192)
            if r["ok"]:
                break
            print(f"stage1 {t['name']} attempt {attempt + 1} failed: "
                  f"{r['error']}")
            time.sleep(3)
        if not r["ok"]:
            print(f"stage1 {t['name']}: SKIPPED (describe failed twice)")
            continue
        descriptions[t["name"]] = r["text"]
        cache.write_text(r["text"])
        print(f"stage1 {t['name']}: {r['secs']:.0f}s, "
              f"{len(r['text'])} chars")
        time.sleep(1.5)

    # ---------------- stage 2: every text model per description -----------
    results = {}
    for model in TEXT_MODELS:
        row = {"scores": [], "secs": [], "sigs": [], "fails": []}
        for t in truths:
            if t["name"] not in descriptions:
                continue  # describe stage skipped this drawing
            r = call_api(model, key, [{
                "role": "user",
                "content": PLAN_PROMPT + descriptions[t["name"]],
            }], max_tokens=8192, timeout=75)
            tag = f"two_{model.replace('/', '_')}_{t['name']}"
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
            time.sleep(1.5)
        results[model] = row
        avg = sum(row["scores"]) / len(row["scores"])
        print(f"{model:48s} avg {avg:5.1f}  "
              f"scores {['%.0f' % s for s in row['scores']]}  "
              f"secs {['%.0f' % s for s in row['secs']]}  "
              f"fails {len(row['fails'])}")
        for f in row["fails"]:
            print(f"      ! {f}")

    (OUT / "bench_two_stage.json").write_text(json.dumps(
        {m: {k: (v if k != "sigs" else [str(s) for s in v])
             for k, v in row.items()} for m, row in results.items()},
        indent=1))
    print("\nwrote bench_two_stage.json")


if __name__ == "__main__":
    main()
