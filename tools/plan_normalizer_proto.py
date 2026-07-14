#!/usr/bin/env python3
"""
Plan normalizer prototype (build 20) - the pure-logic pass that makes ANY
LayoutPlan buildable, run after AI parsing and after every drag edit.
Validated here first, then ported to Dart (lib/services/plan_normalizer.dart)
with these constants FROZEN.

Assumes the b20 unified coordinate convention: run u measured from the
WEST end on north/south walls, from the NORTH end on east/west walls
(same as the AI schema; the generator Frame was aligned to match).

Rules (in order):
 1. Runs clamped into their wall, degenerates dropped, same-wall overlaps
    merged. Fridge-only runs (length ~0.8) are legal.
 2. Corner pass - perpendicular runs must not overlap in plan:
      - a fridge slot is IMMOVABLE: the other run is trimmed to clear it
        (CLEAR_FRIDGE from the fridge's wall)
      - otherwise the east/west run yields to the north/south run
        (trimmed to CLEAR_COUNTER from the N/S wall)
      - a run trimmed under its minimum is dropped (never a fridge-only)
 3. Island pass - overlaps pulled back to touch, then per side: gap under
    ATTACH_EPS = attached (peninsula) but only ONE side may attach (the
    longest contact); every other side needs WALKWAY, enforced by
    shrinking. Below ISLAND_MIN in either dimension the island is dropped
    (fixes "counter covered the whole middle of the room").
 4. Appliances re-clamped into their (possibly trimmed) runs with the
    editor's margins; separation restored; range dropped if no room.

Wall choice (generator): only walls hosting runs/windows are built, and
never all four - the lowest-content wall is left open (max 3).
"""

import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import design_studio_proto as dsp  # noqa: E402

# ---- frozen constants (port these verbatim) --------------------------------
COUNTER_D = 0.655      # counter overhang depth (= Dart _cd)
FRIDGE_D = 0.75        # fridge box depth
FRIDGE_SPAN = 0.8      # fridge width along the run
CLEAR_FRIDGE = 0.82    # perpendicular run keeps this far from a fridge wall
CLEAR_COUNTER = 0.67   # E/W run keeps this far from an occupied N/S corner
WALKWAY = 0.85         # min island clearance on a non-attached side
ATTACH_EPS = 0.10      # gap below this = peninsula attachment, allowed
ISLAND_MIN = 0.60      # island dropped if thinner than this after shrink
MIN_RUN = 0.90         # min counter run length
FRIDGE_ONLY_LEN = 0.80 # exact length of a fridge-only run
FRIDGE_ONLY_EPS = 0.05
EDGE_MARGIN = 0.45     # sink/range centre distance from run ends
MIN_SEP = 0.95         # sink<->range separation


def axis_max(wall, w, d):
    return w if wall in ("north", "south") else d


def run_rect(r, w, d):
    """Plan-space rect (x0,z0,x1,z1) of a run incl. its fridge depth.
    Unified convention: u is x from west (N/S) or z from north (E/W)."""
    depth = FRIDGE_D if r.get("fridge") else COUNTER_D
    a, b = r["a"], r["b"]
    if r["wall"] == "north":
        return (a, 0.0, b, depth)
    if r["wall"] == "south":
        return (a, d - depth, b, d)
    if r["wall"] == "west":
        return (0.0, a, depth, b)
    return (w - depth, a, w, b)  # east


def fridge_rect(r, w, d):
    """Plan-space rect of just the fridge slot, or None."""
    if not r.get("fridge"):
        return None
    a, b = r["a"], r["b"]
    fa, fb = (a, a + FRIDGE_SPAN) if r["fridge"] == "start" \
        else (b - FRIDGE_SPAN, b)
    if r["wall"] == "north":
        return (fa, 0.0, fb, FRIDGE_D)
    if r["wall"] == "south":
        return (fa, d - FRIDGE_D, fb, d)
    if r["wall"] == "west":
        return (0.0, fa, FRIDGE_D, fb)
    return (w - FRIDGE_D, fa, w, fb)  # east


def rects_overlap(p, q, eps=0.01):
    return (p[0] < q[2] - eps and q[0] < p[2] - eps and
            p[1] < q[3] - eps and q[1] < p[3] - eps)


def min_len(r):
    return FRIDGE_ONLY_LEN - FRIDGE_ONLY_EPS if r.get("fridge") else MIN_RUN


