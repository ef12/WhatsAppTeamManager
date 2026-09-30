"""Generate Android and Windows launcher icons from the RKAVIC club crest."""

from pathlib import Path

from PIL import Image


root = Path(__file__).resolve().parents[1]
image = Image.open(root / "assets" / "rkavic_crest.png").convert("RGBA")

for folder, pixels in {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}.items():
    target = root / "android" / "app" / "src" / "main" / "res" / folder / "ic_launcher.png"
    image.resize((pixels, pixels), Image.Resampling.LANCZOS).save(target)

image.save(root / "windows" / "runner" / "resources" / "app_icon.ico", format="ICO", sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
