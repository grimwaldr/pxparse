--[[
gamefont: draw text in Final Fantasy XI's own font from an Ashita v4 addon's ImGui window.

The font is read from the player's own game install when it's first needed. Nothing from the game
ships with this file. The letters are drawn as small textured quads, so no font is loaded into
ImGui or Ashita.

    local gamefont = require('gamefont');

    -- Inside your d3d_present / ImGui window:
    gamefont.text({ 1, 1, 1, 1 }, 'Hello, Vana\'diel');           -- like imgui.TextColored
    gamefont.number({ 1, 1, 1, 1 }, '163');                       -- the large italic digits

    -- In your unload event:
    gamefont.release();

See README.md for the full API and how it works.

In artisan, the dark ring is baked into a small copy of the letters at load, so each letter is one
quad; drawn ring by ring, a full window of text ran past what Ashita's ImGui draws in one window.

Part of PhoenixTracker's Classic theme (by Grimwald). The DAT reading is adapted from Frankie-hz's
craftbook (github.com/Frankie-hz/craftbook), so this file is GPLv3.
]]--

require('common');
local d3d   = require('d3d8');
local ffi   = require('ffi');
local imgui = require('imgui');
local C     = ffi.C;

pcall(ffi.cdef, 'void* GetModuleHandleA(const char* name);');
pcall(ffi.cdef, 'uint32_t GetModuleFileNameA(void* module, char* path, uint32_t size);');

local gamefont = {};

-----------------------------------
-- Layout of the game's font
-----------------------------------
-- The text font ('moji') keeps each character in a 16 x 16 cell, 64 to a row, from the space (0x20).
-- Letters are white with a dark shadow on their right and bottom, and only as wide as their pixels.
gamefont.CELL    = 16;
gamefont.HEIGHT  = 16;
local PER_ROW    = 64;
local FIRST_CODE = 0x21;
local LAST_CODE  = 0x7E;
local GAP        = 1;    -- pixels between letters, as the game spaces its chat
local SPACE      = 4;    -- the width of a space

-- The large italic digits ('font' sheet, 256 x 256, in the same file): each digit's box, outline
-- included. Each box holds only its own digit.
local DIGIT_TOP    = 131;
local DIGIT_BOTTOM = 154;
local DIGITS = {
    ['0'] = { 16, 34 }, ['1'] = { 38, 51 }, ['2'] = { 54, 73 }, ['3'] = { 75, 93 }, ['4'] = { 94, 112 },
    ['5'] = { 114, 132 }, ['6'] = { 134, 151 }, ['7'] = { 156, 172 }, ['8'] = { 173, 191 }, ['9'] = { 193, 210 },
};
gamefont.NUMBER_HEIGHT = DIGIT_BOTTOM - DIGIT_TOP;
local DIGIT_OVERLAP = 2;  -- the digits lean, so each tucks this far under the one before

-- The font file. Each region's client has its own copy; 119/51 is the one English font mods replace.
local FONT_FILES  = { 'ROM\\119\\51.DAT', 'ROM\\118\\111.DAT', 'ROM\\91\\15.DAT', 'ROM\\0\\1.DAT' };
local FONT_CHUNKS = 4096;

-- The game font's own dark edge is only a shadow on the right and bottom, so over light backgrounds
-- the top and left of each letter fade out. A dark copy one pixel out each way rings every letter.
local RING       = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } };
local RING_ALPHA = 0.9;

-- The ring is baked into a small copy of the plain letters once, at load, so each letter is one quad
-- instead of nine. A list of a few hundred letters drawn ring by ring ran past what Ashita's ImGui
-- draws in one window, and the window's own text came out scrambled. Each letter gets an 18 x 18 cell
-- in the copy: its 16 x 16 cell with a pixel of room on every side for the ring.
local RINGED_CELL    = 18;
local RINGED_PER_ROW = 32;
local RINGED_WIDTH   = 1024;
local RINGED_HEIGHT  = 64;

-----------------------------------
-- Reading the game's DAT files (pure Lua)
-----------------------------------
-- A DAT is a list of chunks, each with a 16-byte header. A texture chunk holds a flag byte, a name,
-- a bitmap header, the format tag ("DXT1" to "DXT5", stored backwards) and the raw DXT blocks.
local CHUNK_HEADER  = 16;
local TEXTURE_CHUNK = 0x20;
local DXT_TEXTURE   = 0xA1;