def _trim_run_to_clear(r, blk_a, blk_b):
    """Trim run r so [a,b] avoids the world-axis band [blk_a,blk_b]
    (unified convention: run coords ARE world-axis coords).
    Returns False if r must be dropped."""
    a, b = r["a"], r["b"]
    if blk_b <= a + 1e-9 or blk_a >= b - 1e-9:
        return True
    keep_lo = (a, min(b, blk_a))
    keep_hi = (max(a, blk_b), b)
    best = keep_lo if (keep_lo[1] - keep_lo[0]) >= (keep_hi[1] - keep_hi[0]) \
        else keep_hi
    if best[1] - best[0] < min_len(r) - 1e-9:
        return False
    r["a"], r["b"] = best
    return True


def normalize_plan(plan):
    """Mutates plan (proto format: w,d,runs[a,b,...],island,windows) into a
    buildable one. Returns a list of human-readable fix notes."""
    notes = []
    w, d = plan["w"], plan["d"]

    # ---- 1. clamp, drop degenerates, merge same-wall overlaps ------------
    runs = []
    for r in plan["runs"]:
        if r.get("auto") and r.get("sinkAt") is None and \
                r.get("rangeAt") is None and not r.get("fridge"):
            # editor-created run whose appliance moved away
            notes.append("removed auto run left behind by a moved appliance")
            continue
        m = axis_max(r["wall"], w, d)
        r["a"] = min(max(r["a"], 0.02), m - 0.02)
        r["b"] = min(max(r["b"], 0.02), m - 0.02)
        if r["b"] - r["a"] >= min_len(r) - 1e-9:
            runs.append(r)
        else:
            notes.append(f"dropped degenerate run on {r['wall']}")
    merged = []
    for r in sorted(runs, key=lambda x: (x["wall"], x["a"])):
        prev = merged[-1] if merged and merged[-1]["wall"] == r["wall"] else None
        # runs that merely TOUCH at a fridge slot stay separate - that gap
        # IS the fridge (the editor's mid-run split); overlapping runs and
        # plain touching counters merge
        fridge_at_seam = prev is not None and (
            prev.get("fridge") == "end" or r.get("fridge") == "start")
        touching = prev is not None and r["a"] >= prev["b"] - 0.01
        if prev and r["a"] <= prev["b"] + 0.05 and \
                not (touching and fridge_at_seam):
            prev["b"] = max(prev["b"], r["b"])
            for k in ("sinkAt", "rangeAt"):
                if prev.get(k) is None and r.get(k) is not None:
                    prev[k] = r[k]
            if not prev.get("fridge") and r.get("fridge"):
                prev["fridge"] = r["fridge"]
            prev["uppers"] = prev.get("uppers", False) or r.get("uppers", False)
            # a merge containing ANY original cabinets is not disposable
            prev["auto"] = prev.get("auto", False) and r.get("auto", False)
            notes.append(f"merged overlapping runs on {r['wall']}")
        else:
            merged.append(r)
    plan["runs"] = merged

    # ---- 2. corner pass ---------------------------------------------------
    survivors = []
    for r in plan["runs"]:
        ok = True
        for other in plan["runs"]:
            if other is r or not ok:
                continue
            horiz_r = r["wall"] in ("north", "south")
            horiz_o = other["wall"] in ("north", "south")
            if horiz_r == horiz_o:
                continue  # parallel runs cannot corner-overlap
            if not rects_overlap(run_rect(r, w, d), run_rect(other, w, d)):
                continue
            m = axis_max(r["wall"], w, d)
            fr_o = fridge_rect(other, w, d)
            fr_r = fridge_rect(r, w, d)
            if fr_o and rects_overlap(run_rect(r, w, d), fr_o):
                # r must clear the fridge: blocked band reaches CLEAR_FRIDGE
                # out from other's wall, measured along r's axis
                band = (0.0, CLEAR_FRIDGE) \
                    if other["wall"] in ("north", "west") \
                    else (m - CLEAR_FRIDGE, m)
                ok = _trim_run_to_clear(r, *band)
                notes.append(f"trimmed {r['wall']} run clear of the fridge")
            elif fr_r and rects_overlap(run_rect(other, w, d), fr_r):
                pass  # the other run yields when the loop visits it
            elif not horiz_r:
                # plain counter corner: E/W yields to N/S
                band = (0.0, CLEAR_COUNTER) if other["wall"] == "north" \
                    else (d - CLEAR_COUNTER, d)
                ok = _trim_run_to_clear(r, *band)
                notes.append(f"trimmed {r['wall']} run at the "
                             f"{other['wall']} corner")
        if ok:
            survivors.append(r)
        else:
            notes.append(f"dropped {r['wall']} run - no room left")
    plan["runs"] = survivors

    # ---- 3. island pass ----------------------------------------------------
    isl = plan.get("island")
    if isl:
        x0, z0 = max(isl["x0"], 0.0), max(isl["z0"], 0.0)
        x1 = min(isl["x0"] + isl["w"], w)
        z1 = min(isl["z0"] + isl["d"], d)
        obstacles = [run_rect(r, w, d) for r in plan["runs"]]
        # walls that will exist are obstacles too (thin bands)
        for wl in walls_to_build(plan):
            if wl == "north":
                obstacles.append((0.0, -0.06, w, 0.0))
            elif wl == "south":
                obstacles.append((0.0, d, w, d + 0.06))
            elif wl == "west":
                obstacles.append((-0.06, 0.0, 0.0, d))
            else:
                obstacles.append((w, 0.0, w + 0.06, d))

        # pass A: pull overlapping edges back to touching
        for ob in obstacles:
            ox0, oz0, ox1, oz1 = ob
            if not rects_overlap((x0, z0, x1, z1), ob):
                continue
            # pull back the island edge that intrudes least
            pulls = []
            if ox1 > x0 >= ox0 - 1e-9:
                pulls.append((ox1 - x0, "x0", ox1))
            if ox0 < x1 <= ox1 + 1e-9:
                pulls.append((x1 - ox0, "x1", ox0))
            if oz1 > z0 >= oz0 - 1e-9:
                pulls.append((oz1 - z0, "z0", oz1))
            if oz0 < z1 <= oz1 + 1e-9:
                pulls.append((z1 - oz0, "z1", oz0))
            if not pulls:  # island swallows the obstacle whole - shrink hard
                pulls = [(x1 - ox0, "x1", ox0)]
            _, edge, val = min(pulls)
            if edge == "x0":
                x0 = val
            elif edge == "x1":
                x1 = val
            elif edge == "z0":
                z0 = val
            else:
                z1 = val

        # pass B: classify sides, allow ONE attachment, enforce walkways
        def side_gaps():
            sides = {"x0": [], "x1": [], "z0": [], "z1": []}
            for ob in obstacles:
                ox0, oz0, ox1, oz1 = ob
                if z0 < oz1 and oz0 < z1:  # z-projections meet
                    if ox1 <= x0 + 1e-9:
                        sides["x0"].append((x0 - ox1,
                                            min(z1, oz1) - max(z0, oz0), ox1))
                    elif ox0 >= x1 - 1e-9:
                        sides["x1"].append((ox0 - x1,
                                            min(z1, oz1) - max(z0, oz0), ox0))
                if x0 < ox1 and ox0 < x1:  # x-projections meet
                    if oz1 <= z0 + 1e-9:
                        sides["z0"].append((z0 - oz1,
                                            min(x1, ox1) - max(x0, ox0), oz1))
                    elif oz0 >= z1 - 1e-9:
                        sides["z1"].append((oz0 - z1,
                                            min(x1, ox1) - max(x0, ox0), oz0))
            return sides

        sides = side_gaps()
        # nearest obstacle per side decides that side's state
        state = {}
        for side, entries in sides.items():
            if not entries:
                state[side] = ("free", 0.0, None)
                continue
            gap, contact, front = min(entries, key=lambda e: e[0])
            if gap < ATTACH_EPS:
                state[side] = ("attached", contact, front)
            elif gap < WALKWAY:
                state[side] = ("tight", contact, front)
            else:
                state[side] = ("free", contact, front)
        # attachments are fine on ADJACENT sides (corner peninsula) but an
        # OPPOSITE pair would bridge the room: keep the longer contact,
        # push the other side out to a walkway.
        demoted = set()
        for lo_side, hi_side in (("x0", "x1"), ("z0", "z1")):
            if state[lo_side][0] == "attached" and \
                    state[hi_side][0] == "attached":
                demoted.add(lo_side if state[lo_side][1] < state[hi_side][1]
                            else hi_side)
        for side, (kind, _c, front) in state.items():
            need_push = (kind == "tight") or \
                (kind == "attached" and side in demoted)
            if not need_push:
                continue
            if side == "x0":
                x0 = front + WALKWAY
            elif side == "x1":
                x1 = front - WALKWAY
            elif side == "z0":
                z0 = front + WALKWAY
            else:
                z1 = front - WALKWAY

        if x1 - x0 < ISLAND_MIN - 1e-9 or z1 - z0 < ISLAND_MIN - 1e-9:
            plan["island"] = None
            notes.append("dropped island - no walkable room for it")
        else:
            changed = (abs(x0 - isl["x0"]) > 1e-6 or
                       abs(z0 - isl["z0"]) > 1e-6 or
                       abs((x1 - x0) - isl["w"]) > 1e-6 or
                       abs((z1 - z0) - isl["d"]) > 1e-6)
            if changed:
                isl.update(x0=x0, z0=z0, w=x1 - x0, d=z1 - z0)
                notes.append("shrunk island to keep walkways clear")

    # ---- 4. appliance re-clamp ---------------------------------------------
    for r in plan["runs"]:
        a, b = r["a"], r["b"]
        if r.get("fridge") == "start":
            a += FRIDGE_SPAN
        elif r.get("fridge") == "end":
            b -= FRIDGE_SPAN
        lo, hi = a + EDGE_MARGIN, b - EDGE_MARGIN
        if hi <= lo:
            if r.get("sinkAt") is not None or r.get("rangeAt") is not None:
                notes.append(f"dropped appliances on tiny {r['wall']} run")
            r["sinkAt"] = r["rangeAt"] = None
            continue
        for k in ("sinkAt", "rangeAt"):
            if r.get(k) is not None:
                r[k] = min(max(r[k], lo), hi)
        s_, g_ = r.get("sinkAt"), r.get("rangeAt")
        if s_ is not None and g_ is not None and abs(s_ - g_) < MIN_SEP:
            below, above = s_ - MIN_SEP, s_ + MIN_SEP
            if below >= lo:
                r["rangeAt"] = below
            elif above <= hi:
                r["rangeAt"] = above
            else:
                r["rangeAt"] = None
                notes.append(f"dropped range on {r['wall']} - no room")
    return notes


