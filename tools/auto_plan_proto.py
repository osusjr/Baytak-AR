#!/usr/bin/env python3
"""
Auto-planner prototype (build 36) - the wizard's on-device kitchen designer:
bare room dimensions -> a complete, buildable LayoutPlan, instantly and
without an AI call. Validated here first, then ported to Dart
(lib/services/auto_planner.dart) with these rules FROZEN.

Design rules (researched kitchen-planning practice - IKEA planner guide,
NKBA work-triangle guidelines - expressed in the app's own normalizer
constants so every emitted plan is ALREADY normal form):

  Layout choice (showroom taste: an island outranks a third wall):
    1. U-shape + island   when U fits (w>=3.2, d>=3.0) and an island fits
    2. L-shape + island   when L fits (w>=2.6, d>=2.2) and an island fits
    3. U-shape            when w>=3.2 and d>=3.0
    4. L-shape            when w>=2.6 and d>=2.2
    5. Galley             when w>=2.3 (aisle >= 0.99) and d>=2.4
    6. Single wall        otherwise (corridor / kitchenette rooms)

  Work triangle: fridge lands at the OPEN end of the west run (next to
  the room entry), the sink centres on the north wall under a window,
  the cooker goes to the east wall (U) or shares the north run (L,
  capped 2 m from the sink). Galley: sink+fridge west, cooker east.

  Tall pantry (d >= 3.4, L and U): the west wall becomes the classic
  tall bank - pantry column at the north corner, counter + fridge below.
  Tall and base are SEPARATE touching runs (the b30 kind-split keeps
  them from merging).

  Island: auto-sized to the free floor rect with 0.90 m walkways on all
  four sides (> the normalizer's 0.85 minimum so the island pass never
  moves it), capped 2.4 m, dropped under 1.2 m.

Validation: every plan across a 2.2-8.0 x 1.8-8.0 m sweep (0.1 m steps,
~3.7k rooms) must pass plan_normalizer_proto.normalize_plan with ZERO
notes and ZERO geometry drift - the auto-planner emits exactly what the
normalizer would keep.
"""

import copy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import plan_normalizer_proto as pnp  # noqa: E402

# ---- frozen rule constants (port these verbatim) ---------------------------
U_MIN_W = 3.2        # U-shape needs this width (aisle 3.2-1.31 = 1.89)
U_MIN_D = 3.0
L_MIN_W = 2.6        # matches the manual card's validation since v17
L_MIN_D = 2.2
GALLEY_MIN_W = 2.3   # aisle w - 2*0.655 >= 0.99
GALLEY_MIN_D = 2.4
SIDE_END = 0.12      # side runs stop this short of the open edge
TALL_MIN_D = 3.4     # room depth needed for the west tall bank
TALL_W = 0.60        # pantry column width
ISLAND_MARGIN = 0.90 # walkway kept on every island side (> WALKWAY 0.85)
ISLAND_W_MAX = 2.40
ISLAND_W_MIN = 1.20
ISLAND_D = 0.90
WINDOW_W = 1.10
SINK_HALF = 0.34     # sink cutout half-width (generator constant)

CLEAR_COUNTER = pnp.CLEAR_COUNTER  # 0.67
FRIDGE_SPAN = pnp.FRIDGE_SPAN      # 0.8
FRIDGE_D = pnp.FRIDGE_D            # 0.75
COUNTER_D = pnp.COUNTER_D          # 0.655
EDGE_MARGIN = pnp.EDGE_MARGIN      # 0.45
MIN_SEP = pnp.MIN_SEP              # 0.95


def _run(wall, a, b, sink=None, rng=None, fridge=None, uppers=True,
         tall=False):
    return {"wall": wall, "a": a, "b": b, "sinkAt": sink, "rangeAt": rng,
            "fridge": fridge, "uppers": uppers, "tall": tall,
            "auto": False, "origA": a, "origB": b}


def _clamp(v, lo, hi):
    return min(max(v, lo), hi)


