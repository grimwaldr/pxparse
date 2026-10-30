"""
Draws the real addon with real Dear ImGui (1.92, the version Ashita v4 uses) and saves screenshots,
so the layout can be checked without the game: python3 tests/preview.py [out_dir]

Needs: pip install lupa imgui-bundle PyOpenGL pillow, and a display (on a server: xvfb-run -a).
The addon's Lua runs unchanged; this file maps Ashita's ImGui calls onto imgui-bundle's. Text is
DejaVu Sans Mono at 15px, a wide monospace like Ashita's default, so anything that would run
together in game runs together here too. Classic can't read the game's files here, so it shows
its fallbacks (plain colours for the art, the ringed normal font for text).
"""
import os
import re
import sys

from imgui_bundle import hello_imgui, imgui
from imgui_bundle import icons_fontawesome_6 as fa
from lupa import luajit21
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "images")


def snake(name):
    return re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", name).lower()


def const(name):
    """ImGuiWindowFlags_NoTitleBar -> imgui.WindowFlags_.no_title_bar, as an int."""
    group, _, member = name[len("ImGui"):].partition("_")
    enum = getattr(imgui, group + "_")
    value = getattr(enum, snake(member))
    return int(value.value if hasattr(value, "value") else value)


class Bridge:
    """Ashita's imgui module: PascalCase calls, tables for vectors, tables as out-buffers."""

    def __init__(self, lua):
        self.lua = lua
        self.window = None

    def vec(self, t):
        if t is None:
            return None
        if hasattr(t, "keys"):
            keys = list(t.keys())
            if "x" in keys:
                return imgui.ImVec2(t["x"], t["y"])
            values = [t[i] for i in range(1, len(keys) + 1)]
            return imgui.ImVec2(*values) if len(values) == 2 else imgui.ImVec4(*values)
        return t

    def out(self, v):
        return self.lua.table_from({"x": v.x, "y": v.y})


