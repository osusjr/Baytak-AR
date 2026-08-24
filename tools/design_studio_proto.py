#!/usr/bin/env python3
"""
Baytak AR - Design Studio prototype (v17)
=========================================
Python mirror of the Dart plan-driven kitchen builder
(flutter_app/lib/services/kitchen_generator.dart) extended with the
element-based design system that powers the in-app "Design studio":

  * separate UPPER cabinet materials ('upper' / 'upper_door') so top and
    bottom cabinets can carry different finishes,
  * per-element colour slots: walls, floor, worktops, island top,
    backsplash, lower/upper/island cabinets, hardware,
  * handle styles: 'bar' (current brass bar), 'knob', 'none' (handleless),
  * door styles: 'slab' (current flat front), 'shaker' (framed panel),
  * curated finish option tables - the single source of truth that is
    ported verbatim to Dart (lib/services/kitchen_design.dart).

Per the project convention, all NEW geometry (knobs, shaker rails, the
upper-material split) is validated here FIRST; the coordinates below are
frozen and ported to Dart unchanged.

Outputs (to tools/out_design_proto/):
  design_<name>.glb  - one GLB per design in the validation matrix
  design_<name>.png  - isometric render for visual verification
plus a structural validation report on stdout.
"""

import json
import struct
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent / "out_design_proto"
OUT.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# Base materials - EXACT mirror of Dart _mats: rgb, metallic, roughness.
# NEW: 'upper' and 'upper_door' (default to the walnut values so existing
# palettes keep rendering identically when no design overrides them).
# ---------------------------------------------------------------------------
MATS = {
    "floor":       ((0.82, 0.76, 0.66), 0.0, 0.90),
    "wall":        ((0.91, 0.88, 0.82), 0.0, 0.95),
    "splash":      ((0.71, 0.77, 0.69), 0.0, 0.40),
    "walnut":      ((0.42, 0.28, 0.185), 0.0, 0.65),
    "walnut_door": ((0.48, 0.325, 0.215), 0.0, 0.60),
    "upper":       ((0.42, 0.28, 0.185), 0.0, 0.65),
    "upper_door":  ((0.48, 0.325, 0.215), 0.0, 0.60),
    "olive":       ((0.275, 0.325, 0.26), 0.0, 0.55),
    "olive_door":  ((0.315, 0.37, 0.30), 0.0, 0.50),
    "basalt":      ((0.15, 0.16, 0.17), 0.05, 0.35),
    "quartz":      ((0.90, 0.89, 0.86), 0.0, 0.30),
    "steel":       ((0.74, 0.75, 0.77), 0.95, 0.35),
    "brass":       ((0.78, 0.62, 0.33), 1.0, 0.30),
    "black":       ((0.055, 0.055, 0.065), 0.0, 0.50),
    "toe":         ((0.10, 0.09, 0.085), 0.0, 0.80),
    "glass":       ((0.60, 0.74, 0.82), 0.10, 0.10),
    "frame":       ((0.95, 0.95, 0.94), 0.0, 0.50),
    "wood":        ((0.55, 0.40, 0.27), 0.0, 0.60),
    "taupe":       ((0.66, 0.60, 0.53), 0.0, 0.78),
    "charcoal":    ((0.42, 0.38, 0.35), 0.0, 0.80),
    "plant":       ((0.42, 0.52, 0.34), 0.0, 0.70),
}

# metres per texture repeat (mirror of Dart _matTile; uppers = walnut tile)
MAT_TILE = {
    "floor": 0.62, "wall": 1.40, "splash": 0.60,
    "walnut": 0.85, "walnut_door": 0.85, "upper": 0.85, "upper_door": 0.85,
    "olive": 0.80, "olive_door": 0.80, "wood": 0.70,
    "taupe": 0.45, "charcoal": 0.45, "basalt": 0.90, "quartz": 1.10,
}

# ---------------------------------------------------------------------------
# DESIGN OPTION TABLES - ported verbatim to lib/services/kitchen_design.dart.
# Every option: key -> (label, swatch AARRGGBB for the UI chip, payload).
# Cabinet finishes carry (carcass rgb, door rgb).
# ---------------------------------------------------------------------------
CABINET_FINISHES = {
    "warm_walnut": ("Warm walnut", 0xFF6B4830,
                    ((0.42, 0.28, 0.185), (0.48, 0.325, 0.215))),
    "light_oak":   ("Light oak", 0xFFB3926A,
                    ((0.70, 0.57, 0.41), (0.77, 0.64, 0.47))),
    "white_satin": ("White satin", 0xFFE6E4DE,
                    ((0.88, 0.87, 0.84), (0.93, 0.92, 0.89))),
    "sand_beige":  ("Sand beige", 0xFFC2AE8F,
                    ((0.74, 0.66, 0.54), (0.80, 0.72, 0.60))),
    "sage_green":  ("Sage green", 0xFF85947F,
                    ((0.50, 0.56, 0.47), (0.56, 0.62, 0.53))),
    "olive_green": ("Olive green", 0xFF465342,
                    ((0.275, 0.325, 0.26), (0.315, 0.37, 0.30))),
    "navy_blue":   ("Navy blue", 0xFF28384F,
                    ((0.155, 0.215, 0.31), (0.19, 0.255, 0.36))),
    "graphite":    ("Graphite", 0xFF2A2C30,
                    ((0.16, 0.17, 0.19), (0.20, 0.21, 0.24))),
}

