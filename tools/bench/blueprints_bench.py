#!/usr/bin/env python3
"""
Benchmark blueprints: three DELIBERATELY DIFFERENT kitchen drawings with
machine-readable ground truth, used by bench_models.py to measure how
faithfully each hosted vision model reads real layout variety (the v18
symptom: every drawing came back as roughly the same kitchen).

Drawn in the same architectural language as the bundled demo blueprint
(ink lines, hatched walls, printed dimensions) so results transfer.
"""

import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Circle, Rectangle

OUT = Path(__file__).resolve().parent / "out"
OUT.mkdir(parents=True, exist_ok=True)

INK, PAPER = "#1d3557", "#f4f1e8"


def _canvas(W, D, title):
    fig, ax = plt.subplots(figsize=(10, 9), dpi=150)
    fig.patch.set_facecolor(PAPER)
    ax.set_facecolor(PAPER)
    for gx in np.arange(-0.5, W + 1.01, 0.5):
        ax.plot([gx, gx], [-0.9, D + 0.6], color=INK, lw=0.25, alpha=0.15)
    for gz in np.arange(-0.5, D + 0.61, 0.5):
        ax.plot([-0.9, W + 0.9], [gz, gz], color=INK, lw=0.25, alpha=0.15)
    ax.text(-0.12, D + 0.65, title, fontsize=12, color=INK,
            family="monospace", weight="bold")
    return fig, ax


def _wall(ax, x0, z0, x1, z1):
    ax.add_patch(Rectangle((x0, z0), x1 - x0, z1 - z0, facecolor=INK,
                           edgecolor=INK, hatch="////", lw=1.0, alpha=0.9))


def _unit(ax, x0, z0, x1, z1):
    ax.add_patch(Rectangle((x0, z0), x1 - x0, z1 - z0, fill=False,
                           edgecolor=INK, lw=1.3))
    ax.plot([x0, x1], [z0, z1], color=INK, lw=0.5, alpha=0.5)


def _sink(ax, cx, cz, along_x=True, label_dz=-0.35):
    w, d = (0.62, 0.4) if along_x else (0.4, 0.62)
    for k in (0, 1):
        if along_x:
            bx0 = cx - w / 2 + k * (w / 2 + 0.02)
            ax.add_patch(Rectangle((bx0, cz - d / 2), w / 2 - 0.02, d,
                                   fill=False, edgecolor=INK, lw=1.1))
        else:
            bz0 = cz - d / 2 + k * (d / 2 + 0.02)
            ax.add_patch(Rectangle((cx - w / 2, bz0), w, d / 2 - 0.02,
                                   fill=False, edgecolor=INK, lw=1.1))
    ax.text(cx, cz + label_dz, "SINK", fontsize=7.5, ha="center",
            color=INK, family="monospace")


def _range(ax, cx, cz, along_x=True):
    w, d = (0.72, 0.55) if along_x else (0.55, 0.72)
    ax.add_patch(Rectangle((cx - w / 2, cz - d / 2), w, d, fill=False,
                           edgecolor=INK, lw=1.6))
    for bx in (-0.17, 0.17):
        for bz in (-0.13, 0.13):
            ax.add_patch(Circle((cx + bx, cz + bz), 0.07, fill=False,
                                ec=INK, lw=1.0))
    ax.text(cx, cz + (0.5 if along_x else 0.6), "RANGE 60", fontsize=7.5,
            ha="center", color=INK, family="monospace")


def _fridge(ax, x0, z0, x1, z1):
    ax.add_patch(Rectangle((x0, z0), x1 - x0, z1 - z0, fill=False,
                           edgecolor=INK, lw=1.6))
    ax.plot([x0, x1], [z0, z1], color=INK, lw=0.8)
    ax.plot([x0, x1], [z1, z0], color=INK, lw=0.8)
    ax.text((x0 + x1) / 2, z1 + 0.22, "REF.", fontsize=8, ha="center",
            color=INK, family="monospace")


def _window(ax, wall, W, D, center, width):
    a, b = center - width / 2, center + width / 2
    for off in (-0.085, -0.06, -0.035):
        if wall == "north":
            ax.plot([a, b], [off, off], color=INK, lw=1.2)
        elif wall == "west":
            ax.plot([off, off], [a, b], color=INK, lw=1.2)
        elif wall == "east":
            ax.plot([W - off, W - off], [a, b], color=INK, lw=1.2)
    label_pos = ((a + b) / 2, -0.28) if wall == "north" else \
        ((-0.5 if wall == "west" else W + 0.5), (a + b) / 2)
    ax.text(*label_pos, f"WINDOW {int(width*100)}", fontsize=7, ha="center",
            color=INK, family="monospace",
            rotation=0 if wall == "north" else 90)