def build(lua):
    b = Bridge(lua)
    v = b.vec
    out = b.out

    class DrawList:
        def __init__(self, dl):
            self.dl = dl

        def __getattribute__(self, name):
            attr = object.__getattribute__(self, name)
            if name[:1].isupper() and callable(attr):
                me = self
                return lambda *a: attr(*(a[1:] if a and a[0] is me else a))
            return attr

        def AddRectFilled(self, a, c, col, rounding=0.0, flags=0):
            self.dl.add_rect_filled(v(a), v(c), col, rounding=rounding or 0.0, flags=flags or 0)

        def AddRect(self, a, c, col, rounding=0.0, flags=0, thickness=1.0):
            self.dl.add_rect(v(a), v(c), col, rounding=rounding or 0.0, thickness=thickness or 1.0, flags=flags or 0)

        def AddText(self, pos, col, text):
            self.dl.add_text(v(pos), col, text)

        def AddCircleFilled(self, c, r, col, segments=0):
            self.dl.add_circle_filled(v(c), r, col, segments or 0)

        def AddCircle(self, c, r, col, segments=0, thickness=1.0):
            self.dl.add_circle(v(c), r, col, segments or 0, thickness or 1.0)

        def AddTriangleFilled(self, p1, p2, p3, col):
            self.dl.add_triangle_filled(v(p1), v(p2), v(p3), col)

        def AddImage(self, tex, p_min, p_max, uv0=None, uv1=None, col=0xFFFFFFFF):
            self.dl.add_image(imgui.ImTextureRef(int(tex)), v(p_min), v(p_max),
                              v(uv0) or imgui.ImVec2(0, 0), v(uv1) or imgui.ImVec2(1, 1), col)

        def AddLine(self, p1, p2, col, thickness=1.0):
            self.dl.add_line(v(p1), v(p2), col, thickness or 1.0)

    class Baked:
        def __init__(self, baked):
            self.baked = baked
            self.Ascent = baked.ascent
            self.Descent = baked.descent

        def __getattribute__(self, name):
            attr = object.__getattribute__(self, name)
            if name == "FindGlyph":
                me = self
                return lambda *a: attr(*(a[1:] if a and a[0] is me else a))
            return attr

        def FindGlyph(self, cp):
            g = self.baked.find_glyph(cp)
            if g is None:
                return None
            return lua.table_from({"X0": g.x0, "X1": g.x1, "Y0": g.y0, "Y1": g.y1, "AdvanceX": g.advance_x})

    def Begin(name, p_open=None, flags=0):
        opened = p_open[1] if p_open is not None else None
        res = imgui.begin(name, opened, flags or 0)
        expanded, still = res if isinstance(res, tuple) else (res, opened)
        if p_open is not None:
            p_open[1] = still
        return expanded

    def End():
        b.window = (imgui.get_window_pos(), imgui.get_window_size())
        imgui.end()

    def SliderFloat(label, buf, lo, hi, fmt="%.3f", flags=0):
        changed, value = imgui.slider_float(label, buf[1], lo, hi, fmt, flags or 0)
        buf[1] = value
        return changed

    def Selectable(label, selected=False, flags=0, size=None):
        clicked, _ = imgui.selectable(label, bool(selected), flags or 0, v(size) or imgui.ImVec2(0, 0))
        return clicked

    def MenuItem(label, shortcut=None, selected=False, enabled=True):
        clicked, _ = imgui.menu_item(label, shortcut or "", bool(selected), enabled)
        return clicked

    def PushStyleVar(idx, value):
        imgui.push_style_var(idx, v(value) if not isinstance(value, (int, float)) else value)

    def PushFont(font, size):
        # lupa now and then hands back a different Python object than the one GetFont gave Lua.
        # The addon only ever pushes GetFont's font (at another size), so take it from ImGui.
        if not isinstance(font, imgui.ImFont):
            font = imgui.get_font()
        imgui.push_font(font, size)

    def CalcTextSize(text):
        return out(imgui.calc_text_size(text))

    def TableNextRow(flags=0, height=0.0):
        imgui.table_next_row(flags or 0, height or 0.0)

    def TableSetupColumn(label, flags=0, width=0.0, uid=0):
        imgui.table_setup_column(label, flags or 0, width or 0.0, uid or 0)

    def BeginTable(id_, cols, flags=0, size=None, inner=0.0):
        return imgui.begin_table(id_, cols, flags or 0, v(size) or imgui.ImVec2(0, 0), inner or 0.0)

    def Button(label, size=None):
        return imgui.button(label, v(size) or imgui.ImVec2(0, 0))

    def InvisibleButton(id_, size, flags=0):
        return imgui.invisible_button(id_, v(size), flags or 0)

    def CollapsingHeader(label, flags=0):
        return imgui.collapsing_header(label, flags or 0)

    def ProgressBar(frac, size=None, overlay=None):
        imgui.progress_bar(frac, v(size) or imgui.ImVec2(-1, 0), overlay)

    def SameLine(offset=0.0, spacing=-1.0):
        imgui.same_line(offset or 0.0, -1.0 if spacing is None else spacing)

    def PopStyleColor(n=1):
        imgui.pop_style_color(n or 1)

    def PopStyleVar(n=1):
        imgui.pop_style_var(n or 1)

    # Objects handed to Lua stay referenced here: lupa can otherwise pair a Lua value with a
    # different Python object once the first is collected.
    kept = []

    def keep(obj):
        kept.append(obj)
        if len(kept) > 4096:
            del kept[:2048]
        return obj

    special = {
        "Begin": Begin, "End": End, "SliderFloat": SliderFloat, "Selectable": Selectable,
        "MenuItem": MenuItem, "PushStyleVar": PushStyleVar, "PushFont": PushFont,
        "CalcTextSize": CalcTextSize, "TableNextRow": TableNextRow, "TableSetupColumn": TableSetupColumn,
        "BeginTable": BeginTable, "Button": Button, "InvisibleButton": InvisibleButton,
        "CollapsingHeader": CollapsingHeader, "ProgressBar": ProgressBar, "SameLine": SameLine,
        "PopStyleColor": PopStyleColor, "PopStyleVar": PopStyleVar,
        "GetWindowDrawList": lambda: keep(DrawList(imgui.get_window_draw_list())),
        "GetFontBaked": lambda: keep(Baked(imgui.get_font_baked())),
        "GetFont": lambda: keep(imgui.get_font()),
        "GetColorU32": lambda col: imgui.get_color_u32(v(col)),
    }
    vec_getters = {"GetWindowPos", "GetWindowSize", "GetCursorScreenPos", "GetItemRectMin",
                   "GetItemRectMax", "GetContentRegionAvail"}

    def lookup(name):
        if name in special:
            return special[name]
        fn = getattr(imgui, snake(name))
        if name in vec_getters:
            return lambda *a: out(fn(*a))

        def call(*args):
            args = list(args)
            while args and args[-1] is None:
                args.pop()
            return fn(*[v(a) if hasattr(a, "keys") else a for a in args])
        return call

    module = lua.eval("function (lookup) return setmetatable({}, { __index = function (t, k)"
                      " local f = lookup(k); t[k] = f; return f; end }); end")(lookup)
    return b, module


