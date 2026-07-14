#!/usr/bin/env python3
"""
Baytak AR - catalogue uploader (v17)
====================================
Pushes the demo catalogue (rows + GLBs + thumbnails) to a Supabase project
so the app pulls products from the cloud instead of the APK - the "sold to
a furniture store" configuration.

One-time setup:
  1. Create a free project at supabase.com.
  2. Run supabase/schema.sql in the SQL editor.
  3. export SUPABASE_URL=https://<ref>.supabase.co
     export SUPABASE_SERVICE_KEY=<service_role key>   # NEVER ships in-app
  4. python tools/upload_catalog.py
     (optional)  python tools/upload_catalog.py --nvidia-key nvapi-...
                 also publishes the demo NVIDIA key via demo_config.

Then build the app with:
  flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...

The SEED below mirrors flutter_app/lib/data/catalog.dart (the bundled
offline set). Retailers replace/extend it with their own feed.
"""

import argparse
import json
import mimetypes
import os
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "flutter_app" / "assets"

SEED = [
    {
        "id": "kitchen_k01",
        "title": "Kitchen K-01",
        "category": "kitchens",
        "blurb": "L-shape with island, generated as one model from its blueprint.",
        "description": (
            "The whole kitchen as one placeable model - not cabinet by cabinet. "
            "K-01 was generated directly from its blueprint: walnut runs along "
            "two walls, an olive island with seating for two, basalt worktops "
            "with a quartz island top, brass hardware and a sage subway "
            "backsplash. Counters at 90 cm, uppers at 150 cm, true appliance "
            "clearances. Stand inside it in AR before a single cabinet is built."
        ),
        "w_cm": 420, "d_cm": 340, "h_cm": 270,
        "materials": ["Walnut cabinetry", "Olive island", "Basalt + quartz tops",
                      "Brass hardware", "Sage backsplash"],
        "finishes": [0xFF6B4830, 0xFF465342, 0xFF26292B, 0xFFC79E54],
        "variants": ["L-shape + island"],
        "price_jd": 4850,
        "deal_price_jd": None,
        "camera_orbit": "-38deg 72deg 8.4m",
        "asset": "models/demo_kitchen.glb",
        "thumb": "thumbs/kitchen_k01.png",
        "hero": "thumbs/kitchen_k01_wide.png",
        "sort_order": 10,
    },
    {
        "id": "sofa_dana",
        "title": "Dana Sofa",
        "category": "living",
        "blurb": "Three seats in a taupe weave with solid oak legs.",
        "description": (
            "A deep three-seater in a warm taupe weave with charcoal seat "
            "cushions and turned solid-oak legs. Sized generously for family "
            "rooms - place it in AR to check the walkway behind it before "
            "committing."
        ),
        "w_cm": 220, "d_cm": 95, "h_cm": 86,
        "materials": ["Taupe weave", "Charcoal seats", "Oak legs"],
        "finishes": [0xFFA89482, 0xFF6B6156, 0xFF8C6A45],
        "variants": ["W 180", "W 220", "W 260"],
        "price_jd": 649,
        "deal_price_jd": 549,
        "camera_orbit": "-30deg 78deg 4.2m",
        "asset": "models/sofa_rainbow.glb",
        "thumb": "thumbs/sofa_dana.png",
        "hero": None,
        "sort_order": 20,
    },
    {
        "id": "armchair_rum",
        "title": "Rum Armchair",
        "category": "living",
        "blurb": "Walnut shell, olive cushions, brass foot caps.",
        "description": (
            "A compact lounge chair with a wrapping walnut shell, olive bouclé "
            "cushions and brass-capped legs. Made for reading corners and "
            "bedrooms - at 86 cm wide it fits where full armchairs will not."
        ),
        "w_cm": 86, "d_cm": 82, "h_cm": 72,
        "materials": ["Walnut shell", "Olive bouclé", "Brass feet"],
        "finishes": [0xFF465342, 0xFF7A5337, 0xFF3A3F4A],
        "variants": ["Standard"],
        "price_jd": 289,
        "deal_price_jd": None,
        "camera_orbit": "-30deg 76deg 2.4m",
        "asset": "models/armchair_rum.glb",
        "thumb": "thumbs/armchair_rum.png",
        "hero": None,
        "sort_order": 30,
    },
    {
        "id": "dining_ajloun",
        "title": "Ajloun Dining Set",
        "category": "dining",
        "blurb": "Walnut table for four with cushioned chairs.",
        "description": (
            "A walnut dining table with rounded solid-wood legs and four "
            "cushioned chairs. The set places in AR together, so chair pull-out "
            "space and circulation are checked in your actual room, not "
            "guessed from a tape measure."
        ),
        "w_cm": 160, "d_cm": 90, "h_cm": 75,
        "materials": ["Walnut top", "Solid wood legs", "Taupe cushions"],
        "finishes": [0xFF7A5337, 0xFF26292B, 0xFFA89482],
        "variants": ["Seats 4", "Seats 6"],
        "price_jd": 799,
        "deal_price_jd": 699,
        "camera_orbit": "-32deg 74deg 4.4m",
        "asset": "models/dining_ajloun.glb",
        "thumb": "thumbs/dining_ajloun.png",
        "hero": None,
        "sort_order": 40,
    },
    {
        "id": "shelf_petra",
        "title": "Petra Shelf",
        "category": "storage",
        "blurb": "Open walnut shelving with a sage back panel.",
        "description": (
            "Open shelving in walnut with a sage back panel and a brass accent "
            "rail - shown styled, because storage is bought with its contents "
            "imagined. At 32 cm deep it sits comfortably in hallways."
        ),
        "w_cm": 90, "d_cm": 32, "h_cm": 180,
        "materials": ["Walnut frame", "Sage back panel", "Brass accent"],
        "finishes": [0xFF7A5337, 0xFFB5C4B0, 0xFF26292B],
        "variants": ["W 90", "W 120"],
        "price_jd": 349,
        "deal_price_jd": None,
        "camera_orbit": "-24deg 82deg 3.6m",
        "asset": "models/shelf_petra.glb",
        "thumb": "thumbs/shelf_petra.png",
        "hero": None,
        "sort_order": 50,
    },
]