# Worktops apply to BOTH the run counter ('basalt' slot) and the island top
# ('quartz' slot); payload = (rgb, texture or None to keep the slot texture).
WORKTOPS = {
    "basalt_quartz": ("Basalt + quartz", 0xFF26292B, None),  # per-slot default
    "white_quartz":  ("White quartz", 0xFFE5E3DE, ((0.90, 0.89, 0.86), "quartz")),
    "black_granite": ("Black granite", 0xFF17181A, ((0.09, 0.095, 0.10), "stone")),
    "grey_concrete": ("Grey concrete", 0xFF8C8A85, ((0.55, 0.54, 0.51), "stone")),
    "marble_veined": ("Veined marble", 0xFFE9E7E2, ((0.92, 0.91, 0.89), "quartz")),
    "butcher_block": ("Butcher block", 0xFF8C6A45, ((0.55, 0.40, 0.27), "wood")),
}

WALL_PAINTS = {
    "warm_white":  ("Warm white", 0xFFE8E1D2, (0.91, 0.88, 0.82)),
    "pure_white":  ("Pure white", 0xFFF2F1EC, (0.95, 0.95, 0.93)),
    "cream":       ("Cream", 0xFFEDE0C4, (0.93, 0.88, 0.77)),
    "sage_mist":   ("Sage mist", 0xFFCCD6C6, (0.80, 0.84, 0.78)),
    "sky_grey":    ("Sky grey", 0xFFC7CFD6, (0.78, 0.81, 0.84)),
    "terracotta":  ("Terracotta", 0xFFDBB79E, (0.86, 0.72, 0.62)),
    "charcoal":    ("Charcoal", 0xFF595C61, (0.35, 0.36, 0.38)),
}

FLOORS = {
    "travertine":   ("Travertine", 0xFFD1C2A8, ((0.82, 0.76, 0.66), None)),
    "light_oak":    ("Light oak", 0xFFCCB28C, ((0.80, 0.70, 0.55), None)),
    "honey_oak":    ("Honey oak", 0xFFB88F61, ((0.72, 0.56, 0.38), None)),
    "grey_wood":    ("Grey wood", 0xFF9E9A94, ((0.62, 0.60, 0.58), None)),
    "dark_walnut":  ("Dark walnut", 0xFF73573D, ((0.45, 0.34, 0.24), None)),
    "stone_tile":   ("Stone tile", 0xFFBFBAB0, ((0.75, 0.73, 0.68), "stone")),
    "slate_tile":   ("Slate tile", 0xFF595A5E, ((0.35, 0.35, 0.37), "stone")),
}

BACKSPLASHES = {
    "sage_subway":  ("Sage subway", 0xFFB5C4B0, ((0.71, 0.77, 0.69), None)),
    "white_subway": ("White subway", 0xFFE0E5E2, ((0.88, 0.90, 0.89), None)),
    "smoke_grey":   ("Smoke grey", 0xFF4D545C, ((0.30, 0.33, 0.36), None)),
    "deep_navy":    ("Deep navy", 0xFF33425C, ((0.20, 0.26, 0.36), None)),
    "terracotta":   ("Terracotta", 0xFFB87A61, ((0.72, 0.48, 0.38), None)),
    "marble_slab":  ("Marble slab", 0xFFE6E4DF, ((0.90, 0.89, 0.87), "quartz")),
}

HARDWARE = {
    "brass": ("Brass", 0xFFC79E54, ((0.78, 0.62, 0.33), 1.0, 0.30)),
    "steel": ("Steel", 0xFFBDBFC2, ((0.74, 0.75, 0.77), 0.95, 0.35)),
    "black": ("Matte black", 0xFF232326, ((0.06, 0.06, 0.07), 0.40, 0.60)),
}

HANDLE_STYLES = {"bar": "Bar pull", "knob": "Knob", "none": "Handleless"}
DOOR_STYLES = {"slab": "Flat slab", "shaker": "Shaker frame"}


def design(lower="warm_walnut", upper=None, island="olive_green",
           worktop="basalt_quartz", wall="warm_white", floor="travertine",
           splash="sage_subway", hardware="brass", handle="bar", door="slab"):
    return {
        "lower": lower, "upper": upper or lower, "island": island,
        "worktop": worktop, "wall": wall, "floor": floor, "splash": splash,
        "hardware": hardware, "handle": handle, "door": door,
    }


# Presets exposed in the app (incl. the two the user asked for by name).
PRESETS = {
    "signature_walnut": design(),
    "all_light": design(lower="white_satin", upper="white_satin",
                        island="light_oak", worktop="white_quartz",
                        wall="pure_white", floor="light_oak",
                        splash="white_subway", hardware="steel",
                        handle="bar", door="shaker"),
    "all_dark": design(lower="graphite", upper="graphite", island="graphite",
                       worktop="black_granite", wall="charcoal",
                       floor="grey_wood", splash="smoke_grey",
                       hardware="black", handle="none", door="slab"),
    "light_oak": design(lower="light_oak", upper="light_oak",
                        island="sage_green", worktop="white_quartz",
                        wall="pure_white", floor="travertine",
                        splash="white_subway", hardware="steel", door="slab"),
    "dark_modern": design(lower="graphite", upper="graphite",
                          island="olive_green", worktop="basalt_quartz",
                          wall="warm_white", floor="grey_wood",
                          splash="smoke_grey", hardware="black", door="slab"),
}


def scale3(rgb, k):
    return tuple(min(1.0, c * k) for c in rgb)


