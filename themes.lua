--[[
* pxparse - themes
* The three looks: Phoenix (dark red and ember, the starting theme),
* Classic (the game's own window art and font, see skin.lua and gamefont.lua) and Default (plain
* ImGui, like most Ashita addons).
*
* Each theme fills the same palette (ui.COLOR's names) and a few style values, so the view draws
* every theme with the same code. Classic's colours are sampled from each Window Type's art, so the
* flat parts sit with the art behind them; they're also what shows if the art can't be read.
--]]

local skin = require('skin');

local themes = {};

local function hex(h, alpha)
    return {
        tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255,
        alpha or 1,
    };
end

local function shade(c, factor, alpha)
    return { c[1] * factor, c[2] * factor, c[3] * factor, alpha or 1 };
end

local function fade(c, alpha)
    return { c[1], c[2], c[3], alpha };
end

local function lighten(c, amount)
    return { c[1] + (1 - c[1]) * amount, c[2] + (1 - c[2]) * amount, c[3] + (1 - c[3]) * amount, 1 };
end

-----------------------------------
-- Phoenix
-----------------------------------
local PHOENIX = {
    key = 'phoenix', name = 'Phoenix',
    accent = true,          -- the ember line along the top edge
    window_rounding = 8, frame_rounding = 4, bar_rounding = 4, window_border = 1,
    padding = { 12, 10 },
    palette = {
        abyss     = hex('180e0e'),
        surface1  = hex('291c1c'),
        surface2  = hex('321f1f'),
        border    = hex('d2abab', 0.20),
        subtle    = hex('d2abab', 0.12),
        text      = hex('fff8f8'),
        secondary = hex('eae1e1'),
        peach     = hex('d2abab'),
        muted     = hex('8a6b6b'),
        faint     = hex('5a4545'),
        royal     = hex('c55151'),
        tint      = hex('c55151', 0.30),
        hover     = hex('d45e5e'),
        ember     = hex('ff8d79'),
        danger    = hex('e04040'),
        gold      = hex('c5a131'),
        success   = hex('63ba8a'),
        -- Bar fills with job colours on: deep enough that every job colour reads on them.
        bar_deep  = hex('833b3b'),
        gold_deep = hex('836629'),
        row_alt   = hex('291c1c'),
    },
};

-----------------------------------
-- Default: ImGui's own dark style
-----------------------------------
local DEFAULT = {
    key = 'default', name = 'Default',
    accent = false,
    window_rounding = 0, frame_rounding = 0, bar_rounding = 0, window_border = 1,
    padding = { 12, 10 },
    palette = {
        abyss     = { 0.06, 0.06, 0.06, 1 },
        surface1  = { 0.12, 0.12, 0.14, 1 },
        surface2  = { 0.16, 0.29, 0.48, 0.54 },
        border    = { 0.43, 0.43, 0.50, 0.50 },
        subtle    = { 0.23, 0.23, 0.25, 1 },
        text      = { 1.00, 1.00, 1.00, 1 },
        secondary = { 0.86, 0.86, 0.86, 1 },
        peach     = { 0.62, 0.78, 1.00, 1 },
        muted     = { 0.50, 0.50, 0.50, 1 },
        faint     = { 0.36, 0.36, 0.36, 1 },
        royal     = { 0.26, 0.59, 0.98, 0.80 },
        tint      = { 0.26, 0.59, 0.98, 0.31 },
        hover     = { 0.26, 0.59, 0.98, 1.00 },
        ember     = { 1.00, 0.60, 0.35, 1 },
        danger    = { 0.95, 0.45, 0.40, 1 },
        gold      = { 0.90, 0.70, 0.00, 1 },
        success   = { 0.45, 0.85, 0.45, 1 },
        bar_deep  = { 0.17, 0.33, 0.55, 1 },
        gold_deep = { 0.52, 0.41, 0.05, 1 },
        row_alt   = { 1, 1, 1, 0.06 },
    },
};

-----------------------------------
-- Classic: one look per Window Type
-----------------------------------
-- Sampled from each type's background and frame.
local WINDOW_ART = {
    [0] = { background = hex('282452'), frame = hex('888988') },
    [1] = { background = hex('5D5C6F'), frame = hex('9698A6') },
    [2] = { background = hex('23204D'), frame = hex('888988') },
    [3] = { background = hex('2B2B2B'), frame = hex('9698A6') },
    [4] = { background = hex('626262'), frame = hex('888988') },
    [5] = { background = hex('001948'), frame = hex('5A4418') },
    [6] = { background = hex('9E8F64'), frame = hex('867953') },
    [7] = { background = hex('1C353F'), frame = hex('314E57') },
};

-- The middle of the top-down shading skin.lua draws the art with.
local ART_SHADE = 0.62;

local function classic(window_type)
    local art    = WINDOW_ART[window_type];
    local panel  = shade(art.background, ART_SHADE);
    local accent = lighten(art.frame, 0.25);
    local gold   = { 0.98, 0.82, 0.38, 1 };
    return {
        key = 'classic', name = 'Classic',
        skin = window_type,     -- skin.lua paints this type's art behind the window
        accent = false,         -- the art has its own frame
        bars = 'gauge',         -- rows as the game draws lists: text on the art, a thin gauge under it
        window_rounding = 0, frame_rounding = 2, bar_rounding = 2, window_border = 0,
        padding = { 12, 12 },   -- clear of the frame art
        palette = {
            abyss     = panel,
            surface1  = shade(panel, 0.85),
            surface2  = { 0, 0, 0, 0.34 },
            border    = fade(accent, 0.55),
            subtle    = fade(accent, 0.25),
            text      = { 0.96, 0.96, 0.93, 1 },
            secondary = { 0.88, 0.88, 0.85, 1 },
            peach     = { 1.00, 0.87, 0.48, 1 },  -- the game's title gold
            muted     = { 0.74, 0.74, 0.72, 1 },
            faint     = { 0.58, 0.58, 0.56, 1 },
            royal     = fade(accent, 0.62),
            tint      = fade(accent, 0.24),
            hover     = fade(accent, 0.78),
            ember     = { 1.00, 0.58, 0.46, 1 },
            danger    = { 1.00, 0.52, 0.46, 1 },
            gold      = gold,
            success   = { 0.52, 0.90, 0.52, 1 },
            bar_deep  = fade(accent, 0.45),
            gold_deep = fade(gold, 0.45),
            row_alt   = { 1, 1, 1, 0.05 },  -- light enough that the art shows through
        },
    };
end

local CLASSIC = {};
for window_type in pairs(WINDOW_ART) do
    CLASSIC[window_type] = classic(window_type);
end

-----------------------------------
-- Picking
-----------------------------------
themes.ORDER = { 'phoenix', 'classic', 'default' };
themes.NAMES = { phoenix = 'Phoenix', classic = 'Classic', default = 'Default' };
themes.WINDOW_TYPES = 8;

--[[
* The theme to draw with. Classic follows the game's Config > Windows > Shared > Window Type, or
* `window_type` (0-7) when one is pinned (-1 follows the game).
--]]
function themes.get(key, window_type)
    if (key == 'classic') then
        skin.forced = window_type or -1;
        return CLASSIC[skin.window_type()] or CLASSIC[0];
    end
    if (key == 'default') then
        return DEFAULT;
    end
    return PHOENIX;
end

-- A theme key from a name typed in chat, or nil.
function themes.find(text)
    text = (text or ''):lower();
    for _, key in ipairs(themes.ORDER) do
        if (key == text or themes.NAMES[key]:lower() == text) then
            return key;
        end
    end
    return nil;
end

return themes;