def walls_to_build(plan):
    """Walls hosting runs/windows, capped at 3 (lowest content left open)."""
    score = {}
    for r in plan["runs"]:
        score[r["wall"]] = score.get(r["wall"], 0) + 2 * (r["b"] - r["a"])
    for win in plan.get("windows", []):
        score[win["wall"]] = score.get(win["wall"], 0) + win["width"]
    walls = set(score)
    if len(walls) == 4:
        walls.remove(min(score, key=score.get))
    return walls


# ---------------------------------------------------------------------------
# validation cases
# ---------------------------------------------------------------------------
def overlap_report(plan):
    """Invariant: no run/island rects overlap after normalize."""
    w, d = plan["w"], plan["d"]
    rects = [(f"run-{r['wall']}", run_rect(r, w, d)) for r in plan["runs"]]
    if plan.get("island"):
        i = plan["island"]
        rects.append(("island", (i["x0"], i["z0"], i["x0"] + i["w"],
                                 i["z0"] + i["d"])))
    bad = []
    for i in range(len(rects)):
        for j in range(i + 1, len(rects)):
            if rects_overlap(rects[i][1], rects[j][1], eps=0.02):
                bad.append(f"{rects[i][0]} x {rects[j][0]}")
    return bad


def ushape_truth():
    """The owner's real failing blueprint, as ground truth."""
    return {
        "w": 3.2, "d": 3.76,
        "runs": [
            {"wall": "west", "a": 0.1, "b": 2.74, "sinkAt": None,
             "rangeAt": None, "fridge": None, "uppers": True},
            {"wall": "east", "a": 0.1, "b": 2.24, "sinkAt": 1.15,
             "rangeAt": None, "fridge": "end", "uppers": True},
        ],
        "island": {"x0": 0.0, "z0": 2.74, "w": 1.69, "d": 1.02,
                   "seating": "south", "cooktop": True},
        "windows": [],
    }