local function u32(data, offset)
    local a, b, c, d = data:byte(offset + 1, offset + 4);
    return a + b * 256 + c * 65536 + d * 16777216;
end

local function write_u32(value)
    return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256);
end

-- Raw DXT blocks wrapped in a DDS header, so D3DX can load them as a file.
local function as_dds(width, height, fourcc, blocks)
    local zero = write_u32(0);
    return table.concat({
        'DDS ', write_u32(124), write_u32(0x81007), write_u32(height), write_u32(width), write_u32(#blocks), zero, zero,
        zero:rep(11),
        write_u32(32), write_u32(0x4), fourcc, zero:rep(5),
        write_u32(0x1000), zero:rep(4),
        blocks,
    });
end

local function read_texture(body)
    if (#body < 29 or body:byte(1) ~= DXT_TEXTURE) then
        return nil;
    end
    local name   = body:sub(10, 17):gsub('%s+$', '');
    local width  = u32(body, 21);
    local height = u32(body, 25);
    local format = 17 + u32(body, 17);
    local fourcc = body:sub(format + 1, format + 4):reverse();
    if (fourcc:match('^DXT[1-5]$') == nil) then
        return nil;
    end
    local block_size = (fourcc == 'DXT1') and 8 or 16;
    local length     = math.ceil(width / 4) * math.ceil(height / 4) * block_size;
    local blocks     = body:sub(format + 13, format + 12 + length);
    if (#blocks ~= length) then
        return nil;
    end
    return { name = name, width = width, height = height, fourcc = fourcc, blocks = blocks };
end

-- The textures in a DAT (held as a string) whose names are in wanted (a set), keyed by name.
function gamefont.textures(data, wanted, max_chunks)
    local found  = {};
    local offset = 0;
    for _ = 1, max_chunks or FONT_CHUNKS do
        if (offset + CHUNK_HEADER > #data) then
            break;
        end
        local packed = u32(data, offset + 4);
        local size   = (math.floor(packed / 128) % 0x80000) * 16;
        if (size == 0) then
            break;
        end
        if (packed % 128 == TEXTURE_CHUNK) then
            local texture = read_texture(data:sub(offset + CHUNK_HEADER + 1, offset + size));
            if (texture and (wanted == nil or wanted[texture.name])) then
                found[texture.name] = texture;
            end
        end
        offset = offset + size;
    end
    return found;
end

-- Each letter's columns in its cell, read from the DXT3 alpha: { [code] = { left, width } }.
function gamefont.glyph_widths(texture)
    if (texture.fourcc ~= 'DXT3') then
        return nil;
    end
    local blocks_wide = math.ceil(texture.width / 4);
    local blocks      = texture.blocks;
    -- A DXT3 block is 16 bytes: 8 bytes of alpha, 4 bits a pixel in rows of 4, then the colour.
    local function alpha(x, y)
        local block = math.floor(y / 4) * blocks_wide + math.floor(x / 4);
        local pixel = (y % 4) * 4 + (x % 4);
        local byte  = blocks:byte(block * 16 + math.floor(pixel / 2) + 1) or 0;
        return (pixel % 2 == 0) and byte % 16 or math.floor(byte / 16);
    end

    local widths, cell = {}, gamefont.CELL;
    for code = FIRST_CODE, LAST_CODE do
        local index = code - 0x20;
        local cx, cy = (index % PER_ROW) * cell, math.floor(index / PER_ROW) * cell;
        local left, right = nil, nil;
        for x = 0, cell - 1 do
            for y = 0, cell - 1 do
                if (alpha(cx + x, cy + y) > 0) then
                    left, right = left or x, x;
                    break;
                end
            end
        end
        if (left ~= nil) then
            widths[code] = { left = left, width = right - left + 1 };
        end
    end
    return widths;
end

-- Decodes one pixel of a DXT3 texture: r, g, b, a from 0 to 255. Blocks are cached as they're read.
local function dxt3_reader(texture)
    local blocks_wide = math.ceil(texture.width / 4);
    local blocks      = texture.blocks;
    local cache       = {};

    local function expand(c)
        local r, g, b = math.floor(c / 2048) % 32, math.floor(c / 32) % 64, c % 32;
        return math.floor(r * 255 / 31 + 0.5), math.floor(g * 255 / 63 + 0.5), math.floor(b * 255 / 31 + 0.5);
    end

    local function block(index)
        local found = cache[index];
        if (found) then
            return found;
        end
        local o  = index * 16;
        local c0 = blocks:byte(o + 9) + blocks:byte(o + 10) * 256;
        local c1 = blocks:byte(o + 11) + blocks:byte(o + 12) * 256;
        local r0, g0, b0 = expand(c0);
        local r1, g1, b1 = expand(c1);
        found = {
            o = o,
            colors = {
                [0] = { r0, g0, b0 }, { r1, g1, b1 },
                { math.floor((2 * r0 + r1) / 3), math.floor((2 * g0 + g1) / 3), math.floor((2 * b0 + b1) / 3) },
                { math.floor((r0 + 2 * r1) / 3), math.floor((g0 + 2 * g1) / 3), math.floor((b0 + 2 * b1) / 3) },
            },
            indices = u32(blocks, o + 12),
        };
        cache[index] = found;
        return found;
    end

    return function (x, y)
        local b     = block(math.floor(y / 4) * blocks_wide + math.floor(x / 4));
        local pixel = (y % 4) * 4 + (x % 4);
        local byte  = blocks:byte(b.o + math.floor(pixel / 2) + 1) or 0;
        local alpha = (pixel % 2 == 0) and byte % 16 or math.floor(byte / 16);
        local color = b.colors[math.floor(b.indices / (4 ^ pixel)) % 4];
        return color[1], color[2], color[3], alpha * 17;
    end
end

-- The plain letters (0x21 to 0x7E) with the dark ring drawn in, as raw BGRA rows for an uncompressed
-- texture. The letter's own pixels are kept; empty pixels touching it become the ring.
function gamefont.ringed_pixels(texture)
    if (texture.fourcc ~= 'DXT3') then
        return nil;
    end
    local read  = dxt3_reader(texture);
    local cell  = gamefont.CELL;
    local w, h  = RINGED_WIDTH, RINGED_HEIGHT;
    local alpha = {};
    local color = {};
    for code = FIRST_CODE, LAST_CODE do
        local index  = code - 0x20;
        local sx, sy = (index % PER_ROW) * cell, math.floor(index / PER_ROW) * cell;
        local dx, dy = (index % RINGED_PER_ROW) * RINGED_CELL + 1, math.floor(index / RINGED_PER_ROW) * RINGED_CELL + 1;
        for y = 0, cell - 1 do
            for x = 0, cell - 1 do
                local r, g, b, a = read(sx + x, sy + y);
                if (a > 0) then
                    local at = (dy + y) * w + (dx + x);
                    alpha[at] = a;
                    color[at] = string.char(b, g, r, a);
                end
            end
        end
    end
    local ring  = string.char(0, 0, 0, math.floor(RING_ALPHA * 255 + 0.5));
    local clear = string.char(0, 0, 0, 0);
    local rows  = {};
    for y = 0, h - 1 do
        local row = {};
        for x = 0, w - 1 do
            local at = y * w + x;
            local pixel = color[at];
            if (pixel == nil) then
                pixel = clear;
                for _, offset in ipairs(RING) do
                    local nx, ny = x + offset[1], y + offset[2];
                    if (nx >= 0 and ny >= 0 and nx < w and ny < h and alpha[ny * w + nx]) then
                        pixel = ring;
                        break;
                    end
                end
            end
            row[x + 1] = pixel;
        end
        rows[y + 1] = table.concat(row);
    end
    return table.concat(rows), w, h;
end

local function copy(texture, blocks)
    return { name = texture.name, width = texture.width, height = texture.height, fourcc = texture.fourcc, blocks = blocks };
end

-- A DXT3 texture with its alpha doubled. The digits' sheet counts 0x80 as opaque, so drawn as it is
-- it comes out half see-through.
function gamefont.double_alpha(texture)
    local doubled = {};
    for value = 0, 255 do
        doubled[value] = string.char(math.min(15, math.floor(value / 16) * 2) * 16 + math.min(15, (value % 16) * 2));
    end
    local parts = {};
    for offset = 1, #texture.blocks, 16 do
        parts[#parts + 1] = texture.blocks:sub(offset, offset + 7):gsub('.', function (c) return doubled[c:byte()]; end);
        parts[#parts + 1] = texture.blocks:sub(offset + 8, offset + 15);
    end
    return copy(texture, table.concat(parts));
end

-- A DXT3 texture with the black specks the compression left in its dark outlines made the outline's
-- grey, so they don't show as dots. Only drawn, near-black pixels in a block that also holds the grey
-- change.
local function red(colour)
    return math.floor(bit.rshift(colour, 11) % 32 * 255 / 31);
end

function gamefont.even_outline(texture)
    local parts = {};
    for offset = 1, #texture.blocks, 16 do
        local block  = texture.blocks:sub(offset, offset + 15);
        local r0     = red(block:byte(9) + block:byte(10) * 256);
        local r1     = red(block:byte(11) + block:byte(12) * 256);
        local shades = { [0] = r0, r1, math.floor((2 * r0 + r1) / 3), math.floor((r0 + 2 * r1) / 3) };
        local grey   = nil;
        for index = 0, 3 do
            if (shades[index] >= 25 and shades[index] <= 80 and (grey == nil or shades[index] > shades[grey])) then
                grey = index;
            end
        end
        if (grey ~= nil) then
            local indices = block:byte(13) + block:byte(14) * 256 + block:byte(15) * 65536 + block:byte(16) * 16777216;
            local changed = indices;
            for pixel = 0, 15 do
                local alpha = bit.rshift(block:byte(math.floor(pixel / 2) + 1), (pixel % 2) * 4) % 16;
                if (alpha > 0 and shades[bit.rshift(indices, pixel * 2) % 4] < 20) then
                    changed = bit.bor(bit.band(changed, bit.bnot(bit.lshift(3, pixel * 2))), bit.lshift(grey, pixel * 2));
                end
            end
            if (changed ~= indices) then
                changed = changed % 4294967296;
                block = block:sub(1, 12) .. write_u32(changed);
            end
        end
        parts[#parts + 1] = block;
    end
    return copy(texture, table.concat(parts));
end

-----------------------------------
-- Finding the game install and making textures
-----------------------------------
local function running_client_folder()
    local module = C.GetModuleHandleA('FFXiMain.dll');
    if (module == nil) then
        return nil;
    end
    local buffer = ffi.new('char[?]', 260);
    local length = C.GetModuleFileNameA(module, buffer, 260);
    if (length == 0) then
        return nil;
    end
    return ffi.string(buffer, length):match('^(.*)[\\/][^\\/]*$');
end

local function registered_client_folder()
    local language = AshitaCore:GetConfigurationManager():GetInt32('boot', 'ashita.language', 'playonline', 2);
    return ashita.fs.get_install_dir(language, 1);
end

-- One of the game's own files (a name like 'ROM\119\51.DAT') as a string, or nil. Read-only.
local function read_rom(name)
    for _, finder in ipairs({ running_client_folder, registered_client_folder }) do
        local ok, folder = pcall(finder);
        if (ok and folder ~= nil and folder ~= '') then
            local file = io.open(('%s\\%s'):fmt(folder, name), 'rb');
            if (file ~= nil) then
                local data = file:read('*a');
                file:close();
                return data;
            end
        end
    end
    return nil;
end

-- An uncompressed 32-bit DDS from BGRA rows.
local function as_dds_bgra(width, height, pixels)
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

local function create_texture(texture)
    local image  = texture.dds or as_dds(texture.width, texture.height, texture.fourcc, texture.blocks);
    local out    = ffi.new('IDirect3DTexture8*[1]');
    local result = C.D3DXCreateTextureFromFileInMemoryEx(d3d.get_device(), image, #image, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
        C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED, 1, C.D3DX_DEFAULT, 0, nil, nil, out);
    if (result ~= C.S_OK) then
        return nil;
    end
    local handle = ffi.cast('IDirect3DTexture8*', out[0]);
    return { texture = handle, id = tonumber(ffi.cast('uint32_t', handle)) };
end

-----------------------------------
-- Loading
-----------------------------------
local font   = nil;   -- the loaded font, false once loading has failed
local reason = nil;

-- Reads the font from the game install. Called for you the first time anything is drawn; call it
-- yourself to find out early whether it worked. Returns true, or nil and the reason.
-- options.read replaces the file reader (a function from a name like 'ROM\119\51.DAT' to its data).
function gamefont.load(options)
    if (font ~= nil) then
        return font and true or nil, reason;
    end
    local read = options and options.read or read_rom;
    font, reason = false, 'the game\'s font file was not found in the game install';
    for _, name in ipairs(FONT_FILES) do
        local data = read(name);
        local found = data and gamefont.textures(data, { moji = true, font = true }) or {};
        local glyphs = found.moji and gamefont.glyph_widths(found.moji);
        if (glyphs ~= nil) then
            local letters = (options and options.no_textures) and { id = 0 } or create_texture(found.moji);
            if (letters == nil) then
                reason = 'the font texture could not be made';
                return nil, reason;
            end
            font = { letters = letters, width = found.moji.width, height = found.moji.height, glyphs = glyphs };
            local ok, pixels, w, h = pcall(gamefont.ringed_pixels, found.moji);
            if (ok and pixels ~= nil) then
                font.ringed = (options and options.no_textures) and { id = 0 }
                    or create_texture({ dds = as_dds_bgra(w, h, pixels) });
                font.ringed_pixels = (options and options.keep_pixels) and pixels or nil;
            end
            local sheet = found.font;
            if (sheet and sheet.fourcc == 'DXT3' and sheet.width == 256 and sheet.height == 256) then
                local ready = gamefont.double_alpha(gamefont.even_outline(sheet));
                font.digits = (options and options.no_textures) and { id = 0 } or create_texture(ready);
            end
            reason = nil;
            return true;
        end
    end
    return nil, reason;
end

-- True once the font has loaded. Loads it if it hasn't been tried yet.
function gamefont.available()
    return gamefont.load() == true;
end

-- Whether the large digits loaded too (some region's files don't have them).
function gamefont.has_numbers()
    return gamefont.available() and font.digits ~= nil;
end

-- Frees the textures. Call it from your unload event.
function gamefont.release()
    if (font) then
        if (font.letters.texture) then font.letters.texture:Release(); end
        if (font.digits and font.digits.texture) then font.digits.texture:Release(); end
        if (font.ringed and font.ringed.texture) then font.ringed.texture:Release(); end
    end
    font, reason = nil, nil;
end

-----------------------------------
-- Measuring and drawing
-----------------------------------
-- True when every character is plain ASCII the font has (letters, digits, symbols and spaces).
function gamefont.plain(text)
    return type(text) == 'string' and not text:find('[^\32-\126]');
end

-- How many pixels wide text is in the game font: one pixel between letters, none after the last.
function gamefont.width(text)
    if (not gamefont.available()) then
        return 0;
    end
    local width, glyph = 0, nil;
    for index = 1, #text do
        glyph = font.glyphs[text:byte(index)];
        width = width + (glyph and (glyph.width + GAP) or SPACE);
    end
    return glyph and width - GAP or width;
end

local function packed(color, alpha)
    return imgui.GetColorU32({ color[1], color[2], color[3], alpha or color[4] or 1 });
end

-- Draws text with its top-left at (x, y) on an ImGui draw list. color is { r, g, b, a } from 0 to 1.
-- options.ring = false leaves out the dark outline. Letters land on whole pixels, as the game draws
-- them; the font is a bitmap, so draw it at its own size. Returns the width drawn.
function gamefont.draw(list, x, y, color, text, options)
    if (not gamefont.available()) then
        return 0;
    end
    local ring  = not (options and options.ring == false);
    local left0 = math.floor(x + 0.5);
    local top   = math.floor(y + 0.5);
    local fill  = packed(color);
    local dark  = packed({ 0, 0, 0 }, RING_ALPHA * (color[4] or 1));
    local cell  = gamefont.CELL;
    -- With the ring baked in, one quad a letter: the letter's columns plus a pixel all round.
    if (ring and font.ringed) then
        local left = left0;
        for index = 1, #text do
            local code  = text:byte(index);
            local glyph = font.glyphs[code];
            if (glyph) then
                local slot = code - 0x20;
                local u    = (slot % RINGED_PER_ROW) * RINGED_CELL + glyph.left;
                local v    = math.floor(slot / RINGED_PER_ROW) * RINGED_CELL;
                list:AddImage(font.ringed.id, { left - 1, top - 1 }, { left + glyph.width + 1, top + cell + 1 },
                    { u / RINGED_WIDTH, v / RINGED_HEIGHT },
                    { (u + glyph.width + 2) / RINGED_WIDTH, (v + RINGED_CELL) / RINGED_HEIGHT }, fill);
                left = left + glyph.width + GAP;
            else
                left = left + SPACE;
            end
        end
        return gamefont.width(text);
    end
    -- Every ring first, so one letter's ring never covers the letter before it.
    for pass = ring and 1 or 2, 2 do
        local left = left0;
        for index = 1, #text do
            local code  = text:byte(index);
            local glyph = font.glyphs[code];
            if (glyph) then
                local slot = code - 0x20;
                local u    = (slot % PER_ROW) * cell + glyph.left;
                local v    = math.floor(slot / PER_ROW) * cell;
                local uv0  = { u / font.width, v / font.height };
                local uv1  = { (u + glyph.width) / font.width, (v + cell) / font.height };
                if (pass == 1) then
                    for _, offset in ipairs(RING) do
                        local ox, oy = left + offset[1], top + offset[2];
                        list:AddImage(font.letters.id, { ox, oy }, { ox + glyph.width, oy + cell }, uv0, uv1, dark);
                    end
                else
                    list:AddImage(font.letters.id, { left, top }, { left + glyph.width, top + cell }, uv0, uv1, fill);
                end
                left = left + glyph.width + GAP;
            else
                left = left + SPACE;
            end
        end
    end
    return gamefont.width(text);
end

local function cursor()
    local a, b = imgui.GetCursorScreenPos();
    if (type(a) ~= 'number') then
        return a.x, a.y;
    end
    return a, b;
end

-- Use in place of imgui.TextColored: draws at the cursor, centred in a text line, and takes up the
-- space so the next item goes below it. Falls back to imgui.TextColored for text the font doesn't
-- have (accents, Japanese) or when the font can't be read.
function gamefont.text(color, text, options)
    if (not gamefont.plain(text) or not gamefont.available()) then
        imgui.TextColored(color, text);
        return;
    end
    local x, y   = cursor();
    local height = imgui.GetTextLineHeight();
    gamefont.draw(imgui.GetWindowDrawList(), x, y + (height - gamefont.CELL) / 2, color, text, options);
    imgui.Dummy({ math.max(gamefont.width(text), 1), height });
end

-- How many pixels wide a number is in the large digits.
function gamefont.number_width(text)
    local width = 0;
    for index = 1, #text do
        local box = DIGITS[text:sub(index, index)];
        if (box) then
            width = width + box[2] - box[1] - DIGIT_OVERLAP;
        end
    end
    return width > 0 and width + DIGIT_OVERLAP or 0;
end

-- Draws a whole number (digits only) in the game's large italic digits, top-left at (x, y). The
-- digits are already outlined. color tints them. Returns the width drawn, or nil if it can't
-- (the digits didn't load, or text isn't all digits) so you can fall back.
function gamefont.draw_number(list, x, y, color, text)
    if (not gamefont.has_numbers() or not tostring(text):match('^%d+$')) then
        return nil;
    end
    text = tostring(text);
    local left, top, tint = math.floor(x + 0.5), math.floor(y + 0.5), packed(color);
    for index = 1, #text do
        local box = DIGITS[text:sub(index, index)];
        list:AddImage(font.digits.id, { left, top }, { left + box[2] - box[1], top + gamefont.NUMBER_HEIGHT },
            { box[1] / 256, DIGIT_TOP / 256 }, { box[2] / 256, DIGIT_BOTTOM / 256 }, tint);
        left = left + box[2] - box[1] - DIGIT_OVERLAP;
    end
    return gamefont.number_width(text);
end

-- Use in place of a big imgui.TextColored for a count. Falls back to imgui.TextColored.
function gamefont.number(color, text)
    local x, y  = cursor();
    local width = gamefont.draw_number(imgui.GetWindowDrawList(), x, y, color, text);
    if (width == nil) then
        imgui.TextColored(color, tostring(text));
        return;
    end
    imgui.Dummy({ width, gamefont.NUMBER_HEIGHT });
end

return gamefont;