SHOTS = [
    # name, gear open, tab, names hidden, live fight, theme
    ("closed", False, "damage", False, True, "phoenix"),
    ("closed-masked", False, "damage", True, False, "phoenix"),
    ("damage", True, "damage", False, True, "phoenix"),
    ("detail", True, "detail", False, True, "phoenix"),
    ("log", True, "log", False, True, "phoenix"),
    ("settings", True, "settings", False, True, "phoenix"),
    ("classic-closed", False, "damage", False, True, "classic"),
    ("classic-damage", True, "damage", False, True, "classic"),
    ("classic-settings", True, "settings", False, True, "classic"),
    ("default-closed", False, "damage", False, True, "default"),
    ("default-damage", True, "damage", False, True, "default"),
    ("long-names", False, "damage", False, True, "phoenix"),
    ("long-names-damage", True, "damage", False, True, "phoenix"),
    ("chain-late", False, "damage", False, False, "phoenix"),
    # Classic with a window texture standing in for the game's art (see BACKDROP below).
    ("classic-art-closed", False, "damage", False, True, "classic"),
    ("classic-art-damage", True, "damage", False, True, "classic"),
    ("classic-art-detail", True, "detail", False, True, "classic"),
    ("classic-art-mono-closed", False, "damage", False, True, "classic"),
    ("closed-ashita", False, "damage", False, True, "phoenix"),
]

# The game's window art can't be read here (it comes from the game install), so the classic-art
# shots take a screenshot of a game window as a stand-in: PREVIEW_BACKDROP=path/to/window.png,
# PREVIEW_WINTYPE=1-8. The picture is tiled behind the window and its top rows are used as the
# frame line, roughly as skin.lua lays the real art out.
BACKDROP = os.environ.get("PREVIEW_BACKDROP")
WINTYPE = int(os.environ.get("PREVIEW_WINTYPE", "1")) - 1

MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"

# PREVIEW_FONT=path.ttf[:size] draws the classic-art shots in that font instead, e.g. a TTF of the
# game's own letters at 16px, to show what Classic's game font looks like. Not shipped: a font
# traced from the game's files stays on your machine.
GAME_FONT = os.environ.get("PREVIEW_FONT")


def font_loader(name):
    """A wide monospace like Ashita's (or PREVIEW_FONT for the classic-art shots), with Font
    Awesome 6 merged in for the icons."""
    path, size = MONO, 15.0
    if GAME_FONT and name.startswith("classic-art"):
        path, _, given = GAME_FONT.partition(":")
        size = float(given or 16)

    def fonts():
        text = hello_imgui.FontLoadingParams()
        text.inside_assets = False
        text.font_config.pixel_snap_h = True
        hello_imgui.load_font(path, size, text)
        icons = hello_imgui.FontLoadingParams()
        icons.merge_to_last_font = True
        hello_imgui.load_font("fonts/Font_Awesome_6_Free-Solid-900.otf", size - 1, icons)
    return fonts


