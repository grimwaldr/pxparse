--[[
* pxparse - ui
* Drawing helpers, in the active theme (themes.lua). ui.COLOR holds the theme's palette; switching
* theme rewrites the colours in place, so every table that refers to them follows.
*
* All text goes through ui.text, ui.text_width and ui.draw_text. Under Classic they draw in the
* game's own font (gamefont.lua) at UI scale 1, or the normal font ringed in dark at other sizes or
* when the font can't be read, the way the game rings its text. Other themes draw as ImGui does.
--]]

require('common');

local chat     = require('chat');
local imgui    = require('imgui');
local themes   = require('themes');
local skin     = require('skin');
local gamefont = require('gamefont');

local ui = {};

ui.PADDING    = 12;
ui.BASE_WIDTH = 360;

function ui.rgb(hex, alpha)
    return {
        tonumber(hex:sub(1, 2), 16) / 255,
        tonumber(hex:sub(3, 4), 16) / 255,
        tonumber(hex:sub(5, 6), 16) / 255,
        alpha or 1.0,
    };
end

local rgb = ui.rgb;

-- The palette's names. Each starts as a placeholder; ui.use_theme fills them in place.
ui.COLOR = T{ clear = { 0, 0, 0, 0 } };
local COLOR = ui.COLOR;
for name in pairs(themes.get('phoenix').palette) do
    COLOR[name] = { 0, 0, 0, 1 };
end

ui.theme = nil;

-- Makes `key` ('phoenix', 'classic', 'default') the theme drawn with. `window_type` pins Classic
-- to one Window Type (0-7); -1 follows the game.
function ui.use_theme(key, window_type)
    local theme = themes.get(key, window_type);
    if (theme ~= ui.theme) then
        for name, value in pairs(theme.palette) do
            local c = COLOR[name];
            c[1], c[2], c[3], c[4] = value[1], value[2], value[3], value[4] or 1;
        end
        ui.theme = theme;
    end
    return theme;
end

ui.use_theme('phoenix');

-- Name colours by main job. Not a single game convention: picked for distinct hues that read on
-- the theme's dark reds. 0 is no job known (outside the party, or anon).
ui.JOB_COLOR = {
    [0]  = rgb('b8b8b8'), -- none
    [1]  = rgb('f79389'), -- WAR
    [2]  = rgb('f7a964'), -- MNK
    [3]  = rgb('f4f1eb'), -- WHM
    [4]  = rgb('ba97f7'), -- BLM
    [5]  = rgb('f68ed0'), -- RDM
    [6]  = rgb('6cda75'), -- THF
    [7]  = rgb('c4d6e9'), -- PLD
    [8]  = rgb('c09cc0'), -- DRK
    [9]  = rgb('d2b289'), -- BST
    [10] = rgb('f7ec6e'), -- BRD
    [11] = rgb('b3dd5f'), -- RNG
    [12] = rgb('f5c43d'), -- SAM
    [13] = rgb('a3a3a3'), -- NIN: neutral grey, the darkest that still reads on the bars
    [14] = rgb('9eaafa'), -- DRG
    [15] = rgb('5fd5f2'), -- SMN
    [16] = rgb('79aefb'), -- BLU
    [17] = rgb('f7926e'), -- COR
    [18] = rgb('a5c1d4'), -- PUP
    [19] = rgb('74dcb1'), -- DNC
    [20] = rgb('cbb0dd'), -- SCH
    [21] = rgb('de97ed'), -- GEO
    [22] = rgb('eb8ead'), -- RUN
};

-- Jobs drawn with an outline in this colour (none at the moment; kept for darker colours).
ui.JOB_OUTLINE = {};

ui.JOB_ABBR = {
    'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG',
    'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN',
};

-----------------------------------
-- Messages and formatting
-----------------------------------
function ui.say(message)
    print(chat.header(addon.name):append(chat.message(message)));
end

function ui.warn(message)
    print(chat.header(addon.name):append(chat.warning(message)));
end

function ui.duration(seconds)
    seconds = math.max(0, math.floor(seconds));
    local hours   = math.floor(seconds / 3600);
    local minutes = math.floor((seconds % 3600) / 60);
    if (hours > 0) then
        return ('%dh %02dm'):fmt(hours, minutes);
    end
    return ('%dm %02ds'):fmt(minutes, seconds % 60);
