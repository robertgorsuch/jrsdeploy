#!/usr/bin/env python3
"""Rebuild (or update in place) a compose manifest from a LIVE dashboard export.

When a dashboard is rearranged in the JRS designer, the compose manifest goes
stale and a recompose would revert the hand edits. This reads the dashboard's
export archive (layout + components.data + descriptor) and writes a manifest
whose dashlets match the live tile positions/sizes AND the designer
presentation keys gen_dashboard.py honours, so a subsequent
compose_dashboard.ps1 reproduces the live layout exactly (round-trip:
gen_dashboard -> export -> sync_manifest -> gen_dashboard is a fixed point).

Synced keys
  dashboard : autoRefresh, showExportButton, showPrintButton, canvasColor,
              dashletFilterShowPopup, filters[], filterControlFolder,
              filterOwner, filterButtonsPosition, filterFloating,
              filterStripHeight
  report    : resource, label, x/y/width/height, scaleToFit, showTitleBar
  text      : text, size, align, bold, italic, color, background, valign
  image     : url, scaleToFit

Usage
  sync_manifest.py --zip <export.zip> --out <manifest.json>
  sync_manifest.py --zip <export.zip> --merge <existing.json> [--out <path>] [--dry-run]

--merge updates an EXISTING manifest in place: every other key (queries,
outDir, controls, wiring, per-tile build settings, ...) is preserved and key
order is kept; tiles are matched by resource (report) or kind+name; a unified
diff is printed. --dry-run prints the diff and writes nothing.
(normally called by sync_manifest_from_dashboard.ps1, which does the export).
"""
import argparse
import difflib
import json
import re
import sys
import zipfile
from collections import OrderedDict

FILTER_GROUP_ID = "FilterGroup"

# gen_dashboard.py defaults -- a synced value equal to the default is omitted
# from a fresh manifest (kept if the manifest already carries the key). The
# filter* keys are deliberately NOT here: when a filter strip exists its
# docking (filterFloating), button position and height are always written so
# the manifest states them explicitly.
DASH_DEFAULTS = {"autoRefresh": False, "showExportButton": False, "showPrintButton": False,
                 "canvasColor": "#ffffff", "dashletFilterShowPopup": False}
STRIP_DEFAULT = 3
# per-tile generator defaults (merge mode omits a synced value equal to the
# default when the manifest did not already carry the key)
TILE_DEFAULTS = {"report": {"scaleToFit": "width", "showTitleBar": True},
                 "image": {"scaleToFit": "container"},
                 "text": {"align": "left", "bold": False, "italic": False, "valign": "top",
                          "color": "rgba(0, 0, 0, 1)", "background": "rgba(0, 0, 0, 0)", "size": 12}}
TEXT_MAP = (("size", "size"), ("alignment", "align"), ("bold", "bold"), ("italic", "italic"),
            ("color", "color"), ("backgroundColor", "background"), ("verticalAlignment", "valign"))


def attr(blob, name):
    m = re.search(name + r"='([^']*)'", blob) or re.search(name + r'="([^"]*)"', blob)
    return m.group(1) if m else None


def read_live(zip_path):
    """Parse a dashboard export into {folder,name,label,props,tiles[],filters}."""
    z = zipfile.ZipFile(zip_path)
    names = z.namelist()
    layout_path = next((n for n in names if n.endswith("_files/layout")), None)
    if not layout_path:
        raise SystemExit("ERROR: no dashboard layout found in the export (is the URI a dashboard?)")
    base = layout_path[: -len("_files/layout")]          # resources/<folder>/<name>
    uri = base[len("resources"):]                        # /<folder>/<name>
    folder, name = uri.rsplit("/", 1)

    layout = z.read(layout_path).decode("utf-8", "ignore")
    components = json.loads(z.read(base + "_files/components.data").decode("utf-8", "ignore"))
    desc = z.read(base + ".xml").decode("utf-8", "ignore") if (base + ".xml") in names else ""
    mlab = re.search(r"<label>(.*?)</label>", desc, re.S)
    label = mlab.group(1).strip() if mlab else name

    by_id = {c.get("id"): c for c in components if isinstance(c, dict)}
    props = next((c for c in components if isinstance(c, dict) and c.get("type") == "dashboardProperties"), {})
    group = next((c for c in components if isinstance(c, dict) and c.get("type") == "filterGroup"), None)
    controls = sorted([c for c in components if isinstance(c, dict) and c.get("type") == "inputControl"],
                      key=lambda c: int(c.get("position") or 0))

    divs = {}
    for blob in re.findall(r"<div\b([^>]*)>\s*</div>", layout):
        cid = attr(blob, "data-componentId")
        if cid:
            divs[cid] = {"x": int(attr(blob, "data-x") or 0), "y": int(attr(blob, "data-y") or 0),
                         "width": int(attr(blob, "data-width") or 1), "height": int(attr(blob, "data-height") or 1)}

    live = OrderedDict()
    live["folder"], live["name"], live["label"] = folder, name, label
    dash = OrderedDict()
    dash["autoRefresh"] = bool(props.get("autoRefresh", False))
    dash["showExportButton"] = bool(props.get("showExportButton", False))
    dash["showPrintButton"] = bool(props.get("showPrintButton", False))
    dash["canvasColor"] = props.get("canvasColor", "#ffffff")
    dash["dashletFilterShowPopup"] = bool(props.get("dashletFilterShowPopup", False))

    strip = 0
    if group and controls:
        dash["filters"] = [c.get("name") or c.get("id") for c in controls]
        first = controls[0]
        res = first.get("resource") or ""
        if "/" in res:
            dash["filterControlFolder"] = res.rsplit("/", 1)[0]
        if first.get("ownerResourceId"):
            dash["filterOwner"] = first["ownerResourceId"]
        dash["filterButtonsPosition"] = group.get("buttonsPosition", "bottom")
        dash["filterFloating"] = bool(group.get("floating", False))
        gdiv = divs.get(group.get("id") or FILTER_GROUP_ID)
        strip = gdiv["height"] if gdiv else STRIP_DEFAULT
        dash["filterStripHeight"] = strip
    live["props"] = dash

    tiles = []
    for cid, pos in divs.items():
        c = by_id.get(cid, {})
        t = c.get("type")
        if t == "reportUnit":
            d = OrderedDict([("resource", c.get("resource")),
                             ("label", c.get("name") or c.get("label") or cid)])
            d["scaleToFit"] = c.get("scaleToFit", "width")
            d["showTitleBar"] = bool(c.get("showTitleBar", False))
        elif t == "text":
            d = OrderedDict([("kind", "text"), ("name", cid), ("text", c.get("text", ""))])
            for src, dst in TEXT_MAP:
                if c.get(src) is not None:
                    d[dst] = c[src]
        elif t == "image":
            d = OrderedDict([("kind", "image"), ("name", cid), ("url", c.get("url", ""))])
            d["scaleToFit"] = c.get("scaleToFit", "container")
        else:
            continue  # dashboardProperties / filterGroup / inputControl -> not a tile
        # gen_dashboard shifts every tile down by the strip height when filters exist
        d["x"], d["y"] = pos["x"], max(0, pos["y"] - strip)
        d["width"], d["height"] = pos["width"], pos["height"]
        tiles.append(d)
    if not tiles:
        raise SystemExit("ERROR: no tiles parsed from the live layout")
    live["tiles"] = tiles
    return live