def _appliance_window(a, b, fridge):
    """Legal sink/range band on a run, pre-applying the normalizer's
    pass-4 margins so emitted positions are never silently re-clamped."""
    if fridge == "start":
        a += FRIDGE_SPAN
    elif fridge == "end":
        b -= FRIDGE_SPAN
    return a + EDGE_MARGIN, b - EDGE_MARGIN


def _west_bank(d, allow_tall):
    """West wall composition shared by L and U: optional pantry column at
    the north corner, then the counter run with the fridge at the OPEN
    (south) end - next to where the client walks in."""
    runs = []
    a = CLEAR_COUNTER
    if allow_tall and d >= TALL_MIN_D:
        runs.append(_run("west", a, a + TALL_W, tall=True, uppers=False))
        a += TALL_W
    runs.append(_run("west", a, d - SIDE_END, fridge="end"))
    return runs


def _island_for(w, d, west_clear, east_clear, north_clear):
    """Island sized into the free floor rect with ISLAND_MARGIN on all
    sides; None when it would come out under ISLAND_W_MIN."""
    free_x0 = west_clear + ISLAND_MARGIN
    free_x1 = w - east_clear - ISLAND_MARGIN
    free_z0 = north_clear + ISLAND_MARGIN
    free_z1 = d - ISLAND_MARGIN
    iw = min(ISLAND_W_MAX, free_x1 - free_x0)
    if iw < ISLAND_W_MIN or free_z1 - free_z0 < ISLAND_D:
        return None
    return {"x0": free_x0 + (free_x1 - free_x0 - iw) / 2,
            "z0": free_z0 + (free_z1 - free_z0 - ISLAND_D) / 2,
            "w": iw, "d": ISLAND_D,
            "seating": "south", "cooktop": False}


def auto_plan(w, d, allow_island=True, allow_tall=True,
              palette="warm_walnut"):
    """Room dimensions -> a complete plan in normal form (proto format)."""
    u_ok = w >= U_MIN_W and d >= U_MIN_D
    l_ok = w >= L_MIN_W and d >= L_MIN_D
    # side-wall clearances used for island fitting (fridge run rect is
    # 0.75 deep in the normalizer's island pass)
    isl_u = _island_for(w, d, FRIDGE_D, COUNTER_D, COUNTER_D) \
        if allow_island else None
    isl_l = _island_for(w, d, FRIDGE_D, 0.0, COUNTER_D) \
        if allow_island else None

    if u_ok and isl_u:
        layout, island = "U-shape", isl_u
    elif l_ok and isl_l:
        layout, island = "L-shape", isl_l
    elif u_ok:
        layout, island = "U-shape", None
    elif l_ok:
        layout, island = "L-shape", None
    elif w >= GALLEY_MIN_W and d >= GALLEY_MIN_D:
        layout, island = "Galley", None
    else:
        layout, island = "Single wall", None

    runs, windows = [], []
    tall = False
    if layout in ("U-shape", "L-shape"):
        # north showcase run, full width - sink under the window
        na, nb = 0.02, w - 0.02
        lo, hi = _appliance_window(na, nb, None)
        sink = _clamp(0.45 * w if layout == "U-shape" else 0.30 * w, lo, hi)
        rng = None
        if layout == "L-shape":
            # cooker shares the north run, capped 2 m from the sink
            rng = _clamp(min(sink + 2.0, na + 0.72 * (nb - na)),
                         sink + MIN_SEP, hi)
            if rng > hi:
                rng = None
        runs.append(_run("north", na, nb, sink=sink, rng=rng))
        windows.append({"wall": "north", "center": sink, "width": WINDOW_W})
        west = _west_bank(d, allow_tall)
        tall = any(r["tall"] for r in west)
        runs.extend(west)
        if layout == "U-shape":
            ea, eb = CLEAR_COUNTER, d - SIDE_END
            lo, hi = _appliance_window(ea, eb, None)
            runs.append(_run("east", ea, eb, rng=_clamp(0.45 * d, lo, hi)))
    elif layout == "Galley":
        wa, wb = 0.02, d - 0.02
        lo, hi = _appliance_window(wa, wb, "start")
        runs.append(_run("west", wa, wb, sink=_clamp(0.55 * d, lo, hi),
                         fridge="start"))
        lo, hi = _appliance_window(wa, wb, None)
        runs.append(_run("east", wa, wb, rng=_clamp(0.45 * d, lo, hi)))
        windows.append({"wall": "north",
                        "center": w / 2,
                        "width": min(WINDOW_W, w - 0.8)})
    else:  # single wall
        na, nb = 0.05, w - 0.05
        lo, hi = _appliance_window(na, nb, "end")
        if hi - lo >= MIN_SEP:
            sink = lo + 0.18 * (hi - lo - MIN_SEP)
            rng = min(hi, sink + max(MIN_SEP, 0.5 * (hi - lo)))
        else:
            sink, rng = (lo + hi) / 2, None
        runs.append(_run("north", na, nb, sink=sink, rng=rng, fridge="end"))
        windows.append({"wall": "north",
                        "center": _clamp(sink, 0.65, w - 0.65),
                        "width": min(WINDOW_W, w - 1.2)})

    bits = [layout]
    if island:
        bits.append("island")
    if tall:
        bits.append("pantry")
    return {"w": w, "d": d, "runs": runs, "island": island,
            "windows": windows,
            "summary": " + ".join(bits) + " - designed on this phone",
            "palette": palette}


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------
def _key(r):
    return (r["wall"], round(r["a"], 4))


