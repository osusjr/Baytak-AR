#!/usr/bin/env python3
"""
Baytak AR - asset generator
============================
This script is the demo implementation of the "blueprint -> 3D kitchen" pipeline.

It does three things:
  1. Defines a parametric kitchen layout (the machine-readable form of a blueprint).
  2. Extrudes that layout into a full 3D kitchen and exports it as a glTF binary
     (.glb) - the format Flutter's model_viewer_plus and Android Scene Viewer load.
  3. Draws the matching 2D architectural blueprint (PNG) so the app can show
     "this drawing became that model".

It also exports a single furniture piece (a sofa) for the single-item flow,
a boxes.json used by the standalone HTML preview, and isometric check renders.

No external glTF library is used - the GLB writer below is self-contained
(numpy + stdlib only), so the pipeline is fully inspectable for a demo/thesis.

Roadmap (see README): swap the hardcoded LAYOUT dict for a floor-plan parser
(e.g. trained on CubiCasa5K) and this same extruder produces the model.
"""

import json
import struct
import numpy as np
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "flutter_app" / "assets" / "models"
BLUEPRINTS = ROOT / "flutter_app" / "assets" / "blueprints"
DOCS = ROOT / "docs"
PREVIEW = ROOT / "preview"
for d in (MODELS, BLUEPRINTS, DOCS, PREVIEW):
    d.mkdir(parents=True, exist_ok=True)

# ----------------------------------------------------------------------------
# 1. Materials (PBR): name -> (rgb 0..1, metallic, roughness)
# ----------------------------------------------------------------------------
MATERIALS = {
    "floor_travertine": ((0.82, 0.76, 0.66), 0.0, 0.90),
    "wall_sand":        ((0.91, 0.88, 0.82), 0.0, 0.95),
    "backsplash_sage":  ((0.71, 0.77, 0.69), 0.0, 0.40),
    "cab_walnut":       ((0.42, 0.28, 0.185), 0.0, 0.65),
    "cab_walnut_door":  ((0.48, 0.325, 0.215), 0.0, 0.60),
    "island_olive":     ((0.275, 0.325, 0.26), 0.0, 0.55),
    "island_olive_door":((0.315, 0.37, 0.30), 0.0, 0.50),
    "counter_basalt":   ((0.15, 0.16, 0.17), 0.05, 0.35),
    "counter_quartz":   ((0.90, 0.89, 0.86), 0.0, 0.30),
    "steel":            ((0.74, 0.75, 0.77), 0.95, 0.35),
    "brass":            ((0.78, 0.62, 0.33), 1.00, 0.30),
    "black_matte":      ((0.055, 0.055, 0.065), 0.0, 0.50),
    "toe_kick":         ((0.10, 0.09, 0.085), 0.0, 0.80),
    "window_glass":     ((0.60, 0.74, 0.82), 0.10, 0.10),
    "white_frame":      ((0.95, 0.95, 0.94), 0.0, 0.50),
    "stool_wood":       ((0.55, 0.40, 0.27), 0.0, 0.60),
    "ceramic_white":    ((0.93, 0.92, 0.89), 0.0, 0.35),
    "ceramic_black":    ((0.12, 0.12, 0.13), 0.0, 0.40),
    "plant_green":      ((0.30, 0.45, 0.26), 0.0, 0.70),
    "fabric_taupe":     ((0.66, 0.60, 0.53), 0.0, 0.85),
    "fabric_dark":      ((0.42, 0.38, 0.34), 0.0, 0.85),
}
MAT_INDEX = {name: i for i, name in enumerate(MATERIALS)}

# ----------------------------------------------------------------------------
# 1b. Procedural textures (tileable, baked into the GLB) - the realism layer
# ----------------------------------------------------------------------------
TEX_SIZE = 512
# meters of world space per texture repeat
TEX_SCALE = {
    "cab_walnut": 0.85, "cab_walnut_door": 0.85, "stool_wood": 0.70,
    "island_olive": 0.80, "island_olive_door": 0.80,
    "fabric_taupe": 0.45, "fabric_dark": 0.45,
    "floor_travertine": 0.62, "wall_sand": 1.40, "backsplash_sage": 0.60,
    "counter_quartz": 1.10, "counter_basalt": 0.90, "steel": 0.60,
}

def _grid():
    y, x = np.mgrid[0:TEX_SIZE, 0:TEX_SIZE] / TEX_SIZE
    return x, y

def _tnoise(x, y, comps):
    """Sum of integer-frequency sines -> perfectly tileable value noise."""
    v = np.zeros_like(x)
    for fx, fy, ph, amp in comps:
        v += amp * np.sin(2 * np.pi * (fx * x + fy * y) + ph)
    return v

def _png(rgb):
    from PIL import Image
    import io
    im = Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8))
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    return buf.getvalue()

def _wood(base, contrast=0.30, f=6, along_x=True):
    x, y = _grid()
    a, b = (y, x) if along_x else (x, y)
    warp = _tnoise(x, y, [(1, 2, 0.7, 0.55), (3, 1, 2.1, 0.28), (2, 5, 4.0, 0.14)])
    bands = 0.5 + 0.5 * np.sin(2 * np.pi * (b * f + 1.9 * warp))
    fine = 0.5 + 0.5 * _tnoise(x, y, [(48, 3, 1.0, 0.6), (90, 6, 2.0, 0.4)])
    t = np.clip(0.62 * bands + 0.38 * fine, 0, 1)
    shade = (1 - contrast / 2) + contrast * (1 - t)
    return np.dstack([np.array(base)[c] * shade for c in range(3)])

def _fabric(base):
    x, y = _grid()
    weave = 0.5 + 0.25 * (np.sin(2 * np.pi * x * 52) + np.sin(2 * np.pi * y * 52))
    mottle = 0.5 + 0.5 * _tnoise(x, y, [(3, 4, 1.2, 0.6), (7, 5, 3.0, 0.4)])
    shade = 0.88 + 0.16 * (0.65 * weave + 0.35 * mottle)
    return np.dstack([np.array(base)[c] * shade for c in range(3)])

def _painted(base):
    x, y = _grid()
    n = 0.5 + 0.5 * _tnoise(x, y, [(30, 2, 0.4, 0.5), (5, 9, 2.0, 0.5)])
    shade = 0.965 + 0.05 * n
    return np.dstack([np.array(base)[c] * shade for c in range(3)])

def _travertine(base):
    x, y = _grid()
    bands = 0.5 + 0.5 * np.sin(2 * np.pi * (y * 9 + _tnoise(x, y, [(2, 1, 0.5, 0.7)])))
    pits = (0.5 + 0.5 * _tnoise(x, y, [(60, 41, 1.0, 0.6), (25, 90, 2.5, 0.4)])) > 0.86
    shade = 0.92 + 0.10 * bands - 0.10 * pits
    g = 0.012
    grout = (x < g) | (x > 1 - g) | (y < g) | (y > 1 - g)
    shade = np.where(grout, shade * 0.80, shade)
    return np.dstack([np.array(base)[c] * shade for c in range(3)])

