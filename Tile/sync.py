#!/usr/bin/env python3
"""Copies the tile modules (Tile/*.js) into the call (CLI/BridgeJS.swift) and the playground (site/tile.html).

    python3 Tile/sync.py                      # after editing Tile/*.js
    python3 Tile/sync.py ~/Downloads/fernsprecher-tile.json   # after exporting from the playground
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TILE = ROOT / "Tile"
ORDER = ["scene", "connecting", "listening", "hearing", "thinking", "speaking", "waking", "away"]

if len(sys.argv) > 1:
    exported = json.loads(pathlib.Path(sys.argv[1]).expanduser().read_text(encoding="utf-8"))
    for name in ORDER:
        if name in exported:
            (TILE / f"{name}.js").write_text(exported[name].rstrip() + "\n", encoding="utf-8")

modules = {name: (TILE / f"{name}.js").read_text(encoding="utf-8").rstrip() for name in ORDER}


def replace_block(path, start, end, body):
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.S)
    if not pattern.search(text):
        sys.exit(f"markers not found in {path}")
    path.write_text(pattern.sub(lambda _: start + "\n" + body + "\n" + end, text, count=1), encoding="utf-8")


# The call: real functions (the FaceTime page's CSP forbids compiling strings).
if any('"""#' in src for src in modules.values()):
    sys.exit('a module contains """# which would end the Swift string')
fns = []
for name, src in modules.items():
    inner = "\n".join(("      " + l) if l.strip() else "" for l in src.split("\n"))
    fns.append(f"      {name}: (o) => {{\n{inner}\n      }},")
replace_block(ROOT / "CLI/BridgeJS.swift", "    // <tile-modules>", "    // </tile-modules>",
              "    const tileModules = {\n" + "\n".join(fns) + "\n    };")

# The playground: sources as strings, compiled on the fly.
replace_block(ROOT / "site/tile.html", "/* <tile-modules> */", "/* </tile-modules> */",
              "const DEFAULTS = " + json.dumps(modules, ensure_ascii=False, indent=2) + ";")
print("synced", ", ".join(ORDER))