def effective_mats(d):
    """Mirror of Dart KitchenDesign.apply(): per-element material overrides."""
    lower_c, lower_d = CABINET_FINISHES[d["lower"]][2]
    upper_c, upper_d = CABINET_FINISHES[d["upper"]][2]
    isl_c, isl_d = CABINET_FINISHES[d["island"]][2]
    hw_rgb, hw_metal, hw_rough = HARDWARE[d["hardware"]][2]
    out = {}
    for name, (rgb, metal, rough) in MATS.items():
        out[name] = (rgb, metal, rough)
    out["walnut"] = (lower_c, 0.0, 0.65)
    out["walnut_door"] = (lower_d, 0.0, 0.60)
    out["upper"] = (upper_c, 0.0, 0.65)
    out["upper_door"] = (upper_d, 0.0, 0.60)
    out["olive"] = (isl_c, 0.0, 0.55)
    out["olive_door"] = (isl_d, 0.0, 0.50)
    out["wall"] = (WALL_PAINTS[d["wall"]][2], 0.0, 0.95)
    out["floor"] = (FLOORS[d["floor"]][2][0], 0.0, 0.90)
    out["splash"] = (BACKSPLASHES[d["splash"]][2][0], 0.0, 0.40)
    wt = WORKTOPS[d["worktop"]][2]
    if wt is not None:
        out["basalt"] = (wt[0], 0.05, 0.35)
        out["quartz"] = (wt[0], 0.0, 0.30)
    out["brass"] = (hw_rgb, hw_metal, hw_rough)
    out["toe"] = (scale3(lower_c, 0.35), 0.0, 0.80)
    return out


def texture_overrides(d):
    """Mirror of Dart KitchenDesign.textureOverrides()."""
    out = {}
    fl = FLOORS[d["floor"]][2][1]
    if fl:
        out["floor"] = fl
    wt = WORKTOPS[d["worktop"]][2]
    if wt and wt[1]:
        out["basalt"] = wt[1]
        out["quartz"] = wt[1]
    sp = BACKSPLASHES[d["splash"]][2][1]
    if sp:
        out["splash"] = sp
    return out