def _dim(ax, x0, z0, x1, z1, text, offset=(0, 0.22), rot=0):
    ax.annotate("", xy=(x1, z1), xytext=(x0, z0),
                arrowprops=dict(arrowstyle="<|-|>", color=INK, lw=1.0,
                                shrinkA=0, shrinkB=0))
    ax.text((x0 + x1) / 2 + offset[0], (z0 + z1) / 2 + offset[1], text,
            fontsize=9, ha="center", va="center", color=INK,
            family="monospace", rotation=rot,
            bbox=dict(fc=PAPER, ec="none", pad=1.0))


def _finish(fig, ax, W, D, path):
    ax.set_xlim(-1.3, W + 1.1)
    ax.set_ylim(D + 0.9, -1.3)
    ax.set_aspect("equal")
    ax.axis("off")
    fig.tight_layout(pad=0.4)
    fig.savefig(path, facecolor=PAPER)
    plt.close(fig)


# --------------------------------------------------------------- BP-B galley
def galley():
    W, D = 2.8, 4.6
    fig, ax = _canvas(W, D, "PLAN 02 | GALLEY KITCHEN | SCALE 1:50")
    WT = 0.12
    _wall(ax, -WT, -WT, W + WT, 0)          # north
    _wall(ax, -WT, 0, 0, D + WT)            # west
    _wall(ax, W, 0, W + WT, D + WT)         # east
    ax.plot([0, W], [D, D], color=INK, lw=1.0, ls=(0, (6, 4)))
    ax.text(W / 2, D + 0.25, "OPEN TO DINING", fontsize=7.5, color=INK,
            ha="center", family="monospace")

    # west run z 0.9-4.4: fridge at start (0.9-1.7), sink at 3.0
    _fridge(ax, 0.02, 0.9, 0.74, 1.62)
    for a, b in [(1.7, 2.55), (2.55, 3.45), (3.45, 4.4)]:
        _unit(ax, 0, a, 0.6, b)
    _sink(ax, 0.32, 3.0, along_x=False, label_dz=0.0)

    # east run z 0.2-4.4: range at 1.9
    for a, b in [(0.2, 1.1), (1.1, 2.6), (2.6, 3.5), (3.5, 4.4)]:
        _unit(ax, W - 0.6, a, W, b)
    _range(ax, W - 0.3, 1.9, along_x=False)

    _window(ax, "west", W, D, 3.0, 0.9)
    _dim(ax, 0, -0.75, W, -0.75, "2.80 m")
    _dim(ax, -0.85, 0, -0.85, D, "4.60 m", offset=(-0.25, 0), rot=90)
    _dim(ax, 0.75, 1.9, W - 0.75, 1.9, "1.30", offset=(0, 0.2))
    _finish(fig, ax, W, D, OUT / "bp_galley.png")
    return {
        "name": "bp_galley",
        "width_m": 2.8, "depth_m": 4.6,
        "runs": [
            {"wall": "west", "from_m": 0.9, "to_m": 4.4, "sink_at_m": 3.0,
             "range_at_m": None, "fridge": "start"},
            {"wall": "east", "from_m": 0.2, "to_m": 4.4, "sink_at_m": None,
             "range_at_m": 1.9, "fridge": None},
        ],
        "island": {"present": False},
        "windows": [{"wall": "west", "center_m": 3.0, "width_m": 0.9}],
    }


# --------------------------------------------------------- BP-C single wall
def single_wall():
    W, D = 5.4, 3.2
    fig, ax = _canvas(W, D, "PLAN 03 | SINGLE-WALL KITCHEN | SCALE 1:50")
    WT = 0.12
    _wall(ax, -WT, -WT, W + WT, 0)  # north only
    ax.plot([0, 0], [0, D], color=INK, lw=1.0, ls=(0, (6, 4)))
    ax.plot([W, W], [0, D], color=INK, lw=1.0, ls=(0, (6, 4)))
    ax.plot([0, W], [D, D], color=INK, lw=1.0, ls=(0, (6, 4)))
    ax.text(W / 2, D + 0.25, "OPEN LIVING AREA", fontsize=7.5, color=INK,
            ha="center", family="monospace")

    # north run x 0.1-4.5 with sink 1.3, range 3.6; fridge at end 4.5-5.3
    for a, b in [(0.1, 0.95), (0.95, 1.75), (1.75, 3.2), (3.2, 4.0),
                 (4.0, 4.5)]:
        _unit(ax, a, 0, b, 0.6)
    _sink(ax, 1.3, 0.3, along_x=True, label_dz=0.62)
    _range(ax, 3.6, 0.3, along_x=True)
    _fridge(ax, 4.55, 0.02, 5.3, 0.77)
    _window(ax, "north", W, D, 1.3, 1.1)

    _dim(ax, 0, -0.75, W, -0.75, "5.40 m")
    _dim(ax, -0.85, 0, -0.85, D, "3.20 m", offset=(-0.25, 0), rot=90)
    _dim(ax, 0.1, 1.0, 4.5, 1.0, "4.40 m RUN", offset=(0, 0.2))
    _finish(fig, ax, W, D, OUT / "bp_single.png")
    return {
        "name": "bp_single",
        "width_m": 5.4, "depth_m": 3.2,
        "runs": [
            {"wall": "north", "from_m": 0.1, "to_m": 5.3, "sink_at_m": 1.3,
             "range_at_m": 3.6, "fridge": "end"},
        ],
        "island": {"present": False},
        "windows": [{"wall": "north", "center_m": 1.3, "width_m": 1.1}],
    }


