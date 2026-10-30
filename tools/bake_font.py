"""
Bakes a TTF into the glyph atlases pxparse draws its bundled font from (addons/pxparse/fonts/).

    python3 tools/bake_font.py <font.ttf> <name> [out folder]

pxparse doesn't load fonts into ImGui (doing that from an addon at runtime can crash the game).
Instead each letter is pre-drawn here, and the addon draws it as a small textured square. One file
per pixel size: the printable ASCII letters (0x21 to 0x7E) packed into an alpha-only atlas, with
2 pixels of room round each letter for the dark ring Classic draws.

File layout (little-endian):
    'PXF1'
    u16 size, u16 line height, u16 ascent, u16 atlas width, u16 atlas height,
    u16 advance * 64, u16 glyph count
    per glyph: u8 code, u16 x, u16 y, u8 w, u8 h, i8 x offset, i8 y offset
        (the box in the atlas, ring room included, and where its top-left sits relative to the
        pen position at the top of the line)
    the atlas alpha, run-length coded: 0x00 n is n zero bytes (1-255), any other byte is itself
"""
import os
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

SIZES = [12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 27, 30, 33, 36]
PAD = 2
FIRST, LAST = 0x21, 0x7E


def rle(data):
    out, i = bytearray(), 0
    while i < len(data):
        if data[i] == 0:
            n = 1
            while i + n < len(data) and data[i + n] == 0 and n < 255:
                n += 1
            out += bytes((0, n))
            i += n
        else:
            out.append(data[i])
            i += 1
    return bytes(out)


def em_for(path, size):
    """ImGui's font size is the height of a line, not of the letters: the em that gives a line
    `size` pixels high, so the baked letters match what Ashita would draw at that size."""
    from fontTools.ttLib import TTFont
    f = TTFont(path)
    return size * f["head"].unitsPerEm / (f["hhea"].ascent - f["hhea"].descent)


def bake(path, size):
    font = ImageFont.truetype(path, em_for(path, size))
    ascent, descent = font.getmetrics()
    advance = font.getlength("M")
    glyphs = []
    for code in range(FIRST, LAST + 1):
        ch = chr(code)
        x0, y0, x1, y1 = font.getbbox(ch)
        w, h = x1 - x0 + 2 * PAD, y1 - y0 + 2 * PAD
        im = Image.new("L", (w, h), 0)
        ImageDraw.Draw(im).text((PAD - x0, PAD - y0), ch, font=font, fill=255)
        glyphs.append((code, im, x0 - PAD, y0 - PAD))

    # Pack in rows, tallest first.
    width = 256 if size <= 20 else 512
    order = sorted(glyphs, key=lambda g: -g[1].height)
    x = y = row = 0
    placed = {}
    for code, im, _, _ in order:
        if x + im.width > width:
            x, y, row = 0, y + row, 0
        placed[code] = (x, y)
        x += im.width
        row = max(row, im.height)
    height = y + row
    atlas = Image.new("L", (width, height), 0)
    for code, im, _, _ in glyphs:
        atlas.paste(im, placed[code])

    out = bytearray(b"PXF1")
    out += struct.pack("<7H", size, ascent + descent, ascent, width, height, round(advance * 64), len(glyphs))
    for code, im, xo, yo in glyphs:
        px, py = placed[code]
        out += struct.pack("<BHHBBbb", code, px, py, im.width, im.height, xo, yo)
    out += rle(atlas.tobytes())
    return bytes(out), atlas


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, name = sys.argv[1], sys.argv[2]
    folder = sys.argv[3] if len(sys.argv) > 3 else "addons/pxparse/fonts"
    os.makedirs(folder, exist_ok=True)
    total = 0
    for size in SIZES:
        data, _ = bake(path, size)
        with open(os.path.join(folder, "%s-%d.pxf" % (name, size)), "wb") as f:
            f.write(data)
        total += len(data)
    print("%d sizes, %d KB" % (len(SIZES), total // 1024))


if __name__ == "__main__":
    main()
