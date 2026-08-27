#!/usr/bin/env python3
"""
Matbakhak b35 - cut-list engine prototype (validated FIRST, then ported
to lib/services/cut_list.dart with these numbers FROZEN).

From a LayoutPlan (+ design choices) to the factory floor:
 1. CABINETS  - runs are broken into cabinet modules using the SAME
    door_bays() the renderer uses (a 0.60 m module per door bay).
 2. PARTS     - every module becomes its panel list (sides, bottom, top
    rails, shelf, back, door, plinth) in real mm, on real materials:
      mfc18 - melamine-faced chipboard 18 mm, 2440 x 1220 (the global
              workhorse carcass sheet)
      mdf18 - MDF 18 mm for shaker doors (painted)
      hdf3  - 3 mm HDF backs
 3. NESTING   - shelf-packing (first-fit decreasing, rotation allowed,
    4 mm kerf) onto standard sheets -> boards to buy per material.
 4. HARDWARE  - hinges/legs/brackets/handles/push catches/gola profile.
 5. WORKTOP   - linear metres per worktop class from standard blanks.
 6. PRICE     - default JOD rate card x manufacture factor, +/-10 % band
    (every workshop calibrates the card to its own suppliers).

Sheet/thickness standards researched 2026-08: 2440x1220 (4x8) MFC is the
industry stock size, 18 mm carcass, 3-6 mm backs; laminate worktop
blanks 3000-4100 x 600-635 x 38 mm.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from design_studio_proto import door_bays  # noqa: E402  (shared bays!)

MM = 1000.0

# ---- sheet stock + rate card (JOD) - the calibration surface -------------
SHEETS = {
    "mfc18": {"w": 2440, "h": 1220, "price": 23.0,
              "label": "Melamine chipboard 18 mm"},
    "mdf18": {"w": 2440, "h": 1220, "price": 30.0, "label": "MDF 18 mm"},
    "hdf3":  {"w": 2440, "h": 1220, "price": 8.0,  "label": "HDF back 3 mm"},
}
KERF = 4          # saw blade width, mm
SHEET_TRIM = 10   # unusable edge per side, mm

HARDWARE_PRICES = {
    "hinge": 1.8,        # soft-close concealed, each
    "leg": 0.45,         # adjustable plinth leg
    "bracket": 0.8,      # upper-cabinet hanging bracket
    "handle_bar": 3.5,
    "handle_knob": 2.5,
    "push_catch": 1.6,   # push-to-open magnetic catch, per door
    "gola_profile_m": 12.0,  # hidden-handle aluminium rail, per metre
}
EDGING_PER_M = 0.30      # 0.4 mm ABS edge banding applied, per metre
WORKTOP_PER_M = {        # 600-635 mm deep, per linear metre supplied+cut
    "laminate": 28.0, "wood": 45.0, "engineered": 60.0,
    "concrete": 55.0, "granite": 70.0, "quartz": 85.0,
}
SPLASH_PER_M2 = 18.0
MANUFACTURE_FACTOR = 1.7   # cutting + edging + assembly + install + margin
ESTIMATE_BAND = 0.10       # +/-10 % - stated to the customer

WORKTOP_CLASS = {          # design worktop option id -> price class
    "basalt_quartz": "engineered", "white_quartz": "quartz",
    "black_granite": "granite", "grey_concrete": "concrete",
    "marble_veined": "quartz", "butcher_block": "wood",
}

# carcass geometry (mm) - mirrors the generator's frozen dimensions
BASE_H, BASE_D = 760, 580     # carcass under the 860 counter, on 100 legs
UPPER_H, UPPER_D = 700, 330
TALL_H, TALL_D = 2100, 580


def _mm(v):
    return round(v * MM)


def base_cabinet_parts(w_mm, door_mat, sink=False):
    """One base module: sides, bottom, rails, shelf, back, door."""
    parts = [
        ("side", "mfc18", BASE_D, BASE_H, 2, (BASE_H / MM)),
        ("bottom", "mfc18", w_mm - 36, BASE_D, 1, (w_mm - 36) / MM),
        ("top rail", "mfc18", w_mm - 36, 100, 2, 0),
    ]
    if not sink:
        parts.append(("shelf", "mfc18", w_mm - 36, 500, 1, (w_mm - 36) / MM))
        parts.append(("back", "hdf3", w_mm - 20, 740, 1, 0))
    parts.append(("door", door_mat, w_mm - 4, 740, 1,
                  2 * ((w_mm - 4) + 740) / MM))
    return parts


def upper_cabinet_parts(w_mm, door_mat):
    return [
        ("side", "mfc18", UPPER_D, UPPER_H, 2, (UPPER_H / MM)),
        ("top/bottom", "mfc18", w_mm - 36, UPPER_D, 2, (w_mm - 36) / MM),
        ("shelf", "mfc18", w_mm - 36, 280, 1, (w_mm - 36) / MM),
        ("back", "hdf3", w_mm - 20, 680, 1, 0),
        ("door", door_mat, w_mm - 4, 684, 1, 2 * ((w_mm - 4) + 684) / MM),
    ]


def tall_cabinet_parts(w_mm, door_mat):
    return [
        ("side", "mfc18", TALL_D, TALL_H, 2, 2 * (TALL_H / MM)),
        ("top/bottom", "mfc18", w_mm - 36, 560, 2, (w_mm - 36) / MM),
        ("shelf", "mfc18", w_mm - 36, 560, 2, (w_mm - 36) / MM),
        ("back", "hdf3", w_mm - 20, 2080, 1, 0),
        ("door low", door_mat, w_mm - 4, 1180, 1,
         2 * ((w_mm - 4) + 1180) / MM),
        ("door high", door_mat, w_mm - 4, 880, 1,
         2 * ((w_mm - 4) + 880) / MM),
    ]


def build_bom(plan, design):
    """LayoutPlan + design -> cabinets, parts, hardware, worktop metres."""
    door_mat = "mdf18" if design.get("door") == "shaker" else "mfc18"
    handle = design.get("handle", "bar")
    parts = []        # (name, material, w, h, qty, edging_m)
    hardware = {k: 0 for k in
                ("hinge", "leg", "bracket", "handle", "push_catch")}
    cabinets = []     # (kind, w_mm)
    notes = []
    worktop_m = 0.0
    splash_m2 = 0.0
    gola_m = 0.0
    plinth_m = 0.0

    def count_door_hw(n_doors, tall=False):
        hardware["hinge"] += n_doors * (3 if tall else 2)
        if handle in ("bar", "knob"):
            hardware["handle"] += n_doors
        elif handle == "push":
            hardware["push_catch"] += n_doors

    for r in plan["runs"]:
        a, b = r["a"], r["b"]
        if r.get("fridge") == "start":
            a += 0.80
        elif r.get("fridge") == "end":
            b -= 0.80
        if r.get("fridge"):
            notes.append("fridge space reserved - appliance by customer")
        if r.get("tall"):
            for ba, bb, has_door in door_bays(r["a"], r["b"]):
                w = _mm(bb - ba)
                if not has_door:
                    parts.append(("filler", "mfc18", w, TALL_H, 1, TALL_H / MM))
                    continue
                cabinets.append(("tall", w))
                parts += tall_cabinet_parts(w, door_mat)
                count_door_hw(1, tall=True)   # low door, 3 hinges
                count_door_hw(1)              # high door, 2 hinges
                hardware["leg"] += 4
            continue
        if b - a < 0.7:
            continue
        counter_len = b - a
        worktop_m += counter_len
        splash_m2 += counter_len * 0.56
        plinth_m += counter_len
        if handle == "gola":
            gola_m += counter_len
        for ba, bb, has_door in door_bays(a, b):
            w = _mm(bb - ba)
            mid = (ba + bb) / 2
            if not has_door:
                parts.append(("filler", "mfc18", w, BASE_H, 1, BASE_H / MM))
                continue
            if r.get("rangeAt") is not None and abs(mid - r["rangeAt"]) < 0.42:
                notes.append("cooker gap - freestanding cooker by customer")
                continue
            sink = r.get("sinkAt") is not None and abs(mid - r["sinkAt"]) < 0.34
            cabinets.append(("sink base" if sink else "base", w))
            parts += base_cabinet_parts(w, door_mat, sink=sink)
            count_door_hw(1)
            hardware["leg"] += 4
        if r.get("uppers"):
            for ba, bb, has_door in door_bays(a + 0.02, b - 0.02):
                w = _mm(bb - ba)
                if not has_door:
                    continue
                cabinets.append(("upper", w))
                parts += upper_cabinet_parts(w, door_mat)
                count_door_hw(1)
                hardware["bracket"] += 2

    isl = plan.get("island")
    if isl:
        iw = isl["w"]
        worktop_m += iw + 0.10
        plinth_m += iw
        if handle == "gola":
            gola_m += iw
        for ba, bb, has_door in door_bays(0.0, iw):
            w = _mm(bb - ba)
            if not has_door:
                parts.append(("filler", "mfc18", w, BASE_H, 1, BASE_H / MM))
                continue
            cabinets.append(("island base", w))
            parts += base_cabinet_parts(w, door_mat)
            count_door_hw(1)
            hardware["leg"] += 4
        parts.append(("island back skin", "mfc18", _mm(iw), BASE_H, 1,
                      iw))

    # plinth is cut in sheet-length segments (a 7 m strip is not a part)
    remaining = _mm(plinth_m)
    seg = SHEETS_W - 2 * SHEET_TRIM - KERF
    while remaining > 0:
        cut = min(remaining, seg)
        parts.append(("plinth", "mfc18", cut, 100, 1, cut / MM))
        remaining -= cut
    return {
        "cabinets": cabinets, "parts": parts, "hardware": hardware,
        "worktop_m": worktop_m, "splash_m2": splash_m2, "gola_m": gola_m,
        "notes": sorted(set(notes)),
    }


# ---- nesting: shelf packing, first-fit decreasing, rotation allowed ------
def nest(parts):
    """parts (filtered to one material) -> number of sheets + utilization."""
    usable_w = SHEETS_W - 2 * SHEET_TRIM
    usable_h = SHEETS_H - 2 * SHEET_TRIM
    pieces = []
    for name, _mat, w, h, qty, _e in parts:
        for _ in range(qty):
            lo, hi = sorted((w, h))
            if hi > max(usable_w, usable_h) or lo > min(usable_w, usable_h):
                raise ValueError(f"part {name} {w}x{h} exceeds the sheet")
            pieces.append((lo, hi, name))
    # tallest-shelf-first: sort by the short dim descending
    pieces.sort(key=lambda p: (p[0], p[1]), reverse=True)
    sheets = []  # each: list of shelves [used_w, shelf_h]
    for lo, hi, _name in pieces:
        # orient long side along the shelf (w=hi, h=lo)
        w, h = hi, lo
        placed = False
        for shelves in sheets:
            for sh in shelves:
                if sh[1] >= h + KERF and usable_w - sh[0] >= w + KERF:
                    sh[0] += w + KERF
                    placed = True
                    break
            if placed:
                break
            used_h = sum(s[1] for s in shelves)
            if usable_h - used_h >= h + KERF:
                shelves.append([w + KERF, h + KERF])
                placed = True
                break
        if not placed:
            sheets.append([[w + KERF, h + KERF]])
    area = sum(w * h for w, h, _n in
               ((p[1], p[0], p[2]) for p in pieces))
    total = len(sheets) * SHEETS_W * SHEETS_H
    return len(sheets), (area / total if total else 0.0)


SHEETS_W, SHEETS_H = 2440, 1220


def price_bom(bom, design):
    boards = {}
    util = {}
    for mat in SHEETS:
        mat_parts = [p for p in bom["parts"] if p[1] == mat]
        if not mat_parts:
            continue
        n, u = nest(mat_parts)
        boards[mat] = n
        util[mat] = u
    edging_m = sum(p[5] * p[4] for p in bom["parts"])
    hw = bom["hardware"]
    handle_price = HARDWARE_PRICES[
        "handle_knob" if design.get("handle") == "knob" else "handle_bar"]
    materials = (
        sum(SHEETS[m]["price"] * n for m, n in boards.items())
        + edging_m * EDGING_PER_M
        + bom["worktop_m"] * WORKTOP_PER_M[
            WORKTOP_CLASS.get(design.get("worktop", "basalt_quartz"),
                              "engineered")]
        + bom["splash_m2"] * SPLASH_PER_M2
        + bom["gola_m"] * HARDWARE_PRICES["gola_profile_m"]
        + hw["hinge"] * HARDWARE_PRICES["hinge"]
        + hw["leg"] * HARDWARE_PRICES["leg"]
        + hw["bracket"] * HARDWARE_PRICES["bracket"]
        + hw["handle"] * handle_price
        + hw["push_catch"] * HARDWARE_PRICES["push_catch"]
    )
    total = materials * MANUFACTURE_FACTOR
    return {
        "boards": boards, "utilization": util, "edging_m": edging_m,
        "materials": materials, "total": total,
        "low": total * (1 - ESTIMATE_BAND),
        "high": total * (1 + ESTIMATE_BAND),
    }


# ---- validation -----------------------------------------------------------
def demo_plan():
    return {
        "w": 4.2, "d": 3.4,
        "runs": [
            {"wall": "north", "a": 0.82, "b": 4.15, "sinkAt": 1.71,
             "rangeAt": 3.17, "fridge": None, "uppers": True},
            {"wall": "west", "a": 0.02, "b": 3.06, "sinkAt": None,
             "rangeAt": None, "fridge": "start", "uppers": True},
        ],
        "island": {"x0": 1.2, "z0": 1.5, "w": 1.6, "d": 0.9,
                   "seating": "south", "cooktop": False},
        "windows": [],
    }


def main():
    design = {"worktop": "basalt_quartz", "handle": "bar", "door": "slab"}
    bom = build_bom(demo_plan(), design)
    est = price_bom(bom, design)
    kinds = {}
    for k, w in bom["cabinets"]:
        kinds[k] = kinds.get(k, 0) + 1
    print("cabinets:", kinds)
    print("hardware:", bom["hardware"])
    print(f"worktop {bom['worktop_m']:.2f} m  splash {bom['splash_m2']:.2f} m2"
          f"  edging {est['edging_m']:.1f} m")
    for m, n in est["boards"].items():
        print(f"  {SHEETS[m]['label']}: {n} sheets"
              f" (util {est['utilization'][m]*100:.0f}%)")
    print(f"materials {est['materials']:.0f} JOD -> total"
          f" {est['total']:.0f} JOD ({est['low']:.0f}-{est['high']:.0f})")

    # expectations
    n_base = kinds.get("base", 0) + kinds.get("sink base", 0)
    assert 4 <= n_base <= 8, f"base cabinet count {n_base} implausible"
    assert kinds.get("upper", 0) >= 4, "uppers expected on both runs"
    assert kinds.get("island base", 0) >= 2, "island modules expected"
    assert bom["hardware"]["hinge"] >= 2 * (n_base + kinds["upper"]), "hinges"
    assert est["boards"]["mfc18"] >= 3, "carcass sheets implausibly few"
    assert est["boards"]["hdf3"] >= 1
    for m, u in est["utilization"].items():
        assert 0.35 <= u <= 0.95, f"{m} utilization {u:.2f} out of range"
    assert 1500 <= est["total"] <= 6000, f"total {est['total']:.0f} sanity"

    # push-to-open + gola variants price differently
    est_push = price_bom(build_bom(demo_plan(),
                                   {"handle": "push", "door": "slab"}),
                         {"handle": "push"})
    est_gola = price_bom(build_bom(demo_plan(),
                                   {"handle": "gola", "door": "slab"}),
                         {"handle": "gola"})
    assert est_push["total"] != est["total"]
    assert est_gola["total"] > est_push["total"], "gola rail costs more"
    print("\nall cut-list expectations hold")


if __name__ == "__main__":
    main()