# ------------------------------------------------------- BP-D L + peninsula
def l_peninsula():
    W, D = 3.6, 3.0
    fig, ax = _canvas(W, D, "PLAN 04 | L-KITCHEN + BAR | SCALE 1:50")
    WT = 0.12
    _wall(ax, -WT, -WT, W + WT, 0)   # north
    _wall(ax, W, 0, W + WT, D + WT)  # east
    ax.plot([0, 0], [0, D], color=INK, lw=1.0, ls=(0, (6, 4)))
    ax.plot([0, W], [D, D], color=INK, lw=1.0, ls=(0, (6, 4)))

    # north run x 0.1-3.5: sink 0.9, range 2.6
    for a, b in [(0.1, 1.4), (1.4, 2.2), (2.2, 3.0), (3.0, 3.5)]:
        _unit(ax, a, 0, b, 0.6)
    _sink(ax, 0.9, 0.3, along_x=True, label_dz=0.62)
    _range(ax, 2.6, 0.3, along_x=True)
    _window(ax, "north", W, D, 0.9, 0.8)

    # east run z 0.7-2.9 with fridge at start (0.7-1.5)
    _fridge(ax, W - 0.75, 0.72, W - 0.02, 1.47)
    for a, b in [(1.5, 2.2), (2.2, 2.9)]:
        _unit(ax, W - 0.6, a, W, b)

    # bar island 1.7 x 0.7 at (0.5, 1.9), stools south
    ax.add_patch(Rectangle((0.5, 1.9), 1.7, 0.7, fill=False,
                           edgecolor=INK, lw=1.6))
    ax.add_patch(Rectangle((0.45, 1.85), 1.8, 1.1, fill=False,
                           edgecolor=INK, lw=0.8, ls=(0, (3, 3))))
    ax.text(1.35, 2.25, "BAR 170x70", fontsize=8, ha="center", va="center",
            color=INK, family="monospace")
    for cx in (0.95, 1.75):
        ax.add_patch(Circle((cx, 2.95), 0.16, fill=False, ec=INK, lw=1.1))

    _dim(ax, 0, -0.75, W, -0.75, "3.60 m")
    _dim(ax, -0.85, 0, -0.85, D, "3.00 m", offset=(-0.25, 0), rot=90)
    _finish(fig, ax, W, D, OUT / "bp_lbar.png")
    return {
        "name": "bp_lbar",
        "width_m": 3.6, "depth_m": 3.0,
        "runs": [
            {"wall": "north", "from_m": 0.1, "to_m": 3.5, "sink_at_m": 0.9,
             "range_at_m": 2.6, "fridge": None},
            {"wall": "east", "from_m": 0.7, "to_m": 2.9, "sink_at_m": None,
             "range_at_m": None, "fridge": "start"},
        ],
        "island": {"present": True, "x_m": 0.5, "z_m": 1.9, "w_m": 1.7,
                   "d_m": 0.7, "seating": "south"},
        "windows": [{"wall": "north", "center_m": 0.9, "width_m": 0.8}],
    }


