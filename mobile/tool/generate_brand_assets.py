"""Regenerate launcher and splash PNGs: python tool/generate_brand_assets.py.

Requires Pillow. The approved master is preserved; derivatives only resize it.
"""

import json
from pathlib import Path

from PIL import Image


def main():
    mobile = Path(__file__).resolve().parents[1]
    source = Image.open(mobile / "assets/branding/prepcue-logo.png").convert("RGB")
    assert source.width == source.height, "The approved logo must be square"

    def save(path, size):
        path.parent.mkdir(parents=True, exist_ok=True)
        source.resize((size, size), Image.Resampling.LANCZOS).save(path)
        with Image.open(path) as result:
            assert result.size == (size, size) and result.mode == "RGB", str(path)

    res = mobile / "android/app/src/main/res"
    for density, scale in {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}.items():
        save(res / f"mipmap-{density}/ic_launcher.png", round(48 * scale))
        save(res / f"drawable-{density}/launch_logo.png", round(120 * scale))

    assets = mobile / "ios/Runner/Assets.xcassets"
    icons = assets / "AppIcon.appiconset"
    for icon in json.loads((icons / "Contents.json").read_text())["images"]:
        size = round(float(icon["size"].split("x")[0]) * float(icon["scale"].rstrip("x")))
        save(icons / icon["filename"], size)

    launch = assets / "LaunchImage.imageset"
    for image in json.loads((launch / "Contents.json").read_text())["images"]:
        save(launch / image["filename"], round(96 * float(image["scale"].rstrip("x"))))
    print("Generated and checked Android/iOS launcher and splash images from the approved logo.")


if __name__ == "__main__":
    main()
