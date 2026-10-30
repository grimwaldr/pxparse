--[[
* pxparse - bitmapfont
* Draws the bundled font (fonts/*.pxf, baked ahead of time from the TTF) as small textured squares, one
* per letter, the same way the game font is drawn. Nothing is loaded into ImGui's own fonts, which
* can crash the game when an addon does it at runtime.
*
* Each pixel size is its own atlas, loaded the first time it's drawn. A size is picked to match the
* text size in use, so the letters land on whole pixels and stay crisp. Two textures per size: plain
* letters, and the same letters with a dark ring baked in (Classic rings its text, and one square a
* letter keeps a full Log tab well under what ImGui draws in one window).
--]]

-- ImGui only when drawing, so the reading half runs in the offline tests.
local imgui = nil;

local bitmapfont = {};

bitmapfont.SIZES = { 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 27, 30, 33, 36 };

local RING = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } };
local RING_ALPHA = 0.9;

-- This file's folder: the atlases are in fonts/ beside it, wherever the addon is installed.
local HERE = (debug.getinfo(1, 'S').source:match('^@(.*[\\/])') or './');

local faces = {}; -- [name] = { [size] = loaded atlas, or false once it has failed }

-----------------------------------
-- Reading an atlas (plain Lua)
-----------------------------------
local function u16(s, at) return s:byte(at) + s:byte(at + 1) * 256; end
local function i8(s, at) local v = s:byte(at); return v >= 128 and v - 256 or v; end

--[[
* Parses a .pxf file's contents: { size, line, ascent, width, height, advance, glyphs = { [code] =
* { x, y, w, h, xo, yo } }, alpha = { [index] = 0-255 } }, or nil and why.
--]]
function bitmapfont.parse(data)
    if (type(data) ~= 'string' or data:sub(1, 4) ~= 'PXF1' or #data < 18) then
        return nil, 'not a pxparse font file';
    end
    local f = {
        size = u16(data, 5), line = u16(data, 7), ascent = u16(data, 9),
        width = u16(data, 11), height = u16(data, 13), advance = u16(data, 15) / 64, glyphs = {},
    };
    local count, at = u16(data, 17), 19;
    for _ = 1, count do
        f.glyphs[data:byte(at)] = {
            x = u16(data, at + 1), y = u16(data, at + 3), w = data:byte(at + 5), h = data:byte(at + 6),
            xo = i8(data, at + 7), yo = i8(data, at + 8),
        };
        at = at + 9;
    end
    -- Run-length coded alpha: 0 n is n zero bytes, anything else is itself.
    local alpha, n, total = {}, 0, f.width * f.height;
    while (at <= #data and n < total) do
        local b = data:byte(at);
        if (b == 0) then
            local run = data:byte(at + 1) or 0;
            for k = 1, run do alpha[n + k] = 0; end
            n, at = n + run, at + 2;
        else
            n = n + 1;
            alpha[n] = b;
            at = at + 1;
        end
    end
    if (n ~= total) then
        return nil, 'the font file is cut short';
    end
    f.alpha = alpha;
    return f;
end

--[[
* The atlas as BGRA rows for a texture: white letters (tinted when drawn), and with `ringed`, a dark
* ring one pixel out round every letter, blended under it.
--]]
function bitmapfont.pixels(f, ringed)
    local w, h, alpha = f.width, f.height, f.alpha;
    local rows = {};
    for y = 0, h - 1 do
        local row = {};
        for x = 0, w - 1 do
            local a = alpha[y * w + x + 1] / 255;
            local r = 0;
            if (ringed and a < 1) then
                for _, o in ipairs(RING) do
                    local nx, ny = x + o[1], y + o[2];
                    if (nx >= 0 and ny >= 0 and nx < w and ny < h) then
                        local na = alpha[ny * w + nx + 1];
                        if (na > r) then r = na; end
                    end
                end
                r = r / 255 * RING_ALPHA;
            end
            -- The letter over the ring: white where it's letter, black where it's ring.
            local out = a + r * (1 - a);
            local white = out > 0 and math.floor(255 * a / out + 0.5) or 0;
            row[x + 1] = string.char(white, white, white, math.floor(255 * out + 0.5));
        end
        rows[y + 1] = table.concat(row);
    end
    return table.concat(rows);
end

-----------------------------------
-- Textures
-----------------------------------
local function write_u32(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256);
end

-- An uncompressed 32-bit DDS from BGRA rows, so D3DX can load it from memory.
local function as_dds(width, height, pixels)
    local zero = write_u32(0);
    return table.concat({
        'DDS ', write_u32(124), write_u32(0x100F), write_u32(height), write_u32(width), write_u32(width * 4), zero, zero,
        zero:rep(11),
        write_u32(32), write_u32(0x41), zero, write_u32(32),
        write_u32(0x00FF0000), write_u32(0x0000FF00), write_u32(0x000000FF), write_u32(0xFF000000),
        write_u32(0x1000), zero:rep(4),
        pixels,
    });
end

-- Makes a texture from BGRA rows: { id, release }.
function bitmapfont.make_texture(width, height, pixels)
    local ffi = require('ffi');
    local d3d = require('d3d8');
    local C   = ffi.C;
    local image  = as_dds(width, height, pixels);
    local out    = ffi.new('IDirect3DTexture8*[1]');
    local result = C.D3DXCreateTextureFromFileInMemoryEx(d3d.get_device(), image, #image, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
        C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED, 1, C.D3DX_DEFAULT, 0, nil, nil, out);
    if (result ~= C.S_OK) then
        return nil;
    end
    local handle = ffi.cast('IDirect3DTexture8*', out[0]);
    return { id = tonumber(ffi.cast('uint32_t', handle)), release = function () handle:Release(); end };
end

-----------------------------------
-- Loading
-----------------------------------
-- The baked size nearest `px`.
function bitmapfont.nearest(px)
    local best = bitmapfont.SIZES[1];
    for _, s in ipairs(bitmapfont.SIZES) do
        if (math.abs(s - px) < math.abs(best - px)) then
            best = s;
        end
    end
    return best;
end

local function read(name, size)
    local file = io.open(string.format('%sfonts%s%s-%d.pxf', HERE, HERE:find('\\') and '\\' or '/', name, size), 'rb');
    if (not file) then
        return nil;
    end
    local data = file:read('*a');
    file:close();
    return data;
end

--[[
* The atlas for `name` nearest `px`, loading it the first time (textures included). Nil and the
* reason when it can't be used; that's remembered, so a missing file is only tried once.
--]]
function bitmapfont.get(name, px)
    local size = bitmapfont.nearest(px);
    faces[name] = faces[name] or {};
    local f = faces[name][size];
    if (f == nil) then
        local data = read(name, size);
        local parsed, reason = bitmapfont.parse(data);
        if (not data) then
            reason = string.format('fonts\\%s-%d.pxf is missing', name, size);
        end
        if (parsed) then
            local ok, plain, ringed = pcall(function ()
                return bitmapfont.make_texture(parsed.width, parsed.height, bitmapfont.pixels(parsed, false)),
                    bitmapfont.make_texture(parsed.width, parsed.height, bitmapfont.pixels(parsed, true));
            end);
            if (ok and plain and ringed) then
                parsed.plain, parsed.ringed = plain, ringed;
            else
                if (ok) then
                    pcall(function () if (plain) then plain.release(); end if (ringed) then ringed.release(); end end);
                end
                parsed, reason = nil, 'the font texture could not be made' .. (ok and '' or (': ' .. tostring(plain)));
            end
        end
        f = parsed or false;
        faces[name][size] = f;
        if (not parsed) then
            return nil, reason;
        end
    end
    return f or nil;
end

function bitmapfont.release()
    for _, sizes in pairs(faces) do
        for _, f in pairs(sizes) do
            if (f) then
                pcall(f.plain.release);
                pcall(f.ringed.release);
            end
        end
    end
    faces = {};
end

-----------------------------------
-- Measuring and drawing
-----------------------------------
function bitmapfont.plain(text)
    return type(text) == 'string' and not text:find('[^\32-\126]');
end

function bitmapfont.width(f, text)
    return math.floor(#text * f.advance + 0.5);
end

--[[
* Draws text with the top of its line at (x, y), centred in a text line `line` high. `style` is
* nil (plain), 'ring' (a dark ring round every letter) or 'shadow' (a 1px drop shadow).
--]]
function bitmapfont.draw(list, f, x, y, color, text, line, style)
    imgui = imgui or require('imgui');
    local top  = math.floor(y + ((line or f.line) - f.line) / 2 + 0.5);
    local fill = imgui.GetColorU32(color);
    local tex  = style == 'ring' and f.ringed.id or f.plain.id;
    local W, H = f.width, f.height;
    local passes = { { 0, 0, fill } };
    if (style == 'shadow') then
        passes = { { 1, 1, imgui.GetColorU32({ 0, 0, 0, 0.75 * (color[4] or 1) }) }, { 0, 0, fill } };
    end
    for _, pass in ipairs(passes) do
        local pen = x;
        for i = 1, #text do
            local g = f.glyphs[text:byte(i)];
            if (g) then
                local gx = math.floor(pen + 0.5) + g.xo + pass[1];
                local gy = top + g.yo + pass[2];
                list:AddImage(tex, { gx, gy }, { gx + g.w, gy + g.h },
                    { g.x / W, g.y / H }, { (g.x + g.w) / W, (g.y + g.h) / H }, pass[3]);
            end
            pen = pen + f.advance;
        end
    end
end

return bitmapfont;