# --------------------------------------------- BP-E U-shape + bar peninsula
def u_peninsula():
    """Reconstruction of the owner's real test blueprint (2026-07): U-ish
    kitchen 3.2 x 3.76 m, counters on both side walls, double sink + fridge
    on the east run, bar peninsula with the cooktop attached to the west
    run, 0.91 m minimum walkway printed between peninsula and east run.
    This drawing produced the "counter covered the whole middle" failure.
    """
    W, D = 3.2, 3.76
    fig, ax = _canvas(W, D, "PLAN 05 | U-KITCHEN + BAR | SCALE 1:50")
    WT = 0.12
    _wall(ax, -WT, 0, 0, D + WT)             # west, full depth
    _wall(ax, W, 0, W + WT, 2.36)            # east, upper part only
    ax.plot([0, W], [0, 0], color=INK, lw=1.0, ls=(0, (6, 4)))
    ax.text(W / 2, -0.25, "OPEN", fontsize=7.5, color=INK,
            ha="center", family="monospace")
    ax.plot([W, W], [2.36, D], color=INK, lw=1.0, ls=(0, (6, 4)))
    ax.plot([0, W], [D, D], color=INK, lw=1.0, ls=(0, (6, 4)))

    # west run z 0.1-2.74 (stops where the peninsula takes over), tall
    # pantry unit drawn at the top
    for a, b in [(0.1, 1.0), (1.0, 1.9), (1.9, 2.74)]:
        _unit(ax, 0, a, 0.6, b)
    ax.add_patch(Rectangle((0.03, 0.15), 0.54, 0.8, fill=False,
                           edgecolor=INK, lw=1.6))
    ax.text(0.3, 0.58, "TALL", fontsize=6.5, ha="center", va="center",
            color=INK, family="monospace", rotation=90)

    # east run z 0.1-2.24: double sink at 1.15, fridge (dashed) at end
    for a, b in [(0.1, 0.8), (0.8, 1.5), (1.5, 2.24)]:
        _unit(ax, W - 0.6, a, W, b)
    _sink(ax, W - 0.3, 1.15, along_x=False, label_dz=0.0)
    ax.add_patch(Rectangle((W - 0.72, 1.52), 0.7, 0.72, fill=False,
                           edgecolor=INK, lw=1.3, ls=(0, (4, 3))))
    ax.text(W - 0.36, 1.95, "REF.", fontsize=8, ha="center",
            color=INK, family="monospace")

    # bar peninsula x 0-1.69, z 2.74-3.76 (bottom 0.41 is the raised bar),
    # cooktop on it, two stools south
    ax.add_patch(Rectangle((0, 2.74), 1.69, 1.02, fill=False,
                           edgecolor=INK, lw=1.6))
    ax.plot([0, 1.69], [3.35, 3.35], color=INK, lw=0.9)
    ax.text(0.84, 3.62, "BAR COUNTER", fontsize=7.5, ha="center",
            color=INK, family="monospace")
    for bx in (-0.24, 0.0, 0.24):
        ax.add_patch(Circle((0.85 + bx, 2.98), 0.085, fill=False, ec=INK,
                            lw=1.1))
    for bx in (-0.12, 0.12):
        ax.add_patch(Circle((0.85 + bx, 3.2), 0.085, fill=False, ec=INK,
                            lw=1.1))
    for cx in (0.5, 1.2):
        ax.add_patch(Circle((cx, 4.06), 0.16, fill=False, ec=INK, lw=1.1))

    # printed walkway: diagonal gap peninsula corner -> east counter corner
    _dim(ax, 1.69, 2.74, W - 0.6, 2.24, "0.91 m min", offset=(0.18, 0.3))

    _dim(ax, 0, -0.75, W, -0.75, "3.20 m")
    _dim(ax, -0.85, 0, -0.85, D, "3.76 m", offset=(-0.25, 0), rot=90)
    _dim(ax, W + 0.75, 0, W + 0.75, 2.24, "2.24 m", offset=(0.25, 0),
         rot=90)
    _dim(ax, 1.95, 2.74, 1.95, 3.76, "1.02", offset=(0.32, 0), rot=90)
    _finish(fig, ax, W, D, OUT / "bp_ushape.png")
    return {
        "name": "bp_ushape",
        "width_m": 3.2, "depth_m": 3.76,
        "runs": [
            {"wall": "west", "from_m": 0.1, "to_m": 2.74, "sink_at_m": None,
             "range_at_m": None, "fridge": None},
            {"wall": "east", "from_m": 0.1, "to_m": 2.24, "sink_at_m": 1.15,
             "range_at_m": None, "fridge": "end"},
        ],
        "island": {"present": True, "x_m": 0.0, "z_m": 2.74, "w_m": 1.69,
                   "d_m": 1.02, "seating": "south", "cooktop": True},
        "windows": [],
    }


def main():
    truths = [galley(), single_wall(), l_peninsula(), u_peninsula()]
    (OUT / "truths.json").write_text(json.dumps(truths, indent=1))
    print(f"wrote {len(truths)} blueprints + truths.json to {OUT}")


if __name__ == "__main__":
    main()