def _subway(base):
    x, y = _grid()
    rows = 4.0
    row = np.floor(y * rows)
    xo = (x + np.where(row % 2 == 0, 0.0, 0.25)) % 1.0
    gx, gy = 0.014, 0.02
    grout = (np.abs((xo * 2) % 1.0) < gx * 2) | (np.abs((y * rows) % 1.0) < gy * rows / 2)
    jit = 0.5 + 0.5 * np.sin(row * 12.9898 + np.floor(xo * 2) * 78.233)
    shade = np.where(grout, 0.78, 0.94 + 0.09 * jit)
    return np.dstack([np.array(base)[c] * shade for c in range(3)])

def _quartz(base):
    x, y = _grid()
    warp = _tnoise(x, y, [(2, 3, 0.3, 0.6), (5, 2, 2.2, 0.3)])
    vein = np.abs(np.sin(2 * np.pi * (1.6 * x + 0.9 * y) + 2.6 * warp)) < 0.045
    fine = 0.5 + 0.5 * _tnoise(x, y, [(70, 55, 0.7, 1.0)])
    shade = 0.985 + 0.02 * fine
    shade = np.where(vein, shade * 0.925, shade)
    return np.dstack([np.array(base)[c] * shade for c in range(3)])

def _basalt(base):
    x, y = _grid()
    speck = 0.5 + 0.5 * _tnoise(x, y, [(85, 60, 0.4, 0.6), (40, 95, 1.9, 0.4)])
    flecks = speck > 0.90
    shade = 0.94 + 0.10 * speck + np.where(flecks, 0.18, 0.0)
    return np.dstack([np.array(base)[c] * shade for c in range(3)])

def _brushed(base):
    x, y = _grid()
    streak = 0.5 + 0.5 * np.sin(2 * np.pi * (y * 170) +
                                3.0 * _tnoise(x, y, [(2, 7, 0.5, 1.0)]))
    shade = 0.95 + 0.09 * streak
    return np.dstack([np.array(base)[c] * shade for c in range(3)])

def build_textures():
    """mat name -> PNG bytes; colors baked in (baseColorFactor becomes white)."""
    M = {m: MATERIALS[m][0] for m in MATERIALS}
    return {
        "cab_walnut":       _png(_wood(np.array(M["cab_walnut"]) * 1.12, 0.34, 6, True)),
        "cab_walnut_door":  _png(_wood(np.array(M["cab_walnut_door"]) * 1.10, 0.30, 7, False)),
        "stool_wood":       _png(_wood(np.array(M["stool_wood"]) * 1.08, 0.22, 5, True)),
        "island_olive":     _png(_painted(M["island_olive"])),
        "island_olive_door":_png(_painted(M["island_olive_door"])),
        "fabric_taupe":     _png(_fabric(M["fabric_taupe"])),
        "fabric_dark":      _png(_fabric(M["fabric_dark"])),
        "floor_travertine": _png(_travertine(M["floor_travertine"])),
        "wall_sand":        _png(_painted(M["wall_sand"])),
        "backsplash_sage":  _png(_subway(M["backsplash_sage"])),
        "counter_quartz":   _png(_quartz(M["counter_quartz"])),
        "counter_basalt":   _png(_basalt(M["counter_basalt"])),
        "steel":            _png(_brushed(M["steel"])),
    }

_TEXTURES = None
def textures():
    global _TEXTURES
    if _TEXTURES is None:
        print("  baking textures ...")
        _TEXTURES = build_textures()
    return _TEXTURES

# ----------------------------------------------------------------------------
# 2. Geometry collector: axis-aligned boxes with flat (per-face) normals
# ----------------------------------------------------------------------------
class Scene:
    def __init__(self):
        # per-material: lists of positions, normals, uvs, indices
        self.groups = {m: {"pos": [], "nrm": [], "uv": [], "idx": []}
                       for m in MATERIALS}
        self.boxes_export = []  # for boxes.json (HTML preview)

    @staticmethod
    def _uv(p, n, scale):
        if n[1] != 0:   u, v = p[0], p[2]   # top/bottom -> plan projection
        elif n[2] != 0: u, v = p[0], p[1]   # front/back
        else:           u, v = p[2], p[1]   # sides
        return (u / scale, v / scale)

    def box(self, mn, mx, mat, export=True):
        x0, y0, z0 = mn
        x1, y1, z1 = mx
        assert x1 > x0 and y1 > y0 and z1 > z0, f"degenerate box {mn}->{mx}"
        g = self.groups[mat]
        scale = TEX_SCALE.get(mat, 0.8)
        # (normal, four CCW-from-outside corners) - winding verified by cross product
        faces = [
            ((0, 1, 0),  [(x0,y1,z0),(x0,y1,z1),(x1,y1,z1),(x1,y1,z0)]),   # top
            ((0,-1, 0),  [(x0,y0,z0),(x1,y0,z0),(x1,y0,z1),(x0,y0,z1)]),   # bottom
            ((0, 0, 1),  [(x0,y0,z1),(x1,y0,z1),(x1,y1,z1),(x0,y1,z1)]),   # +z
            ((0, 0,-1),  [(x1,y0,z0),(x0,y0,z0),(x0,y1,z0),(x1,y1,z0)]),   # -z
            ((1, 0, 0),  [(x1,y0,z1),(x1,y0,z0),(x1,y1,z0),(x1,y1,z1)]),   # +x
            ((-1,0, 0),  [(x0,y0,z0),(x0,y0,z1),(x0,y1,z1),(x0,y1,z0)]),   # -x
        ]
        for n, corners in faces:
            a, b, c = (np.array(corners[i], float) for i in range(3))
            cr = np.cross(b - a, c - a)
            assert np.dot(cr, n) > 0, "winding error"
            base = len(g["pos"])
            g["pos"].extend(corners)
            g["nrm"].extend([n] * 4)
            g["uv"].extend(self._uv(p, n, scale) for p in corners)
            g["idx"].extend([base, base + 1, base + 2, base, base + 2, base + 3])
        if export:
            self.boxes_export.append(
                {"min": [round(v, 4) for v in mn],
                 "max": [round(v, 4) for v in mx],
                 "mat": mat})

    def cylinder(self, cx, cz, y0, y1, r, mat, seg=16, export=True):
        """Vertical cylinder: smooth-shaded side + flat caps."""
        assert y1 > y0 and r > 0
        g = self.groups[mat]
        scale = TEX_SCALE.get(mat, 0.8)
        ang = [2 * np.pi * i / seg for i in range(seg + 1)]
        ring = [(cx + r*np.cos(a), cz + r*np.sin(a)) for a in ang]
        nrm = [(np.cos(a), 0.0, np.sin(a)) for a in ang]
        circ = 2 * np.pi * r
        for i in range(seg):
            (xa, za), (xb, zb) = ring[i], ring[i+1]
            base = len(g["pos"])
            quad = [(xa, y0, za), (xb, y0, zb), (xb, y1, zb), (xa, y1, za)]
            a3, b3, c3 = (np.array(quad[k], float) for k in range(3))
            out = np.array([(nrm[i][0]+nrm[i+1][0])/2, 0,
                            (nrm[i][2]+nrm[i+1][2])/2])
            order = quad if np.dot(np.cross(b3-a3, c3-a3), out) > 0 \
                else [quad[0], quad[3], quad[2], quad[1]]
            ns = [nrm[i], nrm[i+1], nrm[i+1], nrm[i]] if order is quad \
                else [nrm[i], nrm[i], nrm[i+1], nrm[i+1]]
            us = [ang[i]/(2*np.pi)*circ/scale, ang[i+1]/(2*np.pi)*circ/scale]
            uvs = [(us[0], y0/scale), (us[1], y0/scale),
                   (us[1], y1/scale), (us[0], y1/scale)] if order is quad \
                else [(us[0], y0/scale), (us[0], y1/scale),
                      (us[1], y1/scale), (us[1], y0/scale)]
            g["pos"].extend(order)
            g["nrm"].extend(ns)
            g["uv"].extend(uvs)
            g["idx"].extend([base, base+1, base+2, base, base+2, base+3])
        for y, ny in ((y1, (0, 1, 0)), (y0, (0, -1, 0))):
            for i in range(seg):
                (xa, za), (xb, zb) = ring[i], ring[i+1]
                quad = [(cx, y, cz), (xa, y, za), (xb, y, zb), (cx, y, cz)]
                a3, b3, c3 = (np.array(quad[k], float) for k in range(3))
                if np.dot(np.cross(b3-a3, c3-a3), np.array(ny)) <= 0:
                    quad = [quad[0], quad[2], quad[1], quad[3]]
                base = len(g["pos"])
                g["pos"].extend(quad)
                g["nrm"].extend([ny] * 4)
                g["uv"].extend(self._uv(p, ny, scale) for p in quad)
                g["idx"].extend([base, base+1, base+2])
        if export:
            self.boxes_export.append(
                {"min": [round(cx-r, 4), round(y0, 4), round(cz-r, 4)],
                 "max": [round(cx+r, 4), round(y1, 4), round(cz+r, 4)],
                 "mat": mat})