end

-- 1234567 -> 1,234,567
function ui.number(n)
    local s = tostring(math.floor(n + 0.5));
    local sign, digits = s:match('^(-?)(%d+)$');
    if (not digits) then
        return s;
    end
    return sign .. digits:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '');
end

function ui.decimal(n)
    if (n >= 1000) then
        return ui.number(n);
    end
    return ('%.1f'):fmt(n);
end

function ui.percent(part, whole)
    if (not whole or whole <= 0) then
        return '-';
    end
    local value = part * 100 / whole;
    if (value > 0 and value < 10) then
        return ('%.1f%%'):fmt(value);
    end
    return ('%.0f%%'):fmt(value);
end

-- 21094 -> 21.1k, for figures where the exact count doesn't matter (rates).
function ui.compact(n)
    if (n >= 100000) then
        return ('%dk'):fmt(math.floor(n / 1000 + 0.5));
    end
    if (n >= 10000) then
        return ('%.1fk'):fmt(n / 1000);
    end
    return ui.number(n);
end

-- 161 -> 2:41, a countdown.
function ui.clock(seconds)
    seconds = math.max(0, math.ceil(seconds));
    return ('%d:%02d'):fmt(math.floor(seconds / 60), seconds % 60);
end

-----------------------------------
-- Positions
-----------------------------------
-- Ashita returns an ImVec2 as two numbers from some calls and as an object from others.
function ui.vec2(a, b)
    if (a ~= nil and type(a) ~= 'number') then
        return a.x or a[1], a.y or a[2];
    end
    return a, b;
end

-----------------------------------
-- Text
-----------------------------------
ui.font_base = nil;    -- the font size before pxparse's scale, set each frame
ui.game_font = true;   -- the setting for the active theme: draw in the game font
local font_off = false; -- set if drawing in the game font ever fails
local warned   = false;

local RING = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } };

local function classic()
    return ui.theme ~= nil and ui.theme.skin ~= nil;
end

-- Whether this text, here, is drawn in the game font: the setting on for this theme (by default only
-- Classic), plain ASCII, and at the font's own size (the game font is a bitmap; scaled or big text
-- uses the normal font, ringed under Classic).
local function game_font(text)
    if (font_off or not ui.game_font or not ui.font_base or not gamefont.plain(text)) then
        return false;
    end
    if (math.abs(imgui.GetFontSize() - ui.font_base) > 0.01) then
        return false;
    end
    local ok, reason = gamefont.load();
    if (not ok and not warned) then
        warned = true;
        ui.say(('Game font: %s. Using the normal font.'):fmt(tostring(reason)));
    end
    return ok == true;
end

local function font_failed(problem)
    if (not font_off) then
        font_off = true;
        ui.say(('Game font is off for this session: %s'):fmt(tostring(problem)));
    end
end

function ui.text_width(text)
    text = tostring(text);
    if (game_font(text)) then
        return gamefont.width(text);
    end
    local width = imgui.CalcTextSize(text);
    if (type(width) ~= 'number') then
        return ui.vec2(width) or 0;
    end
    return width;
end

--[[
* Text at a screen position (top-left of a text line). `outline` rings it in that colour, `shadow`
* gives it a 1px drop shadow. Under Classic every letter is ringed in dark, as the game draws it.
--]]
function ui.draw_text(list, x, y, color, text, outline, shadow)
    text = tostring(text);
    if (game_font(text)) then
        local ok, problem = pcall(gamefont.draw, list, x, y + (imgui.GetTextLineHeight() - gamefont.CELL) / 2, color, text);
        if (ok) then
            return;
        end
        font_failed(problem);
    end
    if (classic() and not outline) then
        outline = { 0, 0, 0, 0.9 * (color[4] or 1) };
    end
    if (outline) then
        local oc = imgui.GetColorU32(outline);
        for _, o in ipairs(RING) do
            list:AddText({ x + o[1], y + o[2] }, oc, text);
        end
    elseif (shadow) then
        list:AddText({ x + 1, y + 1 }, imgui.GetColorU32({ 0, 0, 0, 0.75 }), text);
    end
    list:AddText({ x, y }, imgui.GetColorU32(color), text);