def case_flood():
    """AI returned the middle-covering island (the reported bug)."""
    p = ushape_truth()
    p["island"] = {"x0": 0.4, "z0": 0.6, "w": 2.4, "d": 2.56,
                   "seating": "south", "cooktop": True}
    return p


def case_four_walls():
    """AI put runs on all four walls (mistral pathology)."""
    return {
        "w": 3.6, "d": 3.0,
        "runs": [
            {"wall": "north", "a": 0.1, "b": 3.5, "sinkAt": 0.9,
             "rangeAt": 2.6, "fridge": None, "uppers": True},
            {"wall": "south", "a": 0.1, "b": 3.5, "sinkAt": None,
             "rangeAt": None, "fridge": None, "uppers": False},
            {"wall": "east", "a": 0.1, "b": 2.9, "sinkAt": None,
             "rangeAt": None, "fridge": "start", "uppers": True},
            {"wall": "west", "a": 0.1, "b": 2.9, "sinkAt": None,
             "rangeAt": None, "fridge": None, "uppers": True},
        ],
        "island": None, "windows": [],
    }


def case_fridge_corner():
    """Fridge dragged into a corner already occupied by the other run."""
    return {
        "w": 4.2, "d": 3.4,
        "runs": [
            {"wall": "north", "a": 0.1, "b": 4.1, "sinkAt": 1.2,
             "rangeAt": 3.0, "fridge": "start", "uppers": True},
            # west run starts right at the top corner - overlaps the fridge
            {"wall": "west", "a": 0.1, "b": 3.3, "sinkAt": None,
             "rangeAt": None, "fridge": None, "uppers": True},
        ],
        "island": None, "windows": [],
    }