# ----------------------------------------------------------------------------
# 3. GLB writer (glTF 2.0 binary, spec-compliant, no dependencies)
# ----------------------------------------------------------------------------
def write_glb(scene: Scene, path: Path, name: str):
    bin_blob = bytearray()
    buffer_views, accessors, primitives = [], [], []

    def pad4(b, fill=b"\x00"):
        while len(b) % 4:
            b += fill
        return b

    def add_view(data: bytes, target):
        offset = len(bin_blob)
        bin_blob.extend(data)
        while len(bin_blob) % 4:
            bin_blob.append(0)
        buffer_views.append({"buffer": 0, "byteOffset": offset,
                             "byteLength": len(data), "target": target})
        return len(buffer_views) - 1

    for mat, g in scene.groups.items():
        if not g["idx"]:
            continue
        pos = np.array(g["pos"], dtype=np.float32)
        nrm = np.array(g["nrm"], dtype=np.float32)
        uv = np.array(g["uv"], dtype=np.float32)
        idx = np.array(g["idx"], dtype=np.uint32)

        pv = add_view(pos.tobytes(), 34962)
        nv = add_view(nrm.tobytes(), 34962)
        tv = add_view(uv.tobytes(), 34962)
        iv = add_view(idx.tobytes(), 34963)

        accessors.append({"bufferView": pv, "componentType": 5126,
                          "count": len(pos), "type": "VEC3",
                          "min": pos.min(0).tolist(), "max": pos.max(0).tolist()})
        p_acc = len(accessors) - 1
        accessors.append({"bufferView": nv, "componentType": 5126,
                          "count": len(nrm), "type": "VEC3"})
        n_acc = len(accessors) - 1
        accessors.append({"bufferView": tv, "componentType": 5126,
                          "count": len(uv), "type": "VEC2"})
        t_acc = len(accessors) - 1
        accessors.append({"bufferView": iv, "componentType": 5125,
                          "count": len(idx), "type": "SCALAR"})
        i_acc = len(accessors) - 1

        primitives.append({"attributes": {"POSITION": p_acc, "NORMAL": n_acc,
                                          "TEXCOORD_0": t_acc},
                           "indices": i_acc, "material": MAT_INDEX[mat],
                           "mode": 4})

    # ---- embedded textures ----
    tex = textures()
    images, textures_json = [], []
    tex_index = {}
    for m in MATERIALS:
        if m in tex and scene.groups[m]["idx"]:
            iv = add_view(tex[m], None)
            buffer_views[iv].pop("target")
            images.append({"mimeType": "image/png", "bufferView": iv,
                           "name": m})
            textures_json.append({"sampler": 0, "source": len(images) - 1})
            tex_index[m] = len(textures_json) - 1

    materials_json = []
    for m in MATERIALS:
        pbr = {"metallicFactor": MATERIALS[m][1],
               "roughnessFactor": MATERIALS[m][2]}
        if m in tex_index:
            pbr["baseColorTexture"] = {"index": tex_index[m]}
            pbr["baseColorFactor"] = [1.0, 1.0, 1.0, 1.0]
        else:
            pbr["baseColorFactor"] = [*MATERIALS[m][0], 1.0]
        materials_json.append(
            {"name": m, "pbrMetallicRoughness": pbr, "doubleSided": False})

    gltf = {
        "asset": {"version": "2.0",
                  "generator": "Baytak AR blueprint_to_glb (demo pipeline)"},
        "scene": 0,
        "scenes": [{"nodes": [0], "name": name}],
        "nodes": [{"mesh": 0, "name": name}],
        "meshes": [{"name": name, "primitives": primitives}],
        "materials": materials_json,
        "samplers": [{"magFilter": 9729, "minFilter": 9987,
                      "wrapS": 10497, "wrapT": 10497}],
        "images": images,
        "textures": textures_json,
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": len(bin_blob)}],
    }

    json_bytes = pad4(bytearray(json.dumps(gltf, separators=(",", ":")).encode()), b" ")
    bin_bytes = pad4(bytearray(bin_blob))
    total = 12 + 8 + len(json_bytes) + 8 + len(bin_bytes)

    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))          # glTF header
        f.write(struct.pack("<II", len(json_bytes), 0x4E4F534A))    # JSON chunk
        f.write(json_bytes)
        f.write(struct.pack("<II", len(bin_bytes), 0x004E4942))     # BIN chunk
        f.write(bin_bytes)

    tris = sum(len(g["idx"]) // 3 for g in scene.groups.values())
    print(f"  wrote {path.name}: {total/1024:.1f} KB, {tris} triangles")

# ----------------------------------------------------------------------------
# 4. The parametric layout - this is what a blueprint parser would output
# ----------------------------------------------------------------------------
LAYOUT = {
    "name": "K-01 L-Shape + Island",
    "room": {"w": 4.20, "d": 3.40, "h": 2.70, "wall_t": 0.12},
    "north_run": {  # along z=0 wall
        "segments": [0.60, 0.90, 0.60, 0.60, 0.90, 0.60],  # sums to 4.20
        "sink_seg": 1, "range_seg": 3,
    },
    "west_run": {"z0": 0.60, "z1": 2.55, "segments": [0.65, 0.65, 0.65]},
    "fridge": {"z0": 2.57, "z1": 3.29, "w": 0.72},
    "island": {"x0": 1.55, "x1": 3.15, "z0": 1.75, "z1": 2.65},
    "window": {"x0": 0.62, "x1": 1.48, "y0": 1.18, "y1": 2.02},
    "uppers": {"y0": 1.50, "y1": 2.20, "d": 0.35,
               "spans": [(0.02, 1.95), (2.85, 4.18)]},  # gap = hood
    "dims": {"base_d": 0.60, "base_h": 0.86, "counter_t": 0.04,
             "counter_over": 0.025, "toe_h": 0.10, "toe_inset": 0.055},
}

# ----------------------------------------------------------------------------
# 5. Kitchen builder: layout dict -> boxes
# ----------------------------------------------------------------------------
def handle(s, cx, y, z_face, horizontal=True, length=0.16, out=0.03):
    """Brass bar handle proud of a front face at z_face (facing +z)."""
    t = 0.011
    if horizontal:
        s.box((cx - length/2, y - t/2, z_face + 0.004),
              (cx + length/2, y + t/2, z_face + out), "brass")
    else:
        s.box((cx - t/2, y - length/2, z_face + 0.004),
              (cx + t/2, y + length/2, z_face + out), "brass")

def handle_x(s, x_face, y, cz, length=0.16, out=0.03):
    """Handle proud of a face pointing +x."""
    t = 0.011
    s.box((x_face + 0.004, y - t/2, cz - length/2),
          (x_face + out,   y + t/2, cz + length/2), "brass")

def build_kitchen(L):
    s = Scene()
    R, D = L["room"], L["dims"]
    W, DP, H, WT = R["w"], R["d"], R["h"], R["wall_t"]
    BD, BH, CT, CO, TH, TI = (D["base_d"], D["base_h"], D["counter_t"],
                              D["counter_over"], D["toe_h"], D["toe_inset"])
    CTOP = BH + CT  # 0.90 counter top height

    # --- shell -------------------------------------------------------------
    s.box((-WT, -0.05, -WT), (W + WT, 0.0, DP + WT), "floor_travertine")
    s.box((-WT, 0.0, -WT), (W + WT, H, 0.0), "wall_sand")   # north
    s.box((-WT, 0.0, 0.0), (0.0, H, DP + WT), "wall_sand")  # west

    # --- window over sink (in north wall) -----------------------------------
    win = L["window"]
    s.box((win["x0"], win["y0"], -0.03), (win["x1"], win["y1"], -0.006), "window_glass")
    fw = 0.045
    for mn, mx in [
        ((win["x0"]-fw, win["y0"]-fw, -0.035), (win["x1"]+fw, win["y0"], 0.012)),
        ((win["x0"]-fw, win["y1"], -0.035), (win["x1"]+fw, win["y1"]+fw, 0.012)),
        ((win["x0"]-fw, win["y0"], -0.035), (win["x0"], win["y1"], 0.012)),
        ((win["x1"], win["y0"], -0.035), (win["x1"]+fw, win["y1"], 0.012)),
    ]:
        s.box(mn, mx, "white_frame")
    mid = (win["x0"] + win["x1"]) / 2
    s.box((mid - 0.015, win["y0"], -0.028), (mid + 0.015, win["y1"], -0.002), "white_frame")

    # --- backsplash (sage), skipping the window opening ---------------------
    bs_z = 0.018
    s.box((0.0, CTOP, 0.0), (win["x0"]-fw, 1.50, bs_z), "backsplash_sage")
    s.box((win["x1"]+fw, CTOP, 0.0), (W, 1.50, bs_z), "backsplash_sage")
    s.box((win["x0"]-fw, CTOP, 0.0), (win["x1"]+fw, win["y0"]-fw, bs_z), "backsplash_sage")
    s.box((0.0, CTOP, 0.60), (bs_z, 1.50, L["west_run"]["z1"]), "backsplash_sage")

    # --- north base run ------------------------------------------------------
    seg_w = L["north_run"]["segments"]
    edges = np.concatenate([[0], np.cumsum(seg_w)])
    sink_i, range_i = L["north_run"]["sink_seg"], L["north_run"]["range_seg"]
    s.box((TI, 0.0, 0.0), (W - 0.01, TH, BD - TI), "toe_kick")
    s.box((0.0, TH, 0.0), (W, BH, BD), "cab_walnut")
    front = BD  # z of cabinet front face
    for i, (a, b) in enumerate(zip(edges[:-1], edges[1:])):
        if i == range_i:
            continue  # range slots in here
        gap = 0.009
        # drawer front
        s.box((a+gap, 0.640, front), (b-gap, 0.835, front+0.017), "cab_walnut_door")
        handle(s, (a+b)/2, 0.80, front+0.017)
        # door(s)
        if b - a > 0.75:
            m = (a + b) / 2
            for da, db in [(a+gap, m-gap/2), (m+gap/2, b-gap)]:
                s.box((da, TH+0.008, front), (db, 0.615, front+0.017), "cab_walnut_door")
                cx = da + 0.03 if da < m else db - 0.03
                handle(s, cx, 0.56, front+0.017, horizontal=False, length=0.14)
        else:
            s.box((a+gap, TH+0.008, front), (b-gap, 0.615, front+0.017), "cab_walnut_door")
            handle(s, b-0.035, 0.56, front+0.017, horizontal=False, length=0.14)

    # counters (basalt) with overhang
    s.box((0.0, BH, 0.0), (W, CTOP, BD + CO), "counter_basalt")
    wz0, wz1 = L["west_run"]["z0"], L["west_run"]["z1"]
    s.box((0.0, BH, wz0), (BD + CO, CTOP, wz1), "counter_basalt")

    # --- sink + faucet -------------------------------------------------------
    sx0, sx1 = edges[sink_i] + 0.09, edges[sink_i + 1] - 0.09
    sz0, sz1 = 0.09, 0.50
    s.box((sx0, CTOP+0.0005, sz0), (sx1, CTOP+0.002, sz1), "black_matte")
    rim = 0.02
    for mn, mx in [
        ((sx0-rim, CTOP, sz0-rim), (sx1+rim, CTOP+0.012, sz0)),
        ((sx0-rim, CTOP, sz1), (sx1+rim, CTOP+0.012, sz1+rim)),
        ((sx0-rim, CTOP, sz0), (sx0, CTOP+0.012, sz1)),
        ((sx1, CTOP, sz0), (sx1+rim, CTOP+0.012, sz1)),
    ]:
        s.box(mn, mx, "steel")
    fx = (sx0 + sx1) / 2
    s.cylinder(fx, 0.055, CTOP, CTOP + 0.31, 0.014, "steel")
    s.box((fx-0.012, CTOP+0.286, 0.055), (fx+0.012, CTOP+0.310, 0.250), "steel")
    s.cylinder(fx, 0.235, CTOP + 0.235, CTOP + 0.288, 0.010, "steel")

    # --- range (slide-in) + cooktop + hood ----------------------------------
    rx0, rx1 = edges[range_i], edges[range_i + 1]
    s.box((rx0+0.008, TH, 0.02), (rx1-0.008, BH, front+0.028), "steel")
    s.box((rx0+0.05, 0.15, front+0.028), (rx1-0.05, 0.55, front+0.037), "black_matte")
    s.box((rx0+0.03, 0.60, front+0.028), (rx1-0.03, 0.635, front+0.062), "steel")
    s.box((rx0+0.02, CTOP-0.002, 0.05), (rx1-0.02, CTOP+0.014, 0.57), "black_matte")
    for bx in (rx0+0.16, rx1-0.16):
        for bz in (0.19, 0.43):
            s.box((bx-0.075, CTOP+0.014, bz-0.075),
                  (bx+0.075, CTOP+0.020, bz+0.075), "steel")
    # hood
    s.box((rx0-0.05, 1.42, 0.02), (rx1+0.05, 1.52, 0.53), "steel")
    s.box((rx0+0.17, 1.52, 0.06), (rx1-0.17, H, 0.34), "steel")

    # --- upper cabinets (north) ---------------------------------------------
    U = L["uppers"]
    for ux0, ux1 in U["spans"]:
        s.box((ux0, U["y0"], 0.0), (ux1, U["y1"], U["d"]), "cab_walnut")
        n_doors = max(1, round((ux1 - ux0) / 0.55))
        dw = (ux1 - ux0) / n_doors
        for k in range(n_doors):
            a, b = ux0 + k*dw + 0.008, ux0 + (k+1)*dw - 0.008
            s.box((a, U["y0"]+0.008, U["d"]), (b, U["y1"]-0.008, U["d"]+0.015),
                  "cab_walnut_door")
            handle(s, (a+b)/2, U["y0"]+0.05, U["d"]+0.015)

    # --- west run -------------------------------------------------------------
    s.box((0.0, 0.0, wz0+TI*0), (BD - TI, TH, wz1), "toe_kick")
    s.box((0.0, TH, wz0), (BD, BH, wz1), "cab_walnut")
    zedges = np.concatenate([[wz0], wz0 + np.cumsum(L["west_run"]["segments"])])
    for a, b in zip(zedges[:-1], zedges[1:]):
        gap = 0.009
        s.box((BD, 0.640, a+gap), (BD+0.017, 0.835, b-gap), "cab_walnut_door")
        handle_x(s, BD+0.017, 0.80, (a+b)/2)
        s.box((BD, TH+0.008, a+gap), (BD+0.017, 0.615, b-gap), "cab_walnut_door")
        handle_x(s, BD+0.017, 0.56, b-0.04, length=0.14)

    # open oak shelves + decor above west run
    for sy in (1.38, 1.76):
        s.box((0.02, sy, 0.80), (0.34, sy+0.032, 2.35), "cab_walnut")
    s.cylinder(0.18, 0.95, 1.412, 1.582, 0.055, "ceramic_white")
    s.cylinder(0.18, 1.22, 1.412, 1.642, 0.045, "ceramic_black")
    s.box((0.10, 1.412, 1.585), (0.26, 1.532, 1.745), "ceramic_white")
    s.cylinder(0.18, 2.05, 1.792, 1.884, 0.062, "ceramic_white")
    s.cylinder(0.18, 2.05, 1.878, 2.095, 0.050, "plant_green")
    s.cylinder(0.18, 1.42, 1.792, 1.942, 0.040, "ceramic_black")

    # --- fridge + cabinet above ----------------------------------------------
    F = L["fridge"]
    fz0, fz1, fw_ = F["z0"], F["z1"], F["w"]
    s.box((0.02, 0.0, fz0), (0.02+fw_, 1.86, fz1), "steel")
    s.box((0.02, 1.095, fz1), (0.02+fw_, 1.115, fz1+0.004), "black_matte")
    for hy0, hy1 in [(0.38, 1.04), (1.18, 1.72)]:
        s.box((0.02+fw_*0.42, hy0, fz1), (0.02+fw_*0.42+0.03, hy1, fz1+0.035), "steel")
    s.box((0.0, 1.92, fz0), (0.02+fw_, 2.20, fz1-0.05), "cab_walnut")
    s.box((0.0+0.008, 1.928, fz1-0.05), ((0.02+fw_)-0.008, 2.192, fz1-0.035),
          "cab_walnut_door")

    # --- island (olive) -------------------------------------------------------
    I = L["island"]
    ix0, ix1, iz0, iz1 = I["x0"], I["x1"], I["z0"], I["z1"]
    s.box((ix0+TI, 0.0, iz0+TI), (ix1-TI, TH, iz1-TI), "toe_kick")
    s.box((ix0, TH, iz0), (ix1, BH, iz1), "island_olive")
    # quartz top with seating overhang toward +z
    s.box((ix0-0.05, BH, iz0-0.05), (ix1+0.05, CTOP, iz1+0.30), "counter_quartz")
    # working-side fronts (facing the range, -z direction)
    n_p = 3
    pw = (ix1 - ix0) / n_p
    for k in range(n_p):
        a, b = ix0 + k*pw + 0.009, ix0 + (k+1)*pw - 0.009
        s.box((a, 0.640, iz0-0.017), (b, 0.835, iz0), "island_olive_door")
        s.box((a, TH+0.008, iz0-0.017), (b, 0.615, iz0), "island_olive_door")
        t = 0.011
        s.box(((a+b)/2-0.08, 0.80-t/2, iz0-0.031), ((a+b)/2+0.08, 0.80+t/2, iz0-0.004), "brass")
        s.box((b-0.04-t/2, 0.49, iz0-0.031), (b-0.04+t/2, 0.63, iz0-0.004), "brass")

    # stools (x2) on seating side - round tops, brass footrest
    for cx in (ix0 + 0.50, ix1 - 0.50):
        cz = iz1 + 0.42
        s.cylinder(cx, cz, 0.60, 0.648, 0.185, "stool_wood")
        for a in (0.785, 2.356, 3.927, 5.498):
            lx, lz = cx + 0.130*np.cos(a), cz + 0.130*np.sin(a)
            s.cylinder(lx, lz, 0.0, 0.60, 0.016, "stool_wood", seg=10)
        s.cylinder(cx, cz, 0.215, 0.240, 0.150, "brass", seg=20)

    # pendants over island - brass stem, drum shade
    for cx in (ix0 + 0.45, ix1 - 0.45):
        cz = (iz0 + iz1) / 2
        s.cylinder(cx, cz, 2.02, H, 0.009, "brass", seg=10)
        s.cylinder(cx, cz, 1.86, 2.02, 0.105, "black_matte")
        s.cylinder(cx, cz, 1.848, 1.862, 0.055, "brass", seg=12)

    return s

# ----------------------------------------------------------------------------
# 6. Sofa builder (single-furniture demo item)
# ----------------------------------------------------------------------------
def build_sofa():
    s = Scene()
    hx, hz = 1.10, 0.475
    # legs (round oak)
    for lx in (-hx+0.09, hx-0.09):
        for lz in (-hz+0.08, hz-0.08):
            s.cylinder(lx, lz, 0.0, 0.11, 0.022, "stool_wood", seg=12)
    s.box((-hx, 0.11, -hz), (hx, 0.42, hz), "fabric_taupe")                # base
    s.box((-hx, 0.42, -hz), (-hx+0.22, 0.66, hz), "fabric_taupe")          # arm L
    s.box((hx-0.22, 0.42, -hz), (hx, 0.66, hz), "fabric_taupe")            # arm R
    s.box((-hx+0.22, 0.42, -hz), (hx-0.22, 0.86, -hz+0.20), "fabric_taupe")  # back
    inner_w = 2 * (hx - 0.22)
    cw = inner_w / 3
    for k in range(3):
        a = -hx + 0.22 + k*cw + 0.012
        b = -hx + 0.22 + (k+1)*cw - 0.012
        s.box((a, 0.42, -hz+0.21), (b, 0.585, hz-0.03), "fabric_dark")     # seat
        s.box((a, 0.585, -hz+0.20), (b, 0.84, -hz+0.38), "fabric_taupe")   # back cushion
    return s

def build_armchair():
    """'Rum' armchair - walnut shell, olive cushions, brass foot caps."""
    s = Scene()
    hx, hz = 0.43, 0.41
    for lx in (-hx + 0.075, hx - 0.075):
        for lz in (-hz + 0.075, hz - 0.075):
            s.cylinder(lx, lz, 0.0, 0.016, 0.023, "brass", seg=12)
            s.cylinder(lx, lz, 0.016, 0.10, 0.021, "stool_wood", seg=12)
    s.box((-hx + 0.02, 0.10, -hz + 0.02), (hx - 0.02, 0.30, hz - 0.02), "fabric_dark")
    s.box((-hx, 0.10, -hz), (-hx + 0.10, 0.56, hz), "cab_walnut_door")   # arm L
    s.box((hx - 0.10, 0.10, -hz), (hx, 0.56, hz), "cab_walnut_door")    # arm R
    s.box((-hx + 0.10, 0.10, -hz), (hx - 0.10, 0.72, -hz + 0.08), "cab_walnut_door")  # back shell
    s.box((-hx + 0.11, 0.30, -hz + 0.09), (hx - 0.11, 0.44, hz - 0.05), "island_olive")       # seat
    s.box((-hx + 0.11, 0.42, -hz + 0.085), (hx - 0.11, 0.70, -hz + 0.24), "island_olive_door")  # back cushion
    s.box((-0.17, 0.44, -hz + 0.24), (0.17, 0.58, -hz + 0.335), "fabric_taupe")               # lumbar pillow
    return s

def build_dining():
    """'Ajloun' dining set - walnut table 1.60x0.90 + four chairs."""
    s = Scene()
    hx, hz = 0.80, 0.45
    s.box((-hx, 0.705, -hz), (hx, 0.75, hz), "cab_walnut_door")          # top
    s.box((-0.72, 0.650, -0.41), (0.72, 0.705, 0.41), "cab_walnut")      # apron
    for lx in (-0.70, 0.70):
        for lz in (-0.35, 0.35):
            s.cylinder(lx, lz, 0.0, 0.705, 0.034, "stool_wood")
    def chair(cx, side):  # side = +1 (front) / -1 (back)
        z0, z1 = (0.50, 0.98) if side > 0 else (-0.98, -0.50)
        back_a, back_b = (0.93, 0.98) if side > 0 else (-0.98, -0.93)
        for lx in (cx - 0.175, cx + 0.175):
            for lz in (min(z0, z1) + 0.05, max(z0, z1) - 0.05):
                s.cylinder(lx, lz, 0.0, 0.42, 0.019, "stool_wood", seg=10)
        s.box((cx - 0.22, 0.42, z0), (cx + 0.22, 0.46, z1), "cab_walnut_door")   # seat slab
        s.box((cx - 0.20, 0.46, min(z0, z1) + 0.03),
              (cx + 0.20, 0.505, max(z0, z1) - 0.03), "fabric_taupe")            # cushion
        for px in (cx - 0.22, cx + 0.175):                                       # back posts
            s.box((px, 0.42, back_a), (px + 0.045, 0.90, back_b), "stool_wood")
        s.box((cx - 0.175, 0.60, back_a), (cx + 0.175, 0.86, back_b), "cab_walnut_door")  # back panel
    for cx in (-0.40, 0.40):
        chair(cx, +1)
        chair(cx, -1)
    return s

def build_shelf():
    """'Petra' shelf - walnut frame, sage back, styled decor."""
    s = Scene()
    hx, d = 0.45, 0.16
    s.box((-hx, 0.0, -d), (-hx + 0.035, 1.80, d), "cab_walnut")           # side L
    s.box((hx - 0.035, 0.0, -d), (hx, 1.80, d), "cab_walnut")             # side R
    s.box((-hx + 0.035, 1.765, -d), (hx - 0.035, 1.80, d), "cab_walnut")  # top
    s.box((-hx + 0.035, 0.0, -d), (hx - 0.035, 0.06, d), "toe_kick")      # plinth
    s.box((-hx + 0.035, 0.06, -d), (hx - 0.035, 1.765, -d + 0.025), "backsplash_sage")
    for sy in (0.42, 0.78, 1.14, 1.50):
        s.box((-hx + 0.035, sy, -d + 0.025), (hx - 0.035, sy + 0.03, d - 0.005), "cab_walnut_door")
    # decor: book runs, a plant, ceramics, one brass object
    def books(x0, y, mats, hs):
        x = x0
        for m, h in zip(mats, hs):
            s.box((x, y, -d + 0.05), (x + 0.028, y + h, d - 0.045), m)
            x += 0.033
    books(-0.36, 0.45, ["island_olive", "fabric_dark", "plant_green", "island_olive_door", "fabric_dark"],
          [0.24, 0.21, 0.26, 0.22, 0.25])
    books(0.05, 0.81, ["fabric_dark", "island_olive", "fabric_taupe", "plant_green"],
          [0.22, 0.25, 0.20, 0.24])
    s.cylinder(-0.21, 0.0, 0.81, 0.975, 0.068, "ceramic_white")   # vase
    s.cylinder(0.19, 0.0, 1.17, 1.335, 0.055, "ceramic_black")    # tall vessel
    s.cylinder(-0.25, 0.0, 1.17, 1.285, 0.065, "ceramic_white")   # planter
    s.cylinder(-0.25, 0.0, 1.278, 1.455, 0.052, "plant_green")    # plant
    s.cylinder(-0.02, 0.0, 1.53, 1.655, 0.046, "brass", seg=14)   # brass object
    books(0.14, 1.53, ["island_olive", "fabric_dark", "island_olive_door"], [0.20, 0.17, 0.19])
    return s

# ----------------------------------------------------------------------------
# 7. Blueprint PNG (the 2D drawing the pipeline "reads")
# ----------------------------------------------------------------------------
def draw_blueprint(L, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle, Arc, Circle

    R = L["room"]; W, DP, WT = R["w"], R["d"], R["wall_t"]
    ink = "#1d3557"; paper = "#f4f1e8"; hatch_c = "#5d7ba3"

    fig, ax = plt.subplots(figsize=(11, 9.6), dpi=170)
    fig.patch.set_facecolor(paper); ax.set_facecolor(paper)

    # faint 0.5 m grid
    for gx in np.arange(-0.5, W + 1.01, 0.5):
        ax.plot([gx, gx], [-0.9, DP + 0.6], color=ink, lw=0.25, alpha=0.15, zorder=0)
    for gz in np.arange(-0.5, DP + 0.61, 0.5):
        ax.plot([-0.9, W + 0.9], [gz, gz], color=ink, lw=0.25, alpha=0.15, zorder=0)

    def wall(x0, z0, x1, z1):
        ax.add_patch(Rectangle((x0, z0), x1-x0, z1-z0, facecolor=ink,
                               edgecolor=ink, hatch="////", lw=1.0, zorder=3, alpha=0.9))
    wall(-WT, -WT, W+WT, 0)          # north (top of plan)
    wall(-WT, 0, 0, DP+WT)           # west
    # open edges shown as thin dashed lines
    ax.plot([0, W+WT], [DP, DP], color=ink, lw=1.0, ls=(0, (6, 4)), zorder=2)
    ax.plot([W, W], [0, DP], color=ink, lw=1.0, ls=(0, (6, 4)), zorder=2)
    ax.text(W/2+0.3, DP+0.13, "OPEN TO LIVING / DINING", fontsize=7.5,
            color=ink, ha="center", family="monospace")

    def unit(x0, z0, x1, z1, label=None):
        ax.add_patch(Rectangle((x0, z0), x1-x0, z1-z0, fill=False,
                               edgecolor=ink, lw=1.3, zorder=4))
        ax.plot([x0, x1], [z0, z1], color=ink, lw=0.5, alpha=0.5, zorder=4)
        if label:
            ax.text((x0+x1)/2, (z0+z1)/2 - 0.02, label, fontsize=7, color=ink,
                    ha="center", va="center", family="monospace", zorder=6,
                    bbox=dict(fc=paper, ec="none", pad=0.6))

    # north run units
    edges = np.concatenate([[0], np.cumsum(L["north_run"]["segments"])])
    for i, (a, b) in enumerate(zip(edges[:-1], edges[1:])):
        unit(a, 0, b, 0.60)
    # west run units
    wz0 = L["west_run"]["z0"]
    zedges = np.concatenate([[wz0], wz0 + np.cumsum(L["west_run"]["segments"])])
    for a, b in zip(zedges[:-1], zedges[1:]):
        unit(0, a, 0.60, b)

    # sink (double bowl) in segment 1
    sx0, sx1 = edges[1]+0.12, edges[2]-0.12
    for bx0, bx1 in [(sx0, (sx0+sx1)/2-0.03), ((sx0+sx1)/2+0.03, sx1)]:
        ax.add_patch(Rectangle((bx0, 0.12), bx1-bx0, 0.36, fill=False,
                               edgecolor=ink, lw=1.1, zorder=5))
    ax.add_patch(Circle(((sx0+sx1)/2, 0.09), 0.03, fill=False, ec=ink, lw=1, zorder=5))
    ax.text((sx0+sx1)/2, -0.62, "SINK 90", fontsize=7.5, ha="center",
            color=ink, family="monospace")

    # range with 4 burners
    rx0, rx1 = edges[3], edges[4]
    ax.add_patch(Rectangle((rx0+0.02, 0.02), (rx1-rx0)-0.04, 0.56, fill=False,
                           edgecolor=ink, lw=1.6, zorder=5))
    for bx in (rx0+0.17, rx1-0.17):
        for bz in (0.18, 0.42):
            ax.add_patch(Circle((bx, bz), 0.075, fill=False, ec=ink, lw=1.1, zorder=5))
    ax.text((rx0+rx1)/2, -0.62, "RANGE 60\n+ HOOD", fontsize=7.5, ha="center",
            va="top" if False else "center", color=ink, family="monospace")

    # fridge
    F = L["fridge"]
    ax.add_patch(Rectangle((0.02, F["z0"]), F["w"], F["z1"]-F["z0"], fill=False,
                           edgecolor=ink, lw=1.6, zorder=5))
    ax.plot([0.02, 0.02+F["w"]], [F["z0"], F["z1"]], color=ink, lw=0.8, zorder=5)
    ax.plot([0.02, 0.02+F["w"]], [F["z1"], F["z0"]], color=ink, lw=0.8, zorder=5)
    ax.text(0.38+0.62, (F["z0"]+F["z1"])/2, "REF.", fontsize=8, color=ink,
            family="monospace", va="center")

    # window (triple line) on north wall
    win = L["window"]
    for off in (-0.085, -0.06, -0.035):
        ax.plot([win["x0"], win["x1"]], [off, off], color=ink, lw=1.2, zorder=5)
    ax.text((win["x0"]+win["x1"])/2, -0.30, "WINDOW 90", fontsize=7, ha="center",
            color=ink, family="monospace")

    # island + stools + hatch top
    I = L["island"]
    ax.add_patch(Rectangle((I["x0"], I["z0"]), I["x1"]-I["x0"], I["z1"]-I["z0"],
                           fill=False, edgecolor=ink, lw=1.6, zorder=5))
    ax.add_patch(Rectangle((I["x0"]-0.05, I["z0"]-0.05), (I["x1"]-I["x0"])+0.10,
                           (I["z1"]-I["z0"])+0.35, fill=False, edgecolor=ink,
                           lw=0.8, ls=(0, (3, 3)), zorder=5))
    ax.text((I["x0"]+I["x1"])/2, (I["z0"]+I["z1"])/2, "ISLAND\n160 x 90",
            fontsize=8, ha="center", va="center", color=ink, family="monospace")
    for cx in (I["x0"]+0.50, I["x1"]-0.50):
        ax.add_patch(Circle((cx, I["z1"]+0.42), 0.17, fill=False, ec=ink, lw=1.1, zorder=5))

    # dimension helper
    def dim(x0, z0, x1, z1, text, offset=(0, 0.22), rot=0):
        ax.annotate("", xy=(x1, z1), xytext=(x0, z0),
                    arrowprops=dict(arrowstyle="<|-|>", color=ink, lw=1.0,
                                    shrinkA=0, shrinkB=0), zorder=6)
        ax.text((x0+x1)/2 + offset[0], (z0+z1)/2 + offset[1], text, fontsize=8.5,
                ha="center", va="center", color=ink, family="monospace",
                rotation=rot, bbox=dict(fc=paper, ec="none", pad=1.0), zorder=7)

    dim(0, -0.98, W, -0.98, "4.20 m")
    dim(-0.95, 0, -0.95, DP, "3.40 m", offset=(-0.24, 0), rot=90)
    dim(I["x0"], I["z1"]+0.78, I["x1"], I["z1"]+0.78, "1.60 m", offset=(0, 0.18))
    dim(0.60, 1.30, I["x0"], 1.30, "0.95", offset=(0, 0.17))

    # north arrow + title block
    ax.annotate("N", xy=(W+0.62, 0.62), xytext=(W+0.62, 1.30), fontsize=11,
                color=ink, ha="center", family="monospace",
                arrowprops=dict(arrowstyle="-|>", color=ink, lw=1.4))
    tb_y = DP + 0.34
    ax.text(-WT, tb_y + 0.30, "BAYTAK AR  |  DEMO BLUEPRINT K-01",
            fontsize=13, color=ink, family="monospace", weight="bold")
    ax.text(-WT, tb_y + 0.10,
            "L-SHAPED KITCHEN WITH ISLAND   SCALE 1:50   UNITS: m / cm",
            fontsize=8.5, color=ink, family="monospace")
    ax.text(-WT, tb_y - 0.08,
            "AUTO-TRACED FOR DEMO -> tools/generate_assets.py -> demo_kitchen.glb",
            fontsize=8.5, color=ink, family="monospace", alpha=0.85)

    ax.set_xlim(-1.35, W + 1.05)
    ax.set_ylim(DP + 0.85, -1.35)  # inverted: north at top
    ax.set_aspect("equal"); ax.axis("off")
    fig.tight_layout(pad=0.4)
    fig.savefig(path, facecolor=paper)
    plt.close(fig)
    print(f"  wrote {path.name}")

# ----------------------------------------------------------------------------
# 8. Isometric verification render (for docs / sanity check)
# ----------------------------------------------------------------------------
def iso_render(scene: Scene, path, elev=24, azim=-118, title=""):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from mpl_toolkits.mplot3d.art3d import Poly3DCollection

    light = np.array([0.45, 0.85, 0.45]); light /= np.linalg.norm(light)
    quads, colors = [], []
    for mat, g in scene.groups.items():
        base = np.array(MATERIALS[mat][0])
        pos, nrm = np.array(g["pos"]), np.array(g["nrm"])
        for f in range(0, len(pos), 4):
            n = nrm[f]
            lam = 0.38 + 0.62 * max(float(np.dot(n, light)), 0.0)
            # matplotlib z-up: map (x,y,z)gl -> (x, z, y)
            quads.append([(p[0], p[2], p[1]) for p in pos[f:f+4]])
            colors.append(np.clip(base * lam, 0, 1))
    fig = plt.figure(figsize=(11, 8), dpi=150)
    ax = fig.add_subplot(111, projection="3d")
    ax.add_collection3d(Poly3DCollection(quads, facecolors=colors,
                                         edgecolors="none"))
    allp = np.array([p for q in quads for p in q])
    c = (allp.min(0) + allp.max(0)) / 2; r = (allp.max(0) - allp.min(0)).max() / 2
    ax.set_xlim(c[0]-r, c[0]+r); ax.set_ylim(c[1]-r, c[1]+r); ax.set_zlim(0, 2*r*0.92)
    ax.view_init(elev=elev, azim=azim)
    ax.set_axis_off(); ax.set_facecolor("#101418"); fig.patch.set_facecolor("#101418")
    if title:
        ax.set_title(title, color="#d8d2c4", fontsize=11, family="monospace", pad=0)
    fig.tight_layout(pad=0)
    fig.savefig(path, facecolor="#101418")
    plt.close(fig)
    print(f"  wrote {path.name}")

def product_render(scene: Scene, path, elev=15, azim=-142, size=(9, 9), dpi=100):
    """Catalogue-card render: warm sand background + soft ground shadow."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from mpl_toolkits.mplot3d.art3d import Poly3DCollection

    SAND, SHADOW = "#EFE7D8", "#DACFBA"
    light = np.array([0.45, 0.85, 0.45]); light /= np.linalg.norm(light)
    quads, colors = [], []
    for mat, g in scene.groups.items():
        base = np.array(MATERIALS[mat][0])
        pos, nrm = np.array(g["pos"]), np.array(g["nrm"])
        for f in range(0, len(pos), 4):
            lam = 0.40 + 0.60 * max(float(np.dot(nrm[f], light)), 0.0)
            jit = 0.965 + 0.07 * ((np.sin((len(quads) + 1) * 12.9898) * 43758.5453) % 1.0)
            quads.append([(p[0], p[2], p[1]) for p in pos[f:f+4]])
            colors.append(np.clip(base * lam * jit, 0, 1))
    allp = np.array([p for q in quads for p in q])
    c = (allp.min(0) + allp.max(0)) / 2
    ext = allp.max(0) - allp.min(0)
    r = ext.max() / 2 * 1.06

    # soft shadow ellipse under the footprint (drawn first, at y~0)
    th = np.linspace(0, 2 * np.pi, 40)
    sx, sz = ext[0] * 0.62 + 0.06, ext[1] * 0.62 + 0.06
    shadow = [[(c[0] + sx * np.cos(t), c[1] + sz * np.sin(t), 0.001) for t in th]]

    fig = plt.figure(figsize=size, dpi=dpi)
    ax = fig.add_subplot(111, projection="3d")
    ax.add_collection3d(Poly3DCollection(shadow, facecolors=SHADOW, edgecolors="none"))
    ax.add_collection3d(Poly3DCollection(quads, facecolors=colors, edgecolors="none"))
    ax.set_xlim(c[0]-r, c[0]+r); ax.set_ylim(c[1]-r, c[1]+r); ax.set_zlim(0, 2*r*0.88)
    ax.view_init(elev=elev, azim=azim)
    ax.set_axis_off(); ax.set_facecolor(SAND); fig.patch.set_facecolor(SAND)
    fig.tight_layout(pad=0)
    fig.savefig(path, facecolor=SAND)
    plt.close(fig)
    print(f"  wrote {path.name}")

# ----------------------------------------------------------------------------
def main():
    print("Building kitchen from layout ...")
    kitchen = build_kitchen(LAYOUT)
    write_glb(kitchen, MODELS / "demo_kitchen.glb", "Kitchen_K01")
    (PREVIEW / "kitchen_boxes.json").write_text(json.dumps({
        "meta": {"name": LAYOUT["name"], "room": LAYOUT["room"]},
        "materials": {m: {"color": MATERIALS[m][0], "metallic": MATERIALS[m][1],
                          "roughness": MATERIALS[m][2]} for m in MATERIALS},
        "boxes": kitchen.boxes_export,
    }, separators=(",", ":")))
    print(f"  wrote kitchen_boxes.json ({len(kitchen.boxes_export)} boxes)")

    # refresh the standalone HTML preview from its template
    tpl = PREVIEW / "kitchen_preview_template.html"
    if tpl.exists():
        html = tpl.read_text().replace(
            "__BOXDATA__", (PREVIEW / "kitchen_boxes.json").read_text())
        (PREVIEW / "kitchen_preview.html").write_text(html)
        print("  refreshed kitchen_preview.html")

    print("Building furniture ...")
    sofa = build_sofa()
    write_glb(sofa, MODELS / "sofa_rainbow.glb", "Sofa_Dana")
    armchair = build_armchair()
    write_glb(armchair, MODELS / "armchair_rum.glb", "Armchair_Rum")
    dining = build_dining()
    write_glb(dining, MODELS / "dining_ajloun.glb", "Dining_Ajloun")
    shelf = build_shelf()
    write_glb(shelf, MODELS / "shelf_petra.glb", "Shelf_Petra")

    print("Rendering catalogue thumbnails ...")
    THUMBS = ROOT / "flutter_app" / "assets" / "thumbs"
    THUMBS.mkdir(parents=True, exist_ok=True)
    product_render(kitchen,  THUMBS / "kitchen_k01.png",  elev=22, azim=-120)
    product_render(kitchen,  THUMBS / "kitchen_k01_wide.png",
                   elev=19, azim=-121, size=(12.8, 7.6), dpi=130)
    product_render(sofa,     THUMBS / "sofa_dana.png",    elev=14, azim=-142)
    product_render(armchair, THUMBS / "armchair_rum.png", elev=13, azim=-146)
    product_render(dining,   THUMBS / "dining_ajloun.png", elev=16, azim=-136)
    product_render(shelf,    THUMBS / "shelf_petra.png",  elev=8,  azim=-155)

    print("Drawing blueprint ...")
    draw_blueprint(LAYOUT, BLUEPRINTS / "demo_blueprint.png")

    print("Rendering verification views ...")
    iso_render(kitchen, DOCS / "kitchen_render.png",
               title="BAYTAK AR / K-01 generated from blueprint")
    iso_render(sofa, DOCS / "sofa_render.png", elev=16, azim=-142,
               title="BAYTAK AR / item: sofa 'Rainbow St.'")
    print("Done.")

if __name__ == "__main__":
    main()
