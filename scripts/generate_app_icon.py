import os
import subprocess
from PIL import Image, ImageDraw, ImageFont

def generate_icon(output_icns_path):
    size = 1024
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # macOS squircle background: dark ink #120F0D
    corner_radius = 224
    bg_color = (18, 15, 13, 255) # Sumi ink dark
    draw.rounded_rectangle([40, 40, size - 40, size - 40], radius=corner_radius, fill=bg_color)

    # Outer rice-paper subtle border
    border_color = (246, 241, 231, 40) # Paper wash
    draw.rounded_rectangle([40, 40, size - 40, size - 40], radius=corner_radius, outline=border_color, width=6)

    # Inner vermilion seal stamp
    seal_color = (194, 58, 46, 255) # Vermilion #C23A2E
    seal_margin = 180
    draw.rounded_rectangle(
        [seal_margin, seal_margin, size - seal_margin, size - seal_margin],
        radius=48,
        fill=seal_color
    )

    # Seal inner border line
    inner_line = (246, 241, 231, 160)
    draw.rounded_rectangle(
        [seal_margin + 24, seal_margin + 24, size - seal_margin - 24, size - seal_margin - 24],
        radius=36,
        outline=inner_line,
        width=8
    )

    # Kanji: 鎖 (Lock)
    font_path = "/System/Library/Fonts/Hiragino Sans GB.ttc"
    try:
        font = ImageFont.truetype(font_path, 420)
    except Exception:
        font = ImageFont.load_default()

    text = "鎖"
    bbox = draw.textbbox((0, 0), text, font=font)
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]
    text_x = (size - text_width) // 2 - bbox[0]
    text_y = (size - text_height) // 2 - bbox[1] - 10

    draw.text((text_x, text_y), text, fill=(246, 241, 231, 255), font=font)

    # Top brand label: ZOID
    times_path = "/System/Library/Fonts/Times.ttc"
    try:
        sub_font = ImageFont.truetype(times_path, 54)
    except Exception:
        sub_font = font

    sub_text = "ZOID LOCK IN"
    sub_bbox = draw.textbbox((0, 0), sub_text, font=sub_font)
    sub_w = sub_bbox[2] - sub_bbox[0]
    sub_x = (size - sub_w) // 2
    draw.text((sub_x, 100), sub_text, fill=(246, 241, 231, 210), font=sub_font)

    # Bottom subtitle: SUMI-E
    try:
        bot_font = ImageFont.truetype(times_path, 36)
    except Exception:
        bot_font = font
    bot_text = "DISCIPLINE ENGINE"
    bot_bbox = draw.textbbox((0, 0), bot_text, font=bot_font)
    bot_w = bot_bbox[2] - bot_bbox[0]
    bot_x = (size - bot_w) // 2
    draw.text((bot_x, 880), bot_text, fill=(246, 241, 231, 140), font=bot_font)

    # Prepare iconset
    iconset_dir = "/tmp/ZoidLockIn.iconset"
    os.makedirs(iconset_dir, exist_ok=True)

    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    for filename, s in sizes:
        resized = image.resize((s, s), Image.Resampling.LANCZOS)
        resized.save(os.path.join(iconset_dir, filename))

    os.makedirs(os.path.dirname(output_icns_path), exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", output_icns_path], check=True)
    print(f"Generated ICNS at: {output_icns_path}")

if __name__ == "__main__":
    generate_icon("Resources/AppIcon.icns")
