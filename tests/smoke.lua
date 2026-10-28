--[[
* Loads the real addon against stubbed Ashita and ImGui, sends it packets and draws every tab.
* Catches typos and nil calls in the parts the core tests can't reach. Not a picture of the UI.
--]]

package.path = 'addons/pxparse/?.lua;tests/?.lua;' .. package.path;

local encode = require('encode');

-- Ashita's globals ------------------------------------------------------------------------------
local handlers = {};
local said     = {};
local queued   = {};

function T(t) return setmetatable(t or {}, { __index = table }); end
string.fmt = string.format;
table.append = function (t, v) t[#t + 1] = v; end

addon = {};
ashita = {
    events = { register = function (name, key, fn) handlers[name] = fn; end },
    tasks  = { once = function (_, fn) fn(); end },
    fs     = { exists = function () return true; end, create_directory = function () end },
};
ICON_FA_GEAR = '*';
ICON_FA_CARET_DOWN = 'v';
setmetatable(_G, { __index = function (_, k)
    if (type(k) == 'string' and k:match('^ImGui')) then
        return 1;
    end
    return nil;
end });

package.preload['common'] = function () return true; end
package.preload['d3d8'] = function () return { get_device = function () return nil; end }; end
string.append = function (a, b) return a .. b; end
package.preload['chat'] = function ()
    local piece = {};
    piece.append = function (self, other) return self; end
    return {
        header  = function (s) said[#said + 1] = s; return '[' .. s .. '] '; end,
        message = function (s) said[#said + 1] = s; return s; end,
        warning = function (s) said[#said + 1] = 'WARN ' .. s; return s; end,
    };
end
local saved = 0;
package.preload['settings'] = function ()
    return {
        load     = function (d) local s = {}; for k, v in pairs(d) do s[k] = v; end LOADED = s; return s; end,
        save     = function () saved = saved + 1; end,
        register = function () end,
    };
end

-- ImGui: every call returns something plausible, and calls are counted.
local calls = {};
local list  = { AddRectFilled = function () end, AddText = function () end, AddRect = function () end,
    AddCircleFilled = function () end, AddCircle = function () end, AddTriangleFilled = function () end };
local imgui = setmetatable({
    Begin            = function () return true; end,
    BeginTable       = function () return true; end,
    BeginCombo       = function () return true; end,
    BeginPopup       = function () return true; end,
    Selectable       = function () return false; end,
    CollapsingHeader = function () return true; end,
    IsItemHovered    = function () return true; end,
    InvisibleButton  = function () return false; end,
    Button           = function () return false; end,
    MenuItem         = function () return false; end,
    BeginPopupContextWindow = function () return true; end,
    SliderFloat      = function () return false; end,
    IsItemDeactivatedAfterEdit = function () return false; end,
    CalcTextSize     = function (s) return { x = #tostring(s) * 7, y = 13 }; end,
    GetCursorScreenPos = function () return { x = 10, y = 10 }; end,
    GetCursorPosY    = function () return 0; end,
    GetWindowPos     = function () return { x = 440, y = 300 }; end,
    GetWindowSize    = function () return { x = 384, y = 300 }; end,
    GetContentRegionAvail = function () return { x = 60, y = 20 }; end,
    GetCursorPosX    = function () return 0; end,
    GetItemRectMin   = function () return 0, 0; end,
    GetItemRectMax   = function () return 20, 20; end,
    GetFontSize      = function () return 13; end,
    GetTextLineHeight = function () return 13; end,
    GetFrameHeight   = function () return 19; end,
    GetTextLineHeightWithSpacing = function () return 18; end,
    GetFont          = function () return {}; end,
    GetFontBaked     = function () return { FindGlyph = function () return { X0 = 0, X1 = 8, Y0 = 0, Y1 = 8 }; end }; end,
    GetWindowDrawList = function () return list; end,
    GetColorU32      = function () return 0; end,
}, { __index = function (_, k)
    return function () calls[k] = (calls[k] or 0) + 1; end;
end });
package.preload['imgui'] = function () return imgui; end

-- Ashita memory: me (Grimwald) and Alme in the party, my pet, two mobs.
local GRIM, ALME, PET, CRAB = 0x00100001, 0x00100002, 0x01000701, 0x01001234;
local ENT = {
    [0x401] = { id = GRIM, name = 'Grimwald', pet = 0x701, flags = 0x0D },
    [0x402] = { id = ALME, name = 'Alme', pet = 0, flags = 0x0D },
    [0x701] = { id = PET, name = 'Carbuncle', pet = 0, flags = 0x102 },
    [0x234] = { id = CRAB, name = 'Snipper', pet = 0, flags = 0x10 },
};
local entity = {
    GetServerId       = function (_, i) return ENT[i] and ENT[i].id or 0; end,
    GetName           = function (_, i) return ENT[i] and ENT[i].name or ''; end,
    GetPetTargetIndex = function (_, i) return ENT[i] and ENT[i].pet or 0; end,
    GetSpawnFlags     = function (_, i) return ENT[i] and ENT[i].flags or 0; end,
};
local SLOTS = { [0] = 0x401, [1] = 0x402 };
local party = {
    GetMemberIsActive    = function (_, s) return SLOTS[s] and 1 or 0; end,
    GetMemberServerId    = function (_, s) return SLOTS[s] and ENT[SLOTS[s]].id or 0; end,
    GetMemberName        = function (_, s) return SLOTS[s] and ENT[SLOTS[s]].name or ''; end,
    GetMemberTargetIndex = function (_, s) return SLOTS[s] or 0; end,
    -- The party list says 0 for you (as while /anon); your player data has the real job.
    GetMemberMainJob      = function (_, s) return ({ [0] = 0, [1] = 4 })[s] or 0; end,
    GetMemberMainJobLevel = function (_, s) return ({ [0] = 0, [1] = 29 })[s] or 0; end,
    GetMemberSubJob       = function (_, s) return 0; end,
    GetMemberSubJobLevel  = function (_, s) return 0; end,
};
local resources = {
    GetAbilityById = function (_, id) return { Name = { ({ [40] = 'Savage Blade', [578] = 'Jump' })[id] or '' } }; end,
    GetSpellById   = function (_, id) return { Name = { ({ [147] = 'Fire III' })[id] or '' } }; end,
    GetString      = function () return nil; end,
};
AshitaCore = {
    GetMemoryManager   = function () return {
        GetEntity = function () return entity; end,
        GetParty  = function () return party; end,
        GetPlayer = function () return {
            GetMainJob = function () return 17; end, GetMainJobLevel = function () return 30; end,
            GetSubJob  = function () return 13; end, GetSubJobLevel  = function () return 15; end,
            GetExpCurrent = function () return 1200; end, GetExpNeeded = function () return 3200; end,
            GetLimitPoints = function () return 0; end,
        }; end,
    }; end,
    GetResourceManager = function () return resources; end,
    GetChatManager     = function () return { QueueCommand = function (_, _, c) queued[#queued + 1] = c; end }; end,
    GetInstallPath     = function () return '.'; end,
};

-- Load the addon -------------------------------------------------------------------------------
local real_open = io.open;
io.open = function (path, mode)
    if (mode == 'w') then
        return { write = function () end, close = function () end };
    end
    return real_open(path, mode);
end

dofile('addons/pxparse/pxparse.lua');
assert(handlers.packet_in and handlers.d3d_present and handlers.command, 'events not registered');

local function packet(action, chunk_start)
    local data = encode.action(action);
    -- Make the chunk start with this packet when asked, to drive the duplicate check.
    handlers.packet_in({ id = 0x028, size = #data, data = data, chunk_data = chunk_start and data or ('x'):rep(#data), injected = false });
end

local function cmd(text)
    local args = {};
    for word in text:gmatch('%S+') do
        args[#args + 1] = word;
    end
    local e = { command = { args = function () return args; end }, blocked = false };
    e.command = setmetatable({}, { __index = { args = function () return args; end } });
    handlers.command(e);
    return e.blocked;
end

local hit = { actor = GRIM, category = 1, targets = { { id = CRAB, results = { { param = 120, message = 1 } } } } };
packet(hit, true);
packet(hit, false);   -- same chunk, same bytes: a second real hit
packet(hit, true);    -- new chunk repeating the last one's bytes: a duplicate
packet({ actor = GRIM, category = 3, id = 40, targets = { { id = CRAB, results = {
    { kind = 3, param = 900, message = 185, proc = { kind = 6, param = 300, message = 293 } } } } } }, true);
packet({ actor = PET, category = 13, id = 831, targets = { { id = CRAB, results = { { param = 250, message = 317 } } } } }, true);
packet({ actor = ALME, category = 4, id = 147, targets = { { id = CRAB, results = { { param = 700, message = 252 } } } } }, true);
packet({ actor = CRAB, category = 1, targets = { { id = GRIM, results = {
    { param = 50, message = 1, react = { kind = 5, param = 22, message = 44 } } } } } }, true);
packet({ actor = GRIM, category = 1, targets = { { id = CRAB, results = { { param = 0, message = 700 } } } } }, true);

local view = require('view');
for _, expanded in ipairs({ false, true }) do
    view.expanded = expanded;
    for _, tab in ipairs({ 'damage', 'detail', 'log', 'settings' }) do
        LOADED.tab = tab;
        handlers.d3d_present();
        handlers.d3d_present();
    end
end

assert(cmd('/pxp report'), 'command not blocked');
assert(cmd('/pxp report p 2'));
assert(cmd('/pxp sc bar'));
handlers.d3d_present();
assert(cmd('/pxp sc'));
assert(cmd('/pxp sc shared'));
assert(LOADED.sc == 'shared', 'sc shared not set');
for _, tab in ipairs({ 'damage', 'detail', 'log', 'settings' }) do
    LOADED.tab = tab;
    handlers.d3d_present();
end
assert(cmd('/pxp jobs'));
assert(LOADED.jobcolors == false, 'jobs toggle');
handlers.d3d_present();
assert(cmd('/pxp jobs'));
local world = require('world');
assert(world.job(GRIM) == 17, 'your job should come from player data (COR)');
assert(world.job(ALME) == 4, 'party members still come from the party list');
assert(cmd('/pxp debug'));
assert(world.job(0x01001234) == nil, 'mob has no job');
assert(cmd('/pxp party'));
assert(cmd('/pxp party'));
assert(cmd('/pxp scale 1.5'));
assert(cmd('/pxp export'));
assert(cmd('/pxp nonsense'));
assert(not cmd('/somethingelse'), 'other commands must pass through');

-- What the report said: the duplicate must not be in the total.
local report = table.concat(queued, '\n');
print(report);
assert(report:find('/p pxparse: Current fight'), 'report title missing');
assert(report:find('Grimwald 1,712'), 'Grimwald total wrong (duplicate counted, or pet/sc missing)');
assert(report:find('Alme 700'), 'Alme total wrong');
assert(#queued == 3, 'report p 2 should send 3 lines');
-- Experience (0x02D) for me shows the Experience section; someone else's is ignored.
local function points_packet(actor, amount, msg)
    local bytes = {};
    for i = 1, 0x1C do bytes[i] = 0; end
    local function put32(off, v) for k = 0, 3 do bytes[off + k + 1] = math.floor(v / 256 ^ k) % 256; end end
    put32(0x04, actor); put32(0x10, amount);
    bytes[0x18 + 1] = msg % 256; bytes[0x19 + 1] = math.floor(msg / 256);
    local chars = {};
    for i = 1, #bytes do chars[i] = string.char(bytes[i]); end
    return table.concat(chars);
end
local xp_mine  = points_packet(GRIM, 150, 8);
local xp_other = points_packet(ALME, 999, 8);
handlers.packet_in({ id = 0x02D, size = #xp_mine, data = xp_mine, chunk_data = xp_mine, injected = false });
handlers.packet_in({ id = 0x02D, size = #xp_other, data = xp_other, chunk_data = xp_other, injected = false });
LOADED.tab = 'damage';
handlers.d3d_present();

-- A kill (0x029), then zoning ends the fight: it becomes the last fight, named after the mob.
local function message_packet(actor, target, msg)
    local bytes = {};
    for i = 1, 0x1C do bytes[i] = 0; end
    local function put32(off, v) for k = 0, 3 do bytes[off + k + 1] = math.floor(v / 256 ^ k) % 256; end end
    put32(0x04, actor); put32(0x08, target);
    bytes[0x18 + 1] = msg % 256; bytes[0x19 + 1] = math.floor(msg / 256);
    local chars = {};
    for i = 1, #bytes do chars[i] = string.char(bytes[i]); end
    return table.concat(chars);
end
local kill = message_packet(GRIM, CRAB, 6);
handlers.packet_in({ id = 0x029, size = #kill, data = kill, chunk_data = kill, injected = false });
handlers.packet_in({ id = 0x00A, size = 4, data = 'zone', injected = false });

local view = require('view');
for _, fight in ipairs({ 'current', 'overall' }) do
    for _, filter in ipairs({ 'All mobs', 'id:' .. CRAB, 'name:Snipper' }) do
        for _, tab in ipairs({ 'damage', 'detail', 'log' }) do
            view.fight, view.filter, LOADED.tab = fight, filter, tab;
            handlers.d3d_present();
        end
    end
end
view.fight, view.filter = 'current', 'All mobs';
for i = #queued, 1, -1 do queued[i] = nil; end
assert(cmd('/pxp report p 2'));
local last = table.concat(queued, '\n');
print(last);
assert(last:find('pxparse: Snipper, '), 'the last fight should be named after its mob (one Snipper: no id needed)');
assert(cmd('/pxp ids'));
assert(LOADED.showids == true, 'ids not set');
for _, tab in ipairs({ 'damage', 'detail', 'log', 'settings' }) do
    LOADED.tab = tab;
    handlers.d3d_present();
end
for i = #queued, 1, -1 do queued[i] = nil; end
assert(cmd('/pxp report p 2'));
assert(table.concat(queued, '\n'):find('pxparse: Snipper %[234%]'), 'Mob IDs on should add the id');
assert(cmd('/pxp ids'));

-- Hidden names: the report and every tab use jobs, never names.
for i = #queued, 1, -1 do queued[i] = nil; end
assert(cmd('/pxp mask'));
assert(LOADED.masknames == true, 'mask not set');
for _, tab in ipairs({ 'damage', 'detail', 'log', 'settings' }) do
    LOADED.tab = tab;
    handlers.d3d_present();
end
assert(cmd('/pxp report p 2'));
local masked = table.concat(queued, '\n');
print(masked);
assert(masked:find('1. COR '), 'masked report should name your job');
assert(masked:find('2. BLM '), 'masked report should name the job');
assert(not masked:find('Grimwald') and not masked:find('Alme'), 'a real name leaked into the masked report');
assert(cmd('/pxp mask'));
assert(cmd('/pxp reset'));
-- Every theme draws every tab, open and closed. Classic can't read game files here, so it takes its
-- fallbacks: plain colours for the art, the ringed normal font for text.
for _, theme in ipairs({ 'phoenix', 'classic', 'default' }) do
    assert(cmd('/pxp theme ' .. theme));
    assert(LOADED.theme == theme, 'theme not set: ' .. theme);
    for _, expanded in ipairs({ false, true }) do
        view.expanded = expanded;
        for _, tab in ipairs({ 'damage', 'detail', 'log', 'settings' }) do
            LOADED.tab = tab;
            handlers.d3d_present();
        end
    end
end
assert(cmd('/pxp theme'), 'theme cycle');
assert(LOADED.theme == 'phoenix', 'theme cycles back to phoenix');
assert(cmd('/pxp wintype 3') and LOADED.wintype == 2, 'wintype 3');
assert(cmd('/pxp wintype game') and LOADED.wintype == -1, 'wintype game');
-- The game font is per theme: on for Classic only, until turned on elsewhere.
assert(LOADED.gamefont.classic == true and LOADED.gamefont.phoenix == false, 'game font defaults');
assert(cmd('/pxp font') and LOADED.gamefont.phoenix == true, 'font on for phoenix');
assert(LOADED.gamefont.classic == true, 'classic untouched');
handlers.d3d_present(); -- phoenix with the game font asked for: falls back to the normal font here
assert(cmd('/pxp theme classic') and cmd('/pxp font') and LOADED.gamefont.classic == false, 'font off for classic');
assert(LOADED.gamefont.phoenix == true, 'phoenix untouched');
-- Settings saved before it was per theme held one on/off for Classic.
LOADED.gamefont = false;
handlers.d3d_present();
assert(type(LOADED.gamefont) == 'table' and LOADED.gamefont.classic == false and LOADED.gamefont.phoenix == false, 'old setting moved over');
assert(cmd('/pxp theme phoenix'));
assert(cmd('/pxp theme nope'), 'bad theme still blocked');
assert(LOADED.theme == 'phoenix', 'bad theme ignored');
handlers.unload();

-- The footer doesn't shift as its figures tick over, even where digits differ in width (a '1' is
-- narrower than an '8' in the game font): each item keeps the widest slot it has needed.
do
    local ui = require('ui');
    local real_calc, real_same = imgui.CalcTextSize, imgui.SameLine;
    imgui.CalcTextSize = function (s) local w = 0; for c in tostring(s):gmatch('.') do w = w + (c == '1' and 3 or 7); end return { x = w, y = 13 }; end
    local starts = {};
    for _, rate in ipairs({ '8,101', '8,111', '8,188', '8,111', '8,101' }) do
        local offsets = {};
        imgui.SameLine = function (x) offsets[#offsets + 1] = x; end
        ui.spread('test', {
            { rate .. ' exp/hr', { 1, 1, 1, 1 }, 1 }, { 'Chain #1 1:53', { 1, 1, 1, 1 }, 1 }, { '3m 00s to lvl', { 1, 1, 1, 1 }, 2 }, { '206 exp', { 1, 1, 1, 1 }, 3 },
        }, 360);
        starts[#starts + 1] = offsets;
    end
    imgui.CalcTextSize, imgui.SameLine = real_calc, real_same;
    -- After the widest rate ('8,188'), nothing to its right moves back.
    for i = 4, 5 do
        for k = 1, #starts[3] do
            assert(starts[i][k] == starts[3][k], ('footer item %d moved: %s then %s'):format(k + 1, starts[3][k], starts[i][k]));
        end
    end
end

print(('smoke ok: %d stubbed imgui calls, %d settings saves'):format((function () local n = 0; for _, c in pairs(calls) do n = n + c; end return n; end)(), saved));
return 0;