def _geometry_drift(before, after):
    """Human-readable first difference between two plans, or None."""
    rb = sorted(before["runs"], key=_key)
    ra = sorted(after["runs"], key=_key)
    if len(rb) != len(ra):
        return f"run count {len(rb)} -> {len(ra)}"
    for x, y in zip(rb, ra):
        for k in ("wall", "fridge", "uppers", "tall"):
            if x.get(k) != y.get(k):
                return f"{x['wall']} run {k}: {x.get(k)} -> {y.get(k)}"
        for k in ("a", "b", "sinkAt", "rangeAt"):
            xv, yv = x.get(k), y.get(k)
            if (xv is None) != (yv is None):
                return f"{x['wall']} run {k}: {xv} -> {yv}"
            if xv is not None and abs(xv - yv) > 1e-6:
                return f"{x['wall']} run {k}: {xv:.3f} -> {yv:.3f}"
    ib, ia = before.get("island"), after.get("island")
    if (ib is None) != (ia is None):
        return f"island {'kept' if ib else 'none'} -> " \
               f"{'kept' if ia else 'dropped'}"
    if ib:
        for k in ("x0", "z0", "w", "d"):
            if abs(ib[k] - ia[k]) > 1e-6:
                return f"island {k}: {ib[k]:.3f} -> {ia[k]:.3f}"
        if ib["seating"] != ia["seating"]:
            return f"island seating {ib['seating']} -> {ia['seating']}"
    return None


def check_stable(plan, label):
    normalized = copy.deepcopy(plan)
    notes = pnp.normalize_plan(normalized)
    drift = _geometry_drift(plan, normalized)
    ok = not notes and drift is None
    if not ok:
        print(f"FAIL {label}: notes={notes} drift={drift}")
    return ok