def case_fridge_only():
    """b20 free placement: fridge parked alone on a bare wall."""
    return {
        "w": 3.6, "d": 3.0,
        "runs": [
            {"wall": "north", "a": 0.1, "b": 3.5, "sinkAt": 0.9,
             "rangeAt": 2.6, "fridge": None, "uppers": True},
            {"wall": "west", "a": 1.2, "b": 2.0, "sinkAt": None,
             "rangeAt": None, "fridge": "start", "uppers": False},
        ],
        "island": None, "windows": [],
    }


def main():
    out = Path(__file__).resolve().parent / "normalizer_out"
    out.mkdir(exist_ok=True)
    d = dsp.design()
    cases = {
        "ushape_truth": ushape_truth(),
        "flood": case_flood(),
        "four_walls": case_four_walls(),
        "fridge_corner": case_fridge_corner(),
        "fridge_only": case_fridge_only(),
    }
    failures = 0
    for name, plan in cases.items():
        before = copy.deepcopy(plan)
        notes = normalize_plan(plan)
        bad = overlap_report(plan)
        walls = walls_to_build(plan)
        print(f"== {name}")
        for n in notes:
            print(f"   fix: {n}")
        print(f"   walls built: {sorted(walls)}")
        if plan.get("island"):
            i = plan["island"]
            print(f"   island: x{i['x0']:.2f} z{i['z0']:.2f} "
                  f"{i['w']:.2f}x{i['d']:.2f}")
        if bad:
            failures += 1
            print(f"   OVERLAPS REMAIN: {bad}")
        for tag, p in (("before", before), ("after", plan)):
            sc = dsp.build_plan_b20(p, d)
            mats = dsp.effective_mats(d)
            dsp.iso_render(sc, mats, out / f"{name}_{tag}.png",
                           f"{name} {tag}")
        (out / f"{name}_after.json").write_text(json.dumps(plan, indent=1))

    # expectations
    p = cases["flood"]
    if p.get("island"):
        i = p["island"]
        # whatever survives must leave a 0.85 walkway to the east run front
        east_front = 3.2 - FRIDGE_D
        assert i["x0"] + i["w"] <= east_front - WALKWAY + 1e-6, \
            "flood island must clear the east walkway"
    p = cases["four_walls"]
    assert len(walls_to_build(p)) == 3, "four walls must cap at 3"
    p = cases["fridge_corner"]
    west = next(r for r in p["runs"] if r["wall"] == "west")
    assert west["a"] >= CLEAR_FRIDGE - 1e-9, "west run must clear the fridge"
    p = cases["ushape_truth"]
    assert p.get("island") is not None, "true peninsula must survive"
    i = p["island"]
    assert abs(i["w"] - 1.69) < 0.02 and abs(i["d"] - 1.02) < 0.02, \
        "true peninsula must keep its drawn size"
    p = cases["fridge_only"]
    assert any(r.get("fridge") for r in p["runs"]), \
        "fridge-only run must survive"
    for name, plan in cases.items():
        assert not overlap_report(plan), f"{name} still overlaps"
    print("\nall expectations hold" if not failures else "\nFAILURES")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