end

--[[
* Text in the layout, in place of imgui.TextColored. `framed` lines it up with buttons on the same
* row (as AlignTextToFramePadding does for ImGui's own text).
--]]
function ui.text(color, text, framed)
    text = tostring(text);
    if (not classic() and not game_font(text)) then
        if (framed) then
            imgui.AlignTextToFramePadding();
        end
        imgui.TextColored(color, text);
        return;
    end
    local x, y   = ui.vec2(imgui.GetCursorScreenPos());
    local line   = imgui.GetTextLineHeight();
    local height = framed and imgui.GetFrameHeight() or line;
    ui.draw_text(imgui.GetWindowDrawList(), x, y + (height - line) / 2, color, text);
    imgui.Dummy({ math.max(ui.text_width(text), 1), height });
end

function ui.right_text(width, color, text, framed)
    imgui.SameLine(ui.PADDING + width - ui.text_width(text));
    ui.text(color, text, framed);
end

function ui.stat_cell(label, value, color)
    imgui.TableNextColumn();
    ui.text(COLOR.muted, label);
    ui.text(color or COLOR.text, value);
end

-- A name: plain, or ringed in `outline` when it needs one.
function ui.name_text(color, text, outline)
    if (not outline) then
        ui.text(color, text);
        return;
    end
    local x, y = ui.vec2(imgui.GetCursorScreenPos());
    ui.draw_text(imgui.GetWindowDrawList(), x, y, color, text, outline);
    imgui.Dummy({ ui.text_width(text), imgui.GetTextLineHeight() });
end

function ui.right_name(width, color, text, outline)
    imgui.SameLine(ui.PADDING + width - ui.text_width(text));
    ui.name_text(color, text, outline);
end

-- A tooltip drawn line by line: SetTooltip formats like printf, so a '%' would be read as a code.
function ui.tooltip(lines, color)
    imgui.BeginTooltip();
    for _, line in ipairs(lines) do
        ui.text(color or COLOR.text, line);
    end
    imgui.EndTooltip();
end

-- Wraps at the window edge, so a long note doesn't stretch the auto-sized window.
function ui.note(width, color, text)
    if (not classic() and not game_font('A')) then
        imgui.PushTextWrapPos(ui.PADDING + width);
        imgui.TextColored(color, text);
        imgui.PopTextWrapPos();
        return;
    end
    -- Text drawn by hand (Classic, or the game font) is broken into lines here.
    local line = '';
    for word in text:gmatch('%S+') do
        local next_line = (line == '') and word or (line .. ' ' .. word);
        if (line ~= '' and ui.text_width(next_line) > width) then
            ui.text(color, line);
            line = word;
        else
            line = next_line;
        end
    end
    if (line ~= '') then
        ui.text(color, line);
    end
end

-- `text` shortened with '..' to fit `width`.
function ui.fit(text, width)
    if (ui.text_width(text) <= width) then
        return text;
    end
    local cut = #text;
    while (cut > 1 and ui.text_width(text:sub(1, cut) .. '..') > width) do
        cut = cut - 1;
    end
    return text:sub(1, cut) .. '..';
end

--[[
* One line of items spread across `width`: the first at the left edge, the last at the right, the
* rest in between. Each item is { text, color, priority, dot = color }. When they don't fit, the
* highest priority number goes first, so the line never runs together at any font size.
*
* Each item gets a slot as wide as the widest text it has shown, so a figure ticking over (a 1 is
* narrower than an 8 in the game font) doesn't slide the rest of the line along. Slots reset when
* the items or the width change. `id` keeps each line's slots apart.
--]]
local slots = {};

function ui.spread(id, items, width)
    local gap  = 14;
    local dot  = math.max(2.5, imgui.GetTextLineHeight() * 0.18) * 2 + 5;
    local kept = {};
    for i, item in ipairs(items) do
        if (item[1] and item[1] ~= '') then
            item.slot = i;
            kept[#kept + 1] = item;
        end
    end

    -- The widest each item has been since the line last changed shape.
    local shape = tostring(math.floor(width));
    for _, item in ipairs(kept) do
        shape = shape .. ',' .. item.slot;
    end
    local memo = slots[id];
    if (not memo or memo.shape ~= shape) then
        memo = { shape = shape, widths = {} };
        slots[id] = memo;
    end
    local function reserved(item)
        local w = ui.text_width(item[1]) + (item.dot and dot or 0);
        local was = memo.widths[item.slot] or 0;
        if (w > was) then
            memo.widths[item.slot] = w;
            return w;
        end
        return was;
    end

    local function total()
        local sum = 0;
        for i, item in ipairs(kept) do
            sum = sum + reserved(item) + (i > 1 and gap or 0);
        end
        return sum;
    end
    while (#kept > 1 and total() > width) do
        local worst = 1;
        for i, item in ipairs(kept) do
            if ((item[3] or 1) >= (kept[worst][3] or 1)) then
                worst = i;
            end
        end
        table.remove(kept, worst);
    end
    if (#kept == 0) then
        return;
    end
    if (#kept == 1) then
        kept[1][1] = ui.fit(kept[1][1], width - (kept[1].dot and dot or 0));
    end

    local widths, used = {}, 0;
    for i, item in ipairs(kept) do
        widths[i] = reserved(item);
        used = used + widths[i];
    end
    local space = #kept > 1 and (width - used) / (#kept - 1) or 0;
    local x = 0;
    for i, item in ipairs(kept) do
        -- Left-aligned in its slot, except the last, which keeps to the right edge.
        local at = x;
        if (i == #kept and #kept > 1) then
            at = width - ui.text_width(item[1]) - (item.dot and dot or 0);
        end
        if (i > 1) then
            imgui.SameLine(ui.PADDING + math.floor(at + 0.5));
        end
        if (item.dot) then
            ui.dot(item.dot);
            imgui.SameLine(0, 5);
        end
        ui.text(item[2], item[1]);
        x = x + widths[i] + space;
    end
end

-----------------------------------
-- Buttons
-----------------------------------
-- An ImGui button with its label drawn by ui.draw_text (so the game font reaches buttons).
-- `align` 0 puts the label at the left, 0.5 centres it.
local function labelled_button(label, size, color, align)
    local text = tostring(label):match('^(.-)##') or tostring(label);
    if (not classic() and not game_font(text)) then
        return imgui.Button(label, size);
    end
    imgui.PushStyleColor(ImGuiCol_Text, COLOR.clear);
    local clicked = imgui.Button(label, size);
    imgui.PopStyleColor(1);
    local x0, y0 = ui.vec2(imgui.GetItemRectMin());
    local x1, y1 = ui.vec2(imgui.GetItemRectMax());
    local w      = ui.text_width(text);
    local tx     = (align == 0) and (x0 + 4) or (x0 + (x1 - x0 - w) / 2);
    ui.draw_text(imgui.GetWindowDrawList(), math.floor(tx + 0.5), y0 + (y1 - y0 - imgui.GetTextLineHeight()) / 2, color, text);
    return clicked;
end

function ui.toggle_button(label, on, width)
    imgui.PushStyleColor(ImGuiCol_Button, on and COLOR.royal or COLOR.surface2);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, on and COLOR.hover or COLOR.tint);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR.royal);
    imgui.PushStyleColor(ImGuiCol_Text, on and COLOR.text or COLOR.muted);
    local clicked = labelled_button(label, { width, 0 }, on and COLOR.text or COLOR.muted);
    imgui.PopStyleColor(4);
    return clicked;
end

ui.CARET = ICON_FA_CARET_DOWN or 'v';

--[[
* A dropdown that's only its text and a caret: no frame until hovered. Returns true when clicked;
* the caller opens its popup. `room` is the most width it may take.
--]]
function ui.dropdown(id, label, color, room)
    color = color or COLOR.secondary;
    local caret   = ui.CARET;
    local caret_w = imgui.CalcTextSize(caret);
    caret_w = type(caret_w) == 'number' and caret_w or (ui.vec2(caret_w) or 8);
    local text = ui.fit(label, math.max(30, room - caret_w - 16));
    local w    = ui.text_width(text) + caret_w + 4 + 8;
    imgui.PushStyleColor(ImGuiCol_Button, COLOR.clear);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR.tint);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR.tint);
    imgui.PushStyleColor(ImGuiCol_Text, COLOR.clear);
    local clicked = imgui.Button('##' .. id, { w, 0 });
    imgui.PopStyleColor(4);
    -- The label and caret are drawn over the button, so the text can take Classic's game font.
    local x0, y0 = ui.vec2(imgui.GetItemRectMin());
    local _, y1  = ui.vec2(imgui.GetItemRectMax());
    local list   = imgui.GetWindowDrawList();
    local ty     = y0 + (y1 - y0 - imgui.GetTextLineHeight()) / 2;
    ui.draw_text(list, x0 + 4, ty, color, text);
    list:AddText({ x0 + 4 + ui.text_width(text) + 4, ty }, imgui.GetColorU32(color), caret);
    return clicked;
end

--[[
* A row of toggle buttons: equal widths when every label fits its share, otherwise each as wide as
* its label plus an even share of the spare. Too wide for one row, they stack. Returns the index
* clicked, or nil.
--]]
function ui.button_row(id, labels, states, width)
    local gap, total, widths = 8, 0, {};
    for i, label in ipairs(labels) do
        widths[i] = ui.text_width(label) + 12;
        total = total + widths[i] + (i > 1 and gap or 0);
    end
    local clicked = nil;
    local fits    = total <= width;
    local equal   = (width - gap * (#labels - 1)) / #labels;
    local spare   = fits and (width - total) / #labels or 0;
    local even    = true;
    for i = 1, #labels do
        even = even and widths[i] <= equal;
    end
    for i, label in ipairs(labels) do
        if (fits and i > 1) then
            imgui.SameLine(0, gap);
        end
        local w = (not fits and width) or (even and equal) or (widths[i] + spare);
        if (ui.toggle_button(('%s##%s_%d'):fmt(label, id, i), states[i], w)) then
            clicked = i;
        end
    end
    return clicked;
end

-----------------------------------
-- Meter bars
-----------------------------------
--[[
* A meter bar you can click: track, filled share, a label on the left and figures on the right
* drawn over it, with a 1px shadow so coloured names hold up on the fill. `outline` draws a border
* (your own bar). The label is shortened to fit beside the figures. Returns clicked, hovered.
--]]
--[[
* Classic's row: the game never puts a filled bar behind text, so the name and figures sit on the
* window art like a line in one of its lists, with a thin gauge under them, shaded like the HP and
* TP gauges, in the player's job colour. Your own row has a faint light band behind it.
--]]
local function gauge_row(id, width, fill, color, left, right, left_color, mine, right_dim)
    local x, y    = ui.vec2(imgui.GetCursorScreenPos());
    local line    = imgui.GetTextLineHeight();
    local gauge   = math.max(3, math.floor(line * 0.25 + 0.5));
    local height  = line + 2 + gauge;
    local clicked = imgui.InvisibleButton(id, { width, height });
    local hovered = imgui.IsItemHovered();
    local list    = imgui.GetWindowDrawList();

    if (mine or hovered) then
        local band = hovered and { 1, 1, 1, 0.12 } or { 1, 1, 1, 0.07 };
        list:AddRectFilled({ x - 3, y - 1 }, { x + width + 3, y + height + 1 }, imgui.GetColorU32(band), 2);
    end

    -- The gauge: a dark sunken track, the share filled in, lighter along its top edge.
    fill = math.max(0, math.min(1, fill));
    local gy = y + line + 2;
    list:AddRectFilled({ x, gy }, { x + width, gy + gauge }, imgui.GetColorU32({ 0, 0, 0, 0.55 }));
    if (fill > 0) then
        local fx = x + math.max(width * fill, 2);
        local c  = color;
        list:AddRectFilled({ x, gy }, { fx, gy + gauge }, imgui.GetColorU32({ c[1] * 0.80, c[2] * 0.80, c[3] * 0.80, 1 }));
        list:AddRectFilled({ x, gy }, { fx, gy + 1 }, imgui.GetColorU32({
            c[1] + (1 - c[1]) * 0.45, c[2] + (1 - c[2]) * 0.45, c[3] + (1 - c[3]) * 0.45, 1 }));
    end

    local rx = x + width;
    if (right_dim) then
        rx = rx - ui.text_width(right_dim);
        ui.draw_text(list, rx, y, COLOR.peach, right_dim);
        rx = rx - ui.text_width('  ');
    end
    rx = rx - ui.text_width(right);
    ui.draw_text(list, rx, y, COLOR.text, right);
    ui.draw_text(list, x, y, left_color or COLOR.text, ui.fit(left, rx - x - 10));
    return clicked, hovered;
end

function ui.meter_bar(id, width, height, fill, color, left, right, left_color, outline, left_outline, right_dim)
    if (ui.theme.bars == 'gauge') then
        -- The gauge takes the name's colour when it has one (job colours), else the bar colour.
        local gauge_color = (left_color and left_color ~= COLOR.text and left_color ~= COLOR.peach) and left_color or color;
        return gauge_row(id, width, fill, gauge_color, left, right, left_color, outline ~= nil, right_dim);
    end
    local x, y    = ui.vec2(imgui.GetCursorScreenPos());
    local clicked = imgui.InvisibleButton(id, { width, height });
    local hovered = imgui.IsItemHovered();
    local list    = imgui.GetWindowDrawList();
    local round   = ui.theme.bar_rounding;

    fill = math.max(0, math.min(1, fill));
    list:AddRectFilled({ x, y }, { x + width, y + height }, imgui.GetColorU32(COLOR.surface2), round);
    if (fill > 0) then
        list:AddRectFilled({ x, y }, { x + math.max(width * fill, 8), y + height }, imgui.GetColorU32(color), round);
    end
    if (hovered) then
        list:AddRectFilled({ x, y }, { x + width, y + height }, imgui.GetColorU32(COLOR.tint), round);
    end
    if (outline) then
        list:AddRect({ x, y }, { x + width, y + height }, imgui.GetColorU32(outline), round, 0, 1.0);
    end

    -- Figures on the right: the main one, then a dimmer one after it (the share).
    local line = imgui.GetTextLineHeight();
    local ty   = y + (height - line) / 2;
    local rx   = x + width - 6;
    if (right_dim) then
        rx = rx - ui.text_width(right_dim);
        ui.draw_text(list, rx, ty, COLOR.peach, right_dim, nil, true);
        rx = rx - ui.text_width('  ');
    end
    rx = rx - ui.text_width(right);
    ui.draw_text(list, rx, ty, COLOR.text, right, nil, true);
    ui.draw_text(list, x + 6, ty, left_color or COLOR.text, ui.fit(left, rx - x - 6 - 10), left_outline, true);
    return clicked, hovered;
end

-----------------------------------
-- Window
-----------------------------------
-- No title bar: the theme's accent line (or Classic's frame art) marks the window instead.
function ui.window_flags(locked)
    local flags = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse, ImGuiWindowFlags_NoFocusOnAppearing);
    if (locked) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove);
    end
    return flags;
end

local art_off = false;

-- Right after Begin: Classic's window art behind everything, or Phoenix's ember line on top.
function ui.window_art(alpha)
    local theme = ui.theme;
    if (theme.skin ~= nil and not art_off) then
        local ok, problem = pcall(skin.draw, theme.skin, false, alpha);
        if (not ok) then
            art_off = true;
            ui.say(('Classic window art is off for this session: %s'):fmt(tostring(problem)));
        end
    end
    if (theme.accent) then
        local x, y = ui.vec2(imgui.GetWindowPos());
        local w    = ui.vec2(imgui.GetWindowSize());
        imgui.GetWindowDrawList():AddRectFilled({ x + 10, y }, { x + w - 10, y + 2 }, imgui.GetColorU32(COLOR.ember));
    end
end

-- Frees the game art and font (the unload event).
function ui.release()
    pcall(skin.release);
    pcall(gamefont.release);
end

--[[
* Draws one glyph with its ink centred on (cx, cy). Centring the text box instead leaves glyphs
* like '?' or an icon sitting high or low, since the box includes space above and below the ink.
--]]
function ui.glyph_at(list, codepoint, text, cx, cy, color)
    local baked = imgui.GetFontBaked();
    local g     = baked and baked:FindGlyph(codepoint);
    local x, y;
    if (g) then
        x, y = cx - (g.X0 + g.X1) / 2, cy - (g.Y0 + g.Y1) / 2;
    else
        local w = imgui.CalcTextSize(text);
        w = type(w) == 'number' and w or (ui.vec2(w) or 0);
        x, y = cx - w / 2, cy - imgui.GetTextLineHeight() / 2;
    end
    list:AddText({ math.floor(x + 0.5), math.floor(y + 0.5) }, imgui.GetColorU32(color), text);
end

-----------------------------------
-- Tables and sections
-----------------------------------
-- Text right-aligned in the current table cell, for numbers that read down a column.
function ui.cell_right(color, text)
    local avail = ui.vec2(imgui.GetContentRegionAvail());
    imgui.SetCursorPosX(imgui.GetCursorPosX() + math.max(0, avail - ui.text_width(text)));
    ui.text(color, text);
end

-- The width left in the current cell (or line).
function ui.room()
    return ui.vec2(imgui.GetContentRegionAvail()) or 0;
end

-- Left-aligned cell text, shortened with '..' to its column rather than cut off by it.
function ui.cell_text(color, text, outline)
    ui.name_text(color, ui.fit(tostring(text), ui.room()), outline);
end

-- A table's header row: { label, right } per column, numbers' headers right-aligned to match.
function ui.header_row(columns)
    imgui.TableNextRow(ImGuiTableRowFlags_Headers or 0);
    imgui.TableSetBgColor(ImGuiTableBgTarget_RowBg0, imgui.GetColorU32(COLOR.surface2));
    for _, c in ipairs(columns) do
        imgui.TableNextColumn();
        if (c[2]) then
            ui.cell_right(COLOR.text, c[1]);
        else
            ui.text(COLOR.text, c[1]);
        end
    end
end

--[[
* A collapsible section header, drawn here rather than with CollapsingHeader: ImGui widens framed
* headers past the content on both sides, so they'd stick out past the bars and tables. This one
* is exactly `width` wide. A '?' in a ring at its right end shows `help` when hovered. Open state
* is kept per id for the session. Returns whether it's open.
--]]
ui.sections = {};

function ui.section(id, title, help, width, closed)
    local open = ui.sections[id];
    if (open == nil) then
        open = not closed;
    end
    local h      = imgui.GetFrameHeight();
    local x, y   = ui.vec2(imgui.GetCursorScreenPos());
    local line   = imgui.GetTextLineHeight();
    if (imgui.InvisibleButton('##pxp_section_' .. id, { width, h })) then
        open = not open;
    end
    ui.sections[id] = open;
    local hovered = imgui.IsItemHovered();
    local list    = imgui.GetWindowDrawList();
    list:AddRectFilled({ x, y }, { x + width, y + h }, imgui.GetColorU32(hovered and COLOR.tint or COLOR.surface2),
        ui.theme.frame_rounding);

    -- The arrow: a small triangle centred in a square at the left, down when open.
    local cy, s = y + h / 2, math.floor(line * 0.22 + 0.5);
    local cx    = x + 6 + s;
    local color = imgui.GetColorU32(COLOR.secondary);
    if (open) then
        list:AddTriangleFilled({ cx - s, cy - s * 0.6 }, { cx + s, cy - s * 0.6 }, { cx, cy + s * 0.6 }, color);
    else
        list:AddTriangleFilled({ cx - s * 0.6, cy - s }, { cx + s * 0.6, cy }, { cx - s * 0.6, cy + s }, color);
    end
    ui.draw_text(list, cx + s + 8, math.floor(y + (h - line) / 2 + 0.5), COLOR.text, title);

    if (help) then
        -- The ring is sized from the '?' itself, so the glyph always has room inside it.
        local baked = imgui.GetFontBaked();
        local g     = baked and baked:FindGlyph(0x3F);
        local ink   = g and math.max(g.Y1 - g.Y0, g.X1 - g.X0) or line * 0.7;
        local r     = math.min(math.floor(ink / 2 + 3.5), math.floor(h / 2 - 1));
        local qx    = x + width - 6 - r;
        local qc    = hovered and COLOR.peach or COLOR.muted;
        list:AddCircle({ qx, cy }, r, imgui.GetColorU32(qc), 16, 1.0);
        ui.glyph_at(list, 0x3F, '?', qx, cy, qc);
        if (hovered) then
            ui.tooltip(help, COLOR.secondary);
        end
    end
    return open;
end

-- A small filled dot on the current line (the live-fight marker), centred on the text beside it.
function ui.dot(color)
    local x, y   = ui.vec2(imgui.GetCursorScreenPos());
    local line   = imgui.GetTextLineHeight();
    local radius = math.max(2.5, line * 0.18);
    local cy     = y + line / 2;
    if (not game_font('0')) then
        local baked = imgui.GetFontBaked();
        local g     = baked and baked:FindGlyph(0x30); -- '0': centre on the digits
        cy = g and (y + (g.Y0 + g.Y1) / 2) or cy;
    end
    imgui.GetWindowDrawList():AddCircleFilled({ x + radius, cy }, radius, imgui.GetColorU32(color), 12);
    imgui.Dummy({ radius * 2, line });
end

-----------------------------------
-- Theme push
-----------------------------------
-- Returns how many colours and style vars were pushed, for the matching pops.
function ui.push_theme(alpha)
    local theme  = ui.theme;
    local colors = {
        { ImGuiCol_WindowBg,          { COLOR.abyss[1], COLOR.abyss[2], COLOR.abyss[3], alpha } },
        { ImGuiCol_TitleBg,           COLOR.surface1 },
        { ImGuiCol_TitleBgActive,     COLOR.surface2 },
        { ImGuiCol_TitleBgCollapsed,  COLOR.surface1 },
        { ImGuiCol_Border,            COLOR.border   },
        { ImGuiCol_Separator,         COLOR.border   },
        { ImGuiCol_Text,              COLOR.text     },
        { ImGuiCol_TextDisabled,      COLOR.muted    },
        { ImGuiCol_FrameBg,           COLOR.surface2 },
        { ImGuiCol_FrameBgHovered,    COLOR.tint     },
        { ImGuiCol_FrameBgActive,     COLOR.surface2 },
        { ImGuiCol_SliderGrab,        COLOR.royal    },
        { ImGuiCol_SliderGrabActive,  COLOR.hover    },
        { ImGuiCol_PlotHistogram,     COLOR.royal    },
        { ImGuiCol_Header,            COLOR.surface2 },
        { ImGuiCol_HeaderHovered,     COLOR.tint     },
        { ImGuiCol_HeaderActive,      COLOR.royal    },
        { ImGuiCol_TableHeaderBg,     COLOR.surface2 },
        { ImGuiCol_TableBorderLight,  COLOR.subtle   },
        { ImGuiCol_TableBorderStrong, COLOR.border   },
        { ImGuiCol_TableRowBg,        COLOR.clear    },
        { ImGuiCol_TableRowBgAlt,     COLOR.row_alt  },
        { ImGuiCol_PopupBg,           COLOR.surface1 },
        { ImGuiCol_CheckMark,         COLOR.royal    },
        { ImGuiCol_Button,            COLOR.royal    },
        { ImGuiCol_ButtonHovered,     COLOR.hover    },
        { ImGuiCol_ButtonActive,      COLOR.royal    },
        { ImGuiCol_ScrollbarBg,       COLOR.abyss    },
        { ImGuiCol_ScrollbarGrab,     COLOR.surface2 },
        { ImGuiCol_ResizeGrip,        COLOR.clear    },
    };
    for _, color in ipairs(colors) do
        imgui.PushStyleColor(color[1], color[2]);
    end

    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, theme.window_rounding);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, theme.frame_rounding);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, theme.padding);
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 8, 5 });
    imgui.PushStyleVar(ImGuiStyleVar_CellPadding, { 4, 3 });
    -- Set, not left to Ashita's defaults: the theme's window border, no frame borders.
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, theme.window_border);
    imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0.0);
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 4, 3 });

    return #colors, 8;
end

return ui;
