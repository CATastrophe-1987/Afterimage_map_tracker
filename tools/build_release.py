"""Build the release zip: the mod folder, ready to extract into ue4ss/Mods.

    python tools/build_release.py 0.1.0    # writes dist/AfterimageMapTracker-0.1.0.zip
"""
from __future__ import annotations

import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD = ROOT / "AfterimageMapTracker"


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    version = sys.argv[1]
    out = ROOT / "dist" / f"AfterimageMapTracker-{version}.zip"
    out.parent.mkdir(exist_ok=True)
    files = sorted(p for p in MOD.rglob("*") if p.is_file() and "__pycache__" not in p.parts)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path in files:
            z.write(path, path.relative_to(ROOT).as_posix())
        z.write(ROOT / "README.md", "AfterimageMapTracker/README.md")
    print(f"{out} ({len(files) + 1} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
