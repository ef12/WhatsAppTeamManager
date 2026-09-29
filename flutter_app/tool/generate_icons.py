"""Generate the RKAVIC monogram launcher icons from one vector-like design."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


root = Path(__file__).resolve().parents[1]
size = 1024
image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=215, fill="#163E35")
draw.rounded_rectangle((90, 90, 934, 934), radius=170, outline="#D8F27A", width=24)
font = ImageFont.truetype("C:/Windows/Fonts/segoeuib.ttf", 365)
box = draw.textbbox((0, 0), "RK", font=font)
draw.text(((size - (box[2] - box[0])) / 2, 245), "RK", font=font, fill="#FFFFFF")
draw.rounded_rectangle((305, 735, 719, 776), radius=20, fill="#D8F27A")

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