def request(method, url, headers, data=None):
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--nvidia-key", default=None,
                    help="publish this NVIDIA key via demo_config (optional)")
    args = ap.parse_args()

    url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_KEY", "")
    if not url or not key:
        sys.exit("Set SUPABASE_URL and SUPABASE_SERVICE_KEY (service role) "
                 "environment variables first - see supabase/README.md")

    auth = {"apikey": key, "Authorization": f"Bearer {key}"}

    # 1) storage: upload every referenced file (upsert)
    uploads = []
    for row in SEED:
        uploads.append(("models", row["asset"].split("/", 1)[1]))
        uploads.append(("thumbs", row["thumb"].split("/", 1)[1]))
        if row["hero"]:
            uploads.append(("thumbs", row["hero"].split("/", 1)[1]))
    for bucket, name in sorted(set(uploads)):
        local = ASSETS / ("models" if bucket == "models" else "thumbs") / name
        if not local.exists():
            sys.exit(f"missing local asset: {local} - run generate_assets.py")
        mime = ("model/gltf-binary" if name.endswith(".glb")
                else mimetypes.guess_type(name)[0] or "application/octet-stream")
        status, body = request(
            "POST", f"{url}/storage/v1/object/{bucket}/{name}",
            {**auth, "Content-Type": mime, "x-upsert": "true"},
            local.read_bytes())
        if status not in (200, 201):
            sys.exit(f"upload {bucket}/{name} failed ({status}): {body}")
        print(f"  uploaded {bucket}/{name} ({local.stat().st_size // 1024} KB)")

    # 2) products: upsert rows. updated_at is the app's cache-invalidation
    # stamp - it must change on every upload (column defaults do not
    # reapply on upsert-update), so send an explicit timestamp.
    stamp = datetime.now(timezone.utc).isoformat()
    rows = []
    for r in SEED:
        rows.append({
            "id": r["id"], "title": r["title"], "category": r["category"],
            "blurb": r["blurb"], "description": r["description"],
            "w_cm": r["w_cm"], "d_cm": r["d_cm"], "h_cm": r["h_cm"],
            "materials": r["materials"], "finishes": r["finishes"],
            "variants": r["variants"], "price_jd": r["price_jd"],
            "deal_price_jd": r["deal_price_jd"],
            "camera_orbit": r["camera_orbit"],
            "asset_path": r["asset"].split("/", 1)[1],
            "thumb_path": r["thumb"].split("/", 1)[1],
            "hero_path": r["hero"].split("/", 1)[1] if r["hero"] else None,
            "sort_order": r["sort_order"],
            "updated_at": stamp,
        })
    status, body = request(
        "POST", f"{url}/rest/v1/products",
        {**auth, "Content-Type": "application/json",
         "Prefer": "resolution=merge-duplicates"},
        json.dumps(rows).encode())
    if status not in (200, 201, 204):
        sys.exit(f"products upsert failed ({status}): {body}")
    print(f"  upserted {len(rows)} product rows")

    # 3) optional: demo NVIDIA key
    if args.nvidia_key:
        status, body = request(
            "POST", f"{url}/rest/v1/demo_config",
            {**auth, "Content-Type": "application/json",
             "Prefer": "resolution=merge-duplicates"},
            json.dumps([{"key": "nvidia_api_key",
                         "value": args.nvidia_key}]).encode())
        if status not in (200, 201, 204):
            sys.exit(f"demo_config upsert failed ({status}): {body}")
        print("  published nvidia_api_key via demo_config")

    print("done - the app now pulls this catalogue when built with "
          "SUPABASE_URL / SUPABASE_ANON_KEY dart-defines")


if __name__ == "__main__":
    main()