# ---------------------------------------------------------------------------
# Scene / geometry - EXACT mirror of the Dart _Scene/_Frame builders.
# ---------------------------------------------------------------------------
class Scene:
    def __init__(self):
        self.groups = {m: {"pos": [], "nrm": [], "uv": [], "idx": []}
                       for m in MATS}

    def _quad(self, g, n, corners, tile):
        base = len(g["pos"]) // 3
        for p in corners:
            g["pos"].extend(p)
            g["nrm"].extend(n)
            if n[1] != 0:
                u, v = p[0], p[2]
            elif n[2] != 0:
                u, v = p[0], p[1]
            else:
                u, v = p[2], p[1]
            g["uv"].extend([u / tile, v / tile])
        g["idx"].extend([base, base + 1, base + 2, base, base + 2, base + 3])

    def box(self, x0, y0, z0, x1, y1, z1, mat):
        if not (x1 > x0 and y1 > y0 and z1 > z0):
            return
        g = self.groups[mat]
        tile = MAT_TILE.get(mat, 0.8)
        self._quad(g, (0, 1, 0), [(x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0)], tile)
        self._quad(g, (0, -1, 0), [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], tile)
        self._quad(g, (0, 0, 1), [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], tile)
        self._quad(g, (0, 0, -1), [(x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0)], tile)
        self._quad(g, (1, 0, 0), [(x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1)], tile)
        self._quad(g, (-1, 0, 0), [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)], tile)

    @property
    def triangles(self):
        return sum(len(g["idx"]) // 3 for g in self.groups.values())


TH, BH, CTOP, BD, CD = 0.10, 0.86, 0.90, 0.62, 0.655
UY0, UY1, UD, HCEIL, WALLT = 1.50, 2.20, 0.35, 2.70, 0.06


class Frame:
    def __init__(self, wall, w, d):
        self.wall, self.w, self.d = wall, w, d

    def pt(self, u, y, v):
        # b20: ONE u-origin convention everywhere, matching the AI schema -
        # u measured from the WEST end on north/south walls and from the
        # NORTH end on east/west walls. (Pre-b20 south/east frames counted
        # from the opposite end, silently mirroring AI-read appliances.)
        if self.wall == "north":
            return (u, y, v)
        if self.wall == "south":
            return (u, y, self.d - v)
        if self.wall == "west":
            return (v, y, u)
        return (self.w - v, y, u)  # east

    def box(self, s, u0, u1, y0, y1, v0, v1, mat):
        p1, p2 = self.pt(u0, 0, v0), self.pt(u1, 0, v1)
        s.box(min(p1[0], p2[0]), y0, min(p1[2], p2[2]),
              max(p1[0], p2[0]), y1, max(p1[2], p2[2]), mat)


# --- NEW geometry: handles + door fronts (coordinates frozen for the port) --
def base_handle(f, s, c, style):
    """Handle on a base door/drawer front (front face at v=BD+0.017)."""
    if style == "bar":
        f.box(s, c - 0.07, c + 0.07, BH - 0.105, BH - 0.094,
              BD + 0.021, BD + 0.048, "brass")
    elif style == "knob":
        f.box(s, c - 0.016, c + 0.016, BH - 0.118, BH - 0.086,
              BD + 0.017, BD + 0.049, "brass")
    # 'none': handleless - no geometry


def upper_handle(f, s, c, style):
    """Handle on an upper door (front face at v=UD+0.015)."""
    if style == "bar":
        f.box(s, c - 0.07, c + 0.07, UY0 + 0.054, UY0 + 0.065,
              UD + 0.019, UD + 0.046, "brass")
    elif style == "knob":
        f.box(s, c - 0.016, c + 0.016, UY0 + 0.042, UY0 + 0.074,
              UD + 0.015, UD + 0.047, "brass")


def door_front(f, s, u0, u1, y0, y1, v_back, v_face, mat, style):
    """A door leaf from v_back to v_face. 'shaker' = panel + 4 rails; falls
    back to slab when the leaf is too small for a 6.5 cm frame."""
    r = 0.065
    if style == "shaker" and (u1 - u0) > 2.6 * r and (y1 - y0) > 2.6 * r:
        v_mid = v_back + (v_face - v_back) * 0.55
        f.box(s, u0, u1, y0, y1, v_back, v_mid, mat)           # recessed panel
        f.box(s, u0, u0 + r, y0, y1, v_mid, v_face, mat)       # left rail
        f.box(s, u1 - r, u1, y0, y1, v_mid, v_face, mat)       # right rail
        f.box(s, u0 + r, u1 - r, y0, y0 + r, v_mid, v_face, mat)  # bottom
        f.box(s, u0 + r, u1 - r, y1 - r, y1, v_mid, v_face, mat)  # top
    else:
        f.box(s, u0, u1, y0, y1, v_back, v_face, mat)


def build_tall(s, f, r, handle_style="bar", door_style="slab"):
    """b30 tall unit (pantry/larder): floor-to-upper-top carcass with
    stacked door leaves. Uses the lower-cabinet material slots so the
    studio's 'lower' finish drives it. No worktop, no splash, no uppers."""
    a, b = r["a"], r["b"]
    f.box(s, a + 0.02, b - 0.02, 0, TH, 0.02, BD - 0.05, "toe")
    f.box(s, a, b, TH, UY1, 0.0, BD, "walnut")
    n = max(1, round((b - a) / 0.60))
    bw = (b - a) / n
    for k in range(n):
        ba, bb = a + k * bw + 0.009, a + (k + 1) * bw - 0.009
        door_front(f, s, ba, bb, TH + 0.008, 1.295, BD, BD + 0.017,
                   "walnut_door", door_style)
        door_front(f, s, ba, bb, 1.305, UY1 - 0.008, BD, BD + 0.017,
                   "walnut_door", door_style)
        c = (ba + bb) / 2
        if handle_style == "bar":
            f.box(s, c - 0.011, c + 0.011, 0.95, 1.25,
                  BD + 0.019, BD + 0.046, "brass")
            f.box(s, c - 0.011, c + 0.011, 1.35, 1.65,
                  BD + 0.019, BD + 0.046, "brass")
        elif handle_style == "knob":
            f.box(s, c - 0.016, c + 0.016, 1.24, 1.272,
                  BD + 0.017, BD + 0.049, "brass")
            f.box(s, c - 0.016, c + 0.016, 1.34, 1.372,
                  BD + 0.017, BD + 0.049, "brass")


def worktop_span(r, ca, cb, runs, w, d):
    """b31 corner-aware worktop extent: at an L-corner the top runs
    EXACTLY to the perpendicular neighbour's counter face, so the two
    tops join FLUSH - no 5 mm coplanar overlap (z-fighting), no slit.
    [ca, cb] is the COUNTER part of the run (fridge slot excluded).
    Returns (wa, wb) for the worktop slab (default ca-0.02 .. cb+0.02)."""
    a, b = ca, cb
    wa, wb = a - 0.02, b + 0.02
    horiz = r["wall"] in ("north", "south")
    m = w if horiz else d
    m_cross = d if horiz else w
    # my rect's cross extent measured along the PERPENDICULAR axis
    my_near = r["wall"] in ("north", "west")
    cross0 = 0.0 if my_near else m_cross - CD
    cross1 = CD if my_near else m_cross
    near_wall = "north" if not horiz else "west"
    far_wall = "south" if not horiz else "east"
    for q in runs:
        if q is r:
            continue
        if (q["wall"] in ("north", "south")) == horiz:
            continue
        if q.get("fridge") and (q["b"] - q["a"]) <= FRIDGE_ONLY_LEN + 0.06:
            continue  # freestanding fridge: no worktop to join
        # q's span (along its own axis == my cross axis) must reach my band
        lo, hi = max(q["a"], cross0), min(q["b"], cross1)
        if hi - lo < 0.10:
            continue
        qdepth = BD if q.get("tall") else CD
        if q["wall"] == near_wall:
            face = qdepth
            if -0.02 <= a - face <= 0.08:
                wa = face
        elif q["wall"] == far_wall:
            face = m - qdepth
            if -0.02 <= face - b <= 0.08:
                wb = face
    return wa, wb


FRIDGE_ONLY_LEN = 0.80


# --- run builder: mirror of Dart _buildRun + design hooks ------------------
def build_run(s, f, r, windows, handle_style="bar", door_style="slab",
              draw_windows=True, runs=(), room_w=0.0, room_d=0.0):
    if r.get("tall"):
        build_tall(s, f, r, handle_style, door_style)
        return
    a, b = r["a"], r["b"]

    if r.get("fridge") == "start":
        f.box(s, a, a + 0.70, 0, 1.86, 0.0, 0.75, "steel")
        f.box(s, a, a + 0.70, 1.92, 2.20, 0.02, 0.72, "upper")
        a += 0.80
    elif r.get("fridge") == "end":
        f.box(s, b - 0.70, b, 0, 1.86, 0.0, 0.75, "steel")
        f.box(s, b - 0.70, b, 1.92, 2.20, 0.02, 0.72, "upper")
        b -= 0.80
    if b - a < 0.7:
        return

    f.box(s, a + 0.02, b - 0.02, 0, TH, 0.02, BD - 0.05, "toe")
    f.box(s, a, b, TH, BH, 0.0, BD, "walnut")
    if runs and room_w:
        wa, wb = worktop_span(r, a, b, runs, room_w, room_d)
    else:
        wa, wb = a - 0.02, b + 0.02
    f.box(s, wa, wb, BH, CTOP, 0.0, CD, "basalt")
    f.box(s, a, b, CTOP, 1.46, 0.0, 0.02, "splash")

    n = max(2, round((b - a) / 0.60))
    bw = (b - a) / n
    for k in range(n):
        ba, bb = a + k * bw + 0.009, a + (k + 1) * bw - 0.009
        c = (ba + bb) / 2
        if r.get("rangeAt") is not None and abs(c - r["rangeAt"]) < 0.42:
            continue
        door_front(f, s, ba, bb, TH + 0.008, BH - 0.008, BD, BD + 0.017,
                   "walnut_door", door_style)
        base_handle(f, s, c, handle_style)

    if r.get("sinkAt") is not None:
        sc = r["sinkAt"]
        f.box(s, sc - 0.34, sc + 0.34, CTOP + 0.0005, CTOP + 0.002, 0.09, 0.50, "black")
        f.box(s, sc - 0.36, sc + 0.36, CTOP, CTOP + 0.012, 0.07, 0.09, "steel")
        f.box(s, sc - 0.36, sc + 0.36, CTOP, CTOP + 0.012, 0.50, 0.52, "steel")
        f.box(s, sc - 0.015, sc + 0.015, CTOP, CTOP + 0.31, 0.04, 0.075, "steel")
        f.box(s, sc - 0.012, sc + 0.012, CTOP + 0.285, CTOP + 0.31, 0.055, 0.25, "steel")

    if r.get("rangeAt") is not None:
        rc = r["rangeAt"]
        f.box(s, rc - 0.372, rc + 0.372, TH, BH, 0.02, BD + 0.028, "steel")
        f.box(s, rc - 0.33, rc + 0.33, 0.15, 0.55, BD + 0.028, BD + 0.037, "black")
        f.box(s, rc - 0.36, rc + 0.36, CTOP - 0.002, CTOP + 0.014, 0.05, 0.57, "black")
        f.box(s, rc - 0.43, rc + 0.43, 1.42, 1.52, 0.02, 0.53, "steel")
        f.box(s, rc - 0.21, rc + 0.21, 1.52, HCEIL, 0.06, 0.34, "steel")

    if draw_windows:
        for win in windows:
            if win["wall"] != r["wall"]:
                continue
            wa, wb = win["center"] - win["width"] / 2, win["center"] + win["width"] / 2
            f.box(s, wa, wb, 1.00, 1.90, -0.015, 0.005, "glass")
            f.box(s, wa - 0.05, wa, 0.95, 1.95, -0.02, 0.02, "frame")
            f.box(s, wb, wb + 0.05, 0.95, 1.95, -0.02, 0.02, "frame")
            f.box(s, wa - 0.05, wb + 0.05, 0.95, 1.00, -0.02, 0.02, "frame")
            f.box(s, wa - 0.05, wb + 0.05, 1.90, 1.95, -0.02, 0.02, "frame")

    if r.get("uppers"):
        skip = []
        if r.get("rangeAt") is not None:
            skip.append([r["rangeAt"] - 0.48, r["rangeAt"] + 0.48])
        for win in windows:
            if win["wall"] == r["wall"]:
                skip.append([win["center"] - win["width"] / 2 - 0.1,
                             win["center"] + win["width"] / 2 + 0.1])
        spans = [[a + 0.02, b - 0.02]]
        for k in skip:
            nxt = []
            for sp in spans:
                if k[1] <= sp[0] or k[0] >= sp[1]:
                    nxt.append(sp)
                else:
                    if k[0] - sp[0] > 0.45:
                        nxt.append([sp[0], k[0]])
                    if sp[1] - k[1] > 0.45:
                        nxt.append([k[1], sp[1]])
            spans = nxt
        for sp in spans:
            f.box(s, sp[0], sp[1], UY0, UY1, 0.0, UD, "upper")
            nd = max(1, round((sp[1] - sp[0]) / 0.55))
            dw = (sp[1] - sp[0]) / nd
            for k in range(nd):
                ba, bb = sp[0] + k * dw + 0.008, sp[0] + (k + 1) * dw - 0.008
                door_front(f, s, ba, bb, UY0 + 0.008, UY1 - 0.008,
                           UD, UD + 0.015, "upper_door", door_style)
                upper_handle(f, s, (ba + bb) / 2, handle_style)


def run_rect_proto(r, w, d):
    """Plan rect of a run (mirror of the normalizer's run_rect)."""
    depth = 0.75 if r.get("fridge") else CD
    a, b = r["a"], r["b"]
    if r["wall"] == "north":
        return (a, 0.0, b, depth)
    if r["wall"] == "south":
        return (a, d - depth, b, d)
    if r["wall"] == "west":
        return (0.0, a, depth, b)
    return (w - depth, a, w, b)  # east


def build_island(s, i, w, d, runs=()):
    x0, x1, z0, z1 = i["x0"], i["x0"] + i["w"], i["z0"], i["z0"] + i["d"]
    s.box(x0 + 0.05, 0, z0 + 0.05, x1 - 0.05, TH, z1 - 0.05, "toe")
    s.box(x0, TH, z0, x1, BH, z1, "olive")
    # b30: the 5 cm worktop lip is SUPPRESSED on any side that touches a
    # cabinet run (the normalizer allows attached peninsulas - the lip
    # jutting into the neighbouring worktop read as "cabinets overlap")
    def side_clear(side):
        for r in runs:
            rx0, rz0, rx1, rz1 = run_rect_proto(r, w, d)
            if side in ("x0", "x1") and not (z0 < rz1 and rz0 < z1):
                continue
            if side in ("z0", "z1") and not (x0 < rx1 and rx0 < x1):
                continue
            gap = {"x0": x0 - rx1, "x1": rx0 - x1,
                   "z0": z0 - rz1, "z1": rz0 - z1}[side]
            if -0.02 <= gap < 0.055:
                return False
        return True

    tx0 = x0 - (0.05 if side_clear("x0") else 0.0)
    tx1 = x1 + (0.05 if side_clear("x1") else 0.0)
    tz0 = z0 - (0.05 if side_clear("z0") else 0.0)
    tz1 = z1 + (0.05 if side_clear("z1") else 0.0)
    seat = i.get("seating", "south")
    if seat == "north":
        tz0 = z0 - 0.30
    elif seat == "south":
        tz1 = z1 + 0.30
    elif seat == "west":
        tx0 = x0 - 0.30
    else:
        tx1 = x1 + 0.30
    s.box(tx0, BH, tz0, tx1, CTOP, tz1, "quartz")
    if i.get("cooktop"):
        cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
        hw = min(0.36, i["w"] / 2 - 0.08)
        hd = min(0.26, i["d"] / 2 - 0.06)
        s.box(cx - hw, CTOP - 0.001, cz - hd, cx + hw, CTOP + 0.014, cz + hd, "black")
    horizontal = seat in ("north", "south")
    span = i["w"] if horizontal else i["d"]
    count = 2 if span >= 1.4 else 1
    for k in range(count):
        off = span / 2 if count == 1 else (0.45 if k == 0 else span - 0.45)
        if seat == "north":
            cx, cz = x0 + off, z0 - 0.42
        elif seat == "south":
            cx, cz = x0 + off, z1 + 0.42
        elif seat == "west":
            cx, cz = x0 - 0.42, z0 + off
        else:
            cx, cz = x1 + 0.42, z0 + off
        cx = min(max(cx, 0.25), w - 0.25)
        cz = min(max(cz, 0.25), d - 0.25)
        s.box(cx - 0.18, 0.60, cz - 0.15, cx + 0.18, 0.648, cz + 0.15, "wood")
        for lx in (cx - 0.15, cx + 0.12):
            for lz in (cz - 0.12, cz + 0.09):
                s.box(lx, 0, lz, lx + 0.03, 0.60, lz + 0.03, "wood")
    for k in range(2):
        cx = x0 + i["w"] * 0.28 if k == 0 else x1 - i["w"] * 0.28
        cz = (z0 + z1) / 2
        s.box(cx - 0.008, 2.02, cz - 0.008, cx + 0.008, HCEIL, cz + 0.008, "brass")
        s.box(cx - 0.10, 1.87, cz - 0.10, cx + 0.10, 2.02, cz + 0.10, "black")


def build_plan(plan, d):
    s = Scene()
    w, dp = plan["w"], plan["d"]
    s.box(0, -0.05, 0, w, 0.0, dp, "floor")
    walls = {r["wall"] for r in plan["runs"]} | {x["wall"] for x in plan.get("windows", [])}
    if "north" in walls:
        s.box(0, 0, -WALLT, w, HCEIL, 0, "wall")
    if "south" in walls:
        s.box(0, 0, dp, w, HCEIL, dp + WALLT, "wall")
    if "west" in walls:
        s.box(-WALLT, 0, 0, 0, HCEIL, dp, "wall")
    if "east" in walls:
        s.box(w, 0, 0, w + WALLT, HCEIL, dp, "wall")
    for r in plan["runs"]:
        build_run(s, Frame(r["wall"], w, dp), r, plan.get("windows", []),
                  handle_style=d["handle"], door_style=d["door"])
    if plan.get("island"):
        build_island(s, plan["island"], w, dp, plan["runs"])
    return s


# --- b20: open room + capped walls + windows drawn per BUILT wall ----------
def plan_walls(plan):
    """Walls hosting runs/windows, capped at 3 (lowest content left open) -
    the generated room is a showroom vignette, never a closed box."""
    score = {}
    for r in plan["runs"]:
        score[r["wall"]] = score.get(r["wall"], 0) + 2 * (r["b"] - r["a"])
    for win in plan.get("windows", []):
        score[win["wall"]] = score.get(win["wall"], 0) + win["width"]
    walls = set(score)
    if len(walls) == 4:
        walls.remove(min(score, key=score.get))
    return walls


def draw_wall_windows(s, f, windows):
    """Window glass+frame boxes in the wall plane (was inside build_run;
    b20 draws them once per BUILT wall so open walls get no floating glass
    and double runs no longer double-draw)."""
    for win in windows:
        if win["wall"] != f.wall:
            continue
        wa = win["center"] - win["width"] / 2
        wb = win["center"] + win["width"] / 2
        f.box(s, wa, wb, 1.00, 1.90, -0.015, 0.005, "glass")
        f.box(s, wa - 0.05, wa, 0.95, 1.95, -0.02, 0.02, "frame")
        f.box(s, wb, wb + 0.05, 0.95, 1.95, -0.02, 0.02, "frame")
        f.box(s, wa - 0.05, wb + 0.05, 0.95, 1.00, -0.02, 0.02, "frame")
        f.box(s, wa - 0.05, wb + 0.05, 1.90, 1.95, -0.02, 0.02, "frame")


def build_plan_b20(plan, d):
    s = Scene()
    w, dp = plan["w"], plan["d"]
    s.box(0, -0.05, 0, w, 0.0, dp, "floor")
    walls = plan_walls(plan)
    if "north" in walls:
        s.box(0, 0, -WALLT, w, HCEIL, 0, "wall")
    if "south" in walls:
        s.box(0, 0, dp, w, HCEIL, dp + WALLT, "wall")
    if "west" in walls:
        s.box(-WALLT, 0, 0, 0, HCEIL, dp, "wall")
    if "east" in walls:
        s.box(w, 0, 0, w + WALLT, HCEIL, dp, "wall")
    wins = plan.get("windows", [])
    for r in plan["runs"]:
        build_run(s, Frame(r["wall"], w, dp), r, wins,
                  handle_style=d["handle"], door_style=d["door"],
                  draw_windows=False, runs=plan["runs"],
                  room_w=w, room_d=dp)
    for wl in walls:
        draw_wall_windows(s, Frame(wl, w, dp), wins)
    if plan.get("island"):
        build_island(s, plan["island"], w, dp, plan["runs"])
    return s


# ---------------------------------------------------------------------------
# GLB writer (mirror of Dart _writeGlb, flat colors - textures unchanged)
# ---------------------------------------------------------------------------
def write_glb(scene, path, name, mats):
    bin_blob = bytearray()
    buffer_views, accessors, primitives = [], [], []
    mat_names = list(mats.keys())

    def add_view(data, target):
        offset = len(bin_blob)
        bin_blob.extend(data)
        while len(bin_blob) % 4:
            bin_blob.append(0)
        bv = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
        if target:
            bv["target"] = target
        buffer_views.append(bv)
        return len(buffer_views) - 1

    for mat, g in scene.groups.items():
        if not g["idx"]:
            continue
        pos = struct.pack(f"<{len(g['pos'])}f", *g["pos"])
        nrm = struct.pack(f"<{len(g['nrm'])}f", *g["nrm"])
        idx = struct.pack(f"<{len(g['idx'])}I", *g["idx"])
        mins = [min(g["pos"][i::3]) for i in range(3)]
        maxs = [max(g["pos"][i::3]) for i in range(3)]
        pv, nv, iv = add_view(pos, 34962), add_view(nrm, 34962), add_view(idx, 34963)
        accessors.append({"bufferView": pv, "componentType": 5126,
                          "count": len(g["pos"]) // 3, "type": "VEC3",
                          "min": mins, "max": maxs})
        p_acc = len(accessors) - 1
        accessors.append({"bufferView": nv, "componentType": 5126,
                          "count": len(g["nrm"]) // 3, "type": "VEC3"})
        n_acc = len(accessors) - 1
        accessors.append({"bufferView": iv, "componentType": 5125,
                          "count": len(g["idx"]), "type": "SCALAR"})
        i_acc = len(accessors) - 1
        primitives.append({"attributes": {"POSITION": p_acc, "NORMAL": n_acc},
                           "indices": i_acc,
                           "material": mat_names.index(mat), "mode": 4})

    materials = [{"name": m,
                  "pbrMetallicRoughness": {
                      "baseColorFactor": [*mats[m][0], 1.0],
                      "metallicFactor": mats[m][1],
                      "roughnessFactor": mats[m][2]},
                  "doubleSided": False} for m in mat_names]

    gltf = {"asset": {"version": "2.0", "generator": "Baytak design proto"},
            "scene": 0, "scenes": [{"nodes": [0], "name": name}],
            "nodes": [{"mesh": 0, "name": name}],
            "meshes": [{"name": name, "primitives": primitives}],
            "materials": materials, "accessors": accessors,
            "bufferViews": buffer_views,
            "buffers": [{"byteLength": len(bin_blob)}]}

    js = bytearray(json.dumps(gltf, separators=(",", ":")).encode())
    while len(js) % 4:
        js += b" "
    bb = bytearray(bin_blob)
    while len(bb) % 4:
        bb += b"\x00"
    total = 12 + 8 + len(js) + 8 + len(bb)
    with open(path, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total))
        fh.write(struct.pack("<II", len(js), 0x4E4F534A))
        fh.write(js)
        fh.write(struct.pack("<II", len(bb), 0x004E4942))
        fh.write(bb)
    return total


# ---------------------------------------------------------------------------
# Structural validator: header, chunk layout, accessors, bounds, indices.
# ---------------------------------------------------------------------------
def validate_glb(path):
    data = path.read_bytes()
    magic, version, total = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67 and version == 2, "bad header"
    assert total == len(data), f"length mismatch {total} != {len(data)}"
    jlen, jtype = struct.unpack_from("<II", data, 12)
    assert jtype == 0x4E4F534A
    gltf = json.loads(data[20:20 + jlen])
    blen, btype = struct.unpack_from("<II", data, 20 + jlen)
    assert btype == 0x004E4942
    binchunk = data[28 + jlen:28 + jlen + blen]
    assert gltf["buffers"][0]["byteLength"] <= blen

    n_mats = len(gltf["materials"])
    for prim in gltf["meshes"][0]["primitives"]:
        assert 0 <= prim["material"] < n_mats, "material index out of range"
        p_acc = gltf["accessors"][prim["attributes"]["POSITION"]]
        i_acc = gltf["accessors"][prim["indices"]]
        assert i_acc["count"] % 3 == 0, "indices not triangles"
        # decode indices, check they address valid vertices
        bv = gltf["bufferViews"][i_acc["bufferView"]]
        raw = binchunk[bv["byteOffset"]:bv["byteOffset"] + bv["byteLength"]]
        idx = struct.unpack(f"<{i_acc['count']}I", raw)
        assert max(idx) < p_acc["count"], "index out of vertex range"
        # verify accessor min/max actually bound the positions
        bvp = gltf["bufferViews"][p_acc["bufferView"]]
        rawp = binchunk[bvp["byteOffset"]:bvp["byteOffset"] + bvp["byteLength"]]
        posv = struct.unpack(f"<{p_acc['count'] * 3}f", rawp)
        for c in range(3):
            lo, hi = min(posv[c::3]), max(posv[c::3])
            assert abs(lo - p_acc["min"][c]) < 1e-4, "min bound wrong"
            assert abs(hi - p_acc["max"][c]) < 1e-4, "max bound wrong"
    tris = sum(gltf["accessors"][p["indices"]]["count"] // 3
               for p in gltf["meshes"][0]["primitives"])
    return tris, len(gltf["meshes"][0]["primitives"])


# ---------------------------------------------------------------------------
# Isometric render for visual verification (same approach as generate_assets)
# ---------------------------------------------------------------------------
def iso_render(scene, mats, path, title, elev=26, azim=-118):
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from mpl_toolkits.mplot3d.art3d import Poly3DCollection

    light = np.array([0.45, 0.85, 0.45])
    light /= np.linalg.norm(light)
    quads, colors = [], []
    for mat, g in scene.groups.items():
        if not g["idx"]:
            continue
        base = np.array(mats[mat][0])
        pos = np.array(g["pos"]).reshape(-1, 3)
        nrm = np.array(g["nrm"]).reshape(-1, 3)
        for fidx in range(0, len(pos), 4):
            lam = 0.38 + 0.62 * max(float(np.dot(nrm[fidx], light)), 0.0)
            quads.append([(p[0], p[2], p[1]) for p in pos[fidx:fidx + 4]])
            colors.append(np.clip(base * lam, 0, 1))
    fig = plt.figure(figsize=(10, 7.5), dpi=110)
    ax = fig.add_subplot(111, projection="3d")
    ax.add_collection3d(Poly3DCollection(quads, facecolors=colors, edgecolors="none"))
    allp = np.array([p for q in quads for p in q])
    c = (allp.min(0) + allp.max(0)) / 2
    r = (allp.max(0) - allp.min(0)).max() / 2
    ax.set_xlim(c[0] - r, c[0] + r)
    ax.set_ylim(c[1] - r, c[1] + r)
    ax.set_zlim(0, 2 * r * 0.92)
    ax.view_init(elev=elev, azim=azim)
    ax.set_axis_off()
    ax.set_facecolor("#101418")
    fig.patch.set_facecolor("#101418")
    ax.set_title(title, color="#d8d2c4", fontsize=10, family="monospace", pad=0)
    fig.tight_layout(pad=0)
    fig.savefig(path, facecolor="#101418")
    plt.close(fig)


# Close-up of one base door + one upper door, to eyeball handle/shaker fit.
def detail_render(scene, mats, path, title):
    iso_render(scene, mats, path, title, elev=8, azim=-95)


# ---------------------------------------------------------------------------
def demo_plan():
    """The K-01 L-shape + island plan (mirror of KitchenSpec.toPlan)."""
    w, d = 4.20, 3.40
    x0, x1 = 0.66, w - 0.05
    span = x1 - x0
    return {
        "w": w, "d": d,
        "runs": [
            {"wall": "north", "a": x0, "b": x1, "sinkAt": x0 + span * 0.30,
             "rangeAt": x0 + span * 0.72, "uppers": True},
            {"wall": "west", "a": 0.02, "b": min(d - 0.05, d * 0.9),
             "fridge": "start"},
        ],
        "windows": [{"wall": "north", "center": x0 + span * 0.30, "width": 1.1}],
        "island": {"x0": (w - 1.6) / 2, "z0": max(1.35, d * 0.52), "w": 1.6,
                   "d": 0.9, "seating": "south", "cooktop": False},
    }


def main():
    plan = demo_plan()
    matrix = list(PRESETS.items()) + [
        ("knob_shaker_sage", design(lower="sage_green", upper="white_satin",
                                    worktop="butcher_block", wall="cream",
                                    floor="honey_oak", splash="white_subway",
                                    hardware="black", handle="knob",
                                    door="shaker")),
        ("handleless_navy", design(lower="navy_blue", upper="white_satin",
                                   island="navy_blue", worktop="marble_veined",
                                   wall="sky_grey", floor="light_oak",
                                   splash="marble_slab", hardware="steel",
                                   handle="none", door="slab")),
    ]
    print(f"{'design':22s} {'tris':>6s} {'prims':>6s} {'KB':>7s}")
    for name, d in matrix:
        scene = build_plan(plan, d)
        mats = effective_mats(d)
        p = OUT / f"design_{name}.glb"
        size = write_glb(scene, p, f"Kitchen_{name}", mats)
        tris, prims = validate_glb(p)
        assert tris == scene.triangles
        print(f"{name:22s} {tris:6d} {prims:6d} {size/1024:7.1f}")
        iso_render(scene, mats, OUT / f"design_{name}.png",
                   f"BAYTAK DESIGN STUDIO / {name}")
        if name in ("knob_shaker_sage", "signature_walnut", "all_dark"):
            detail_render(scene, mats, OUT / f"detail_{name}.png",
                          f"door & handle detail / {name}")
    print("all designs validated OK")


if __name__ == "__main__":
    main()