def check_ergonomics(plan, label):
    """Rules the normalizer does not police but a client would notice."""
    w, d = plan["w"], plan["d"]
    ok = True

    def fail(msg):
        nonlocal ok
        ok = False
        print(f"FAIL {label}: {msg}")

    kinds = set()
    for r in plan["runs"]:
        if r["sinkAt"] is not None:
            kinds.add("sink")
        if r["rangeAt"] is not None:
            kinds.add("range")
        if r["fridge"]:
            kinds.add("fridge")
        # appliances respect the pass-4 margins by construction
        lo, hi = _appliance_window(r["a"], r["b"], r["fridge"])
        for k in ("sinkAt", "rangeAt"):
            if r.get(k) is not None and not (lo - 1e-9 <= r[k] <= hi + 1e-9):
                fail(f"{k} outside margins on {r['wall']}")
        if r["sinkAt"] is not None and r["rangeAt"] is not None \
                and abs(r["sinkAt"] - r["rangeAt"]) < MIN_SEP - 1e-9:
            fail("sink/range separation")
    if "fridge" not in kinds:
        fail("no fridge")
    if "sink" not in kinds:
        fail("no sink")
    # every kitchen at least 2.75 m wide must cook
    if "range" not in kinds and w >= 2.75:
        fail("no cooker in a cookable room")
    # aisles: facing runs keep a walkable gap
    walls = {r["wall"] for r in plan["runs"]}
    if {"west", "east"} <= walls and w - 2 * COUNTER_D < 0.98:
        fail("galley aisle too tight")
    isl = plan.get("island")
    if isl:
        for r in plan["runs"]:
            x0, z0, x1, z1 = pnp.run_rect(r, w, d)
            ix0, iz0 = isl["x0"], isl["z0"]
            ix1, iz1 = ix0 + isl["w"], iz0 + isl["d"]
            if z0 < iz1 and iz0 < z1:  # z-projections meet
                gap = ix0 - x1 if x1 <= ix0 else (
                    x0 - ix1 if x0 >= ix1 else -1)
                if -0.5 < gap < pnp.WALKWAY - 1e-9:
                    fail(f"island walkway vs {r['wall']} run")
            if x0 < ix1 and ix0 < x1:
                gap = iz0 - z1 if z1 <= iz0 else (
                    z0 - iz1 if z0 >= iz1 else -1)
                if -0.5 < gap < pnp.WALKWAY - 1e-9:
                    fail(f"island walkway vs {r['wall']} run")
    return ok


def sweep():
    fails = 0
    stats = {}
    for w10 in range(22, 81):
        for d10 in range(18, 81):
            w, d = w10 / 10, d10 / 10
            for allow_island in (True, False):
                for allow_tall in (True, False):
                    p = auto_plan(w, d, allow_island, allow_tall)
                    label = f"{w}x{d} isl={allow_island} tall={allow_tall}"
                    if not check_stable(p, label):
                        fails += 1
                    if not check_ergonomics(p, label):
                        fails += 1
                    if allow_island and allow_tall:
                        key = p["summary"].split(" - ")[0]
                        stats[key] = stats.get(key, 0) + 1
    total = 59 * 63 * 4
    print(f"\nsweep: {total} plans, {fails} failures")
    for k in sorted(stats, key=stats.get, reverse=True):
        print(f"  {k:28s} {stats[k]:5d} rooms")
    return fails == 0


def spot_cases():
    """Anchors a human can eyeball; K-01 must match the demo blueprint."""
    ok = True
    for (w, d), want in [
        ((4.2, 3.4), "L-shape + island + pantry"),   # the K-01 demo room
        ((5.2, 4.2), "U-shape + island + pantry"),
        ((3.3, 3.1), "U-shape"),
        ((2.5, 3.0), "Galley"),
        ((2.2, 1.8), "Single wall"),
        ((5.0, 1.9), "Single wall"),                 # corridor kitchen
    ]:
        p = auto_plan(w, d)
        got = p["summary"].split(" - ")[0]
        mark = "ok " if got == want else "FAIL"
        if got != want:
            ok = False
        print(f"{mark} {w} x {d} -> {got}")
        for r in p["runs"]:
            bits = [k for k in ("sinkAt", "rangeAt") if r[k] is not None]
            if r["fridge"]:
                bits.append(f"fridge:{r['fridge']}")
            if r["tall"]:
                bits.append("tall")
            print(f"      {r['wall']:5s} {r['a']:.2f}-{r['b']:.2f} "
                  f"{' '.join(bits)}")
        if p["island"]:
            i = p["island"]
            print(f"      island {i['w']:.2f}x{i['d']:.2f} at "
                  f"({i['x0']:.2f},{i['z0']:.2f})")
    return ok


if __name__ == "__main__":
    ok = spot_cases()
    ok = sweep() and ok
    print("ALL OK" if ok else "FAILURES")
    sys.exit(0 if ok else 1)