def tile_key(d):
    if d.get("kind", "report") == "report":
        return ("report", d.get("resource") or "")
    return (d.get("kind"), d.get("name") or d.get("id") or "")


def fresh_manifest(live):
    m = OrderedDict([("folder", live["folder"]), ("name", live["name"]), ("label", live["label"])])
    for k, v in live["props"].items():
        if k in DASH_DEFAULTS and v == DASH_DEFAULTS[k]:
            continue
        m[k] = v
    m["dashlets"] = live["tiles"]
    return m


def merge_manifest(existing, live):
    """Write live layout/presentation into the existing manifest, preserving
    everything else and the key order."""
    m = OrderedDict(existing)
    for k, v in live["props"].items():
        if k in m or v != DASH_DEFAULTS.get(k, object()):
            m[k] = v
    if "filters" not in live["props"]:
        for k in ("filters", "filterControlFolder", "filterOwner", "filterButtonsPosition",
                  "filterFloating", "filterStripHeight"):
            m.pop(k, None)
    by_key = {tile_key(d): d for d in live["tiles"]}
    folder = m.get("folder", live["folder"]).rstrip("/")
    merged, seen = [], set()
    for d in m.get("dashlets", []):
        d = OrderedDict(d)
        if d.get("kind", "report") == "report" and not d.get("resource") and d.get("name"):
            key = ("report", f"{folder}/{d['name']}")
        else:
            key = tile_key(d)
        lv = by_key.get(key)
        if lv is None:
            sys.stderr.write(f"WARN: tile {key[1]} is in the manifest but not on the live dashboard (kept as is)\n")
            merged.append(d)
            continue
        seen.add(key)
        for k, v in lv.items():
            if k in ("resource", "kind", "name"):
                continue
            if k == "label" and "label" in d:
                continue                      # manifest label wins (title text)
            if k not in d and TILE_DEFAULTS.get(lv.get("kind", "report"), {}).get(k, object()) == v:
                continue                      # generator default: no need to spell it out
            d[k] = v
        merged.append(d)
    for d in live["tiles"]:
        if tile_key(d) not in seen:
            sys.stderr.write(f"WARN: live tile {tile_key(d)[1]} was not in the manifest (added)\n")
            merged.append(d)
    m["dashlets"] = merged
    return m


def dump(m):
    return json.dumps(m, indent=2, ensure_ascii=True) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", required=True)
    ap.add_argument("--out", help="manifest to write (default: --merge path)")
    ap.add_argument("--merge", help="existing manifest to update in place (keys/order preserved)")
    ap.add_argument("--dry-run", action="store_true", help="print the diff, write nothing")
    args = ap.parse_args()
    if not args.out and not args.merge:
        ap.error("--out or --merge is required")
    out = args.out or args.merge

    live = read_live(args.zip)
    before = ""
    if args.merge:
        with open(args.merge, encoding="utf-8-sig") as f:
            before = f.read()
        existing = json.loads(before, object_pairs_hook=OrderedDict)
        manifest = merge_manifest(existing, live)
    else:
        manifest = fresh_manifest(live)
    after = dump(manifest)

    diff = list(difflib.unified_diff(before.splitlines(), after.splitlines(),
                                     fromfile=(args.merge or "(new)"), tofile=out, lineterm=""))
    if diff:
        print("\n".join(diff))
    else:
        print("(no changes: manifest already matches the live dashboard)")

    if args.dry_run:
        print(f"[dry-run] would write {out} ({len(manifest['dashlets'])} dashlets) from live {live['folder']}/{live['name']}")
        return
    with open(out, "w", encoding="utf-8") as f:
        f.write(after)
    print(f"OK: wrote {out} ({len(manifest['dashlets'])} dashlets) from live {live['folder']}/{live['name']}")
    for d in manifest["dashlets"]:
        tgt = d.get("resource") or (d.get("kind", "?") + ":" + d.get("name", ""))
        print(f"    [{d['x']:>2},{d['y']:>2} {d['width']}x{d['height']}] {tgt}")


if __name__ == "__main__":
    main()