def shoot(name, expanded, tab, masked, live, theme):
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.path = 'addons/pxparse/?.lua;tests/?.lua;' .. package.path")
    bridge, module = build(lua)
    g = lua.globals()
    g.PREVIEW_IMGUI = module
    g.PREVIEW_CONST = const
    g.PREVIEW_LONG = name.startswith("long")

    def texture(w, h, hexdata):
        """The bundled font's atlas (BGRA rows from the addon) as an OpenGL texture."""
        from OpenGL import GL
        bgra = bytes.fromhex(hexdata)
        rgba = bytearray(bgra)
        rgba[0::4], rgba[2::4] = bgra[2::4], bgra[0::4]
        tex = GL.glGenTextures(1)
        GL.glBindTexture(GL.GL_TEXTURE_2D, tex)
        GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_NEAREST)
        GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_NEAREST)
        GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA, int(w), int(h), 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, bytes(rgba))
        return int(tex)

    g.PREVIEW_TEXTURE = texture
    g.PREVIEW_ICONS = lua.table_from({
        "ICON_FA_GEAR": fa.ICON_FA_GEAR, "ICON_FA_EYE": fa.ICON_FA_EYE,
        "ICON_FA_EYE_SLASH": fa.ICON_FA_EYE_SLASH, "ICON_FA_CARET_DOWN": fa.ICON_FA_CARET_DOWN,
    })
    frames = [0]

    def setup():
        with open(os.path.join(ROOT, "tests", "preview.lua"), encoding="utf-8") as f:
            lua.execute(f.read())
        p = g.PREVIEW
        s = p.settings
        s.tab, s.masknames, s.theme = tab, masked, theme
        p.view.expanded = expanded
        if not live:
            p.kill()
            p.advance(10)
        # A font other than the skin's default: "-mono" or "-ashita" in the shot's name.
        for font in ("mono", "ashita"):
            if "-" + font in name:
                s.font[theme] = font
        if name.startswith("classic-art"):
            s.wintype, s.alpha = WINTYPE, 0.0  # the backdrop shows through the window
        if name == "chain-late":
            p.advance(130)  # 40s of chain #2's 180s window left

    art = {}

    def backdrop():
        """Tiles the stand-in window art behind where the window was last frame."""
        if not (name.startswith("classic-art") and BACKDROP and bridge.window):
            return
        if not art:
            from OpenGL import GL
            src = Image.open(BACKDROP).convert("RGBA")
            # The frame: the brightest rows near the top. The body: everything under it.
            rows = [sum(src.getpixel((x, y))[c] for x in range(src.width // 4, src.width * 3 // 4) for c in range(3))
                    for y in range(min(12, src.height))]
            edge = max(range(len(rows)), key=lambda y: rows[y])
            frame = src.crop((0, max(0, edge - 1), src.width, edge + 2))
            body = src.crop((0, edge + 3, src.width, src.height - 4))
            for key, im in (("frame", frame), ("body", body)):
                tex = GL.glGenTextures(1)
                GL.glBindTexture(GL.GL_TEXTURE_2D, tex)
                GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR)
                GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR)
                GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA, im.width, im.height, 0, GL.GL_RGBA,
                                GL.GL_UNSIGNED_BYTE, im.tobytes())
                art[key] = (imgui.ImTextureRef(int(tex)), im.width, im.height)
        pos, size = bridge.window
        dl = imgui.get_background_draw_list()
        tex, tw, th = art["body"]
        x0, y0, x1, y1 = pos.x, pos.y, pos.x + size.x, pos.y + size.y
        y = y0
        while y < y1:
            x = x0
            h = min(th, y1 - y)
            while x < x1:
                w = min(tw, x1 - x)
                dl.add_image(tex, imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h),
                             imgui.ImVec2(0, 0), imgui.ImVec2(w / tw, h / th))
                x += tw
            y += th
        tex, tw, th = art["frame"]
        for a, b, uv1 in (
            ((x0, y0), (x1, y0 + th), (1, 1)),          # top
            ((x0, y1 - th), (x1, y1), (1, 1)),          # bottom
        ):
            dl.add_image(tex, imgui.ImVec2(*a), imgui.ImVec2(*b), imgui.ImVec2(0, 0), imgui.ImVec2(*uv1))
        # Sides: the frame's colour, as thin vertical lines.
        light = imgui.get_color_u32(imgui.ImVec4(0.88, 0.90, 1.0, 1.0))
        mid = imgui.get_color_u32(imgui.ImVec4(0.53, 0.55, 0.65, 1.0))
        for x, col in ((x0, mid), (x0 + 1, light), (x1 - 2, light), (x1 - 1, mid)):
            dl.add_line(imgui.ImVec2(x + 0.5, y0), imgui.ImVec2(x + 0.5, y1), col, 1.0)

    def gui():
        if frames[0] == 0:
            setup()
        backdrop()
        g.PREVIEW_TICK()
        frames[0] += 1
        if frames[0] > 8:
            hello_imgui.get_runner_params().app_shall_exit = True

    def stock_style():
        # hello_imgui applies its own theme; Ashita starts from ImGui's stock dark style.
        style, stock = imgui.get_style(), imgui.Style()
        for name in dir(stock):
            if name.startswith("_") or name in ("colors", "font_scale_dpi", "font_scale_main"):
                continue
            try:
                value = getattr(stock, name)
                if not callable(value):
                    setattr(style, name, value)
            except Exception:
                pass
        imgui.style_colors_dark()

    params = hello_imgui.RunnerParams()
    params.callbacks.setup_imgui_style = stock_style
    params.callbacks.show_gui = gui
    params.callbacks.load_additional_fonts = font_loader(name)
    params.app_window_params.window_geometry.size = (520, 900)
    params.imgui_window_params.default_imgui_window_type = hello_imgui.DefaultImGuiWindowType.no_default_window
    params.imgui_window_params.background_color = imgui.ImVec4(0.13, 0.15, 0.17, 1.0)
    params.ini_disable = True
    params.fps_idling.enable_idling = False
    hello_imgui.run(params)

    img = Image.fromarray(hello_imgui.final_app_window_screenshot())
    pos, size = bridge.window
    box = (int(pos.x) - 8, int(pos.y) - 8, int(pos.x + size.x) + 8, int(pos.y + size.y) + 8)
    img.crop(box).save(os.path.join(OUT, "preview-%s.png" % name))
    print("preview-%s.png" % name, int(size.x), "x", int(size.y))


if __name__ == "__main__":
    os.chdir(ROOT)
    os.makedirs(OUT, exist_ok=True)
    only = sys.argv[2:] if len(sys.argv) > 2 else None
    if only and len(only) == 1:
        shoot(*[shot for shot in SHOTS if shot[0] == only[0]][0])
    else:
        # One process per shot: lupa can mix up objects between Lua runtimes in one process.
        import subprocess
        for shot in SHOTS:
            if not only or shot[0] in only:
                subprocess.run([sys.executable, os.path.abspath(__file__), OUT, shot[0]], check=True)
