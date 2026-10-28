--[[
* A party of four and a fight, for tests/preview.py: loads the real addon against stubbed Ashita
* (ImGui is real, bridged in by preview.py as PREVIEW_IMGUI), feeds it packets the way the server
* would, and hands back a draw function. Time is faked so the fight has a realistic length.
--]]

package.path = 'addons/pxparse/?.lua;tests/?.lua;' .. package.path;

local encode = require('encode');

-- Fake clock -------------------------------------------------------------------------------------
local clock = 1000.0;
os.clock = function () return clock; end
local function advance(seconds) clock = clock + seconds; end

-- Ashita's globals ------------------------------------------------------------------------------
local handlers = {};
function T(t) return setmetatable(t or {}, { __index = table }); end
string.fmt = string.format;
addon = {};
ashita = {
    events = { register = function (name, key, fn) handlers[name] = fn; end },
    tasks  = { once = function (_, fn) fn(); end },
    fs     = { exists = function () return true; end, create_directory = function () end },
};
for k, v in pairs(PREVIEW_ICONS) do
    _G[k] = v;
end
setmetatable(_G, { __index = function (_, k)
    if (type(k) == 'string' and k:match('^ImGui')) then
        return PREVIEW_CONST(k);
    end
    return nil;
end });

package.preload['common'] = function () return true; end
package.preload['d3d8'] = function () return { get_device = function () return nil; end }; end
string.append = function (a, b) return a .. b; end
package.preload['chat'] = function ()
    local piece = {};
    piece.append = function (self) return self; end
    return {
        header  = function (s) return '[' .. s .. '] '; end,
        message = function (s) return s; end,
        warning = function (s) return s; end,
    };
end
package.preload['settings'] = function ()
    return {
        load     = function (d) local s = {}; for k, v in pairs(d) do s[k] = v; end SETTINGS = s; return s; end,
        save     = function () end,
        register = function () end,
    };
end
package.preload['imgui'] = function () return PREVIEW_IMGUI; end

-- The party: me (COR), a WAR, a BLM and a SMN with Carbuncle. Two Goblin Ambushers and a beetle.
local GRIM, VELL, KOPA, DRAV = 0x00100001, 0x00100002, 0x00100003, 0x00100004;
local CARB = 0x01000705;
local GOB1, GOB2, BEET = 0x010011A3, 0x010011C0, 0x01001234;
local ENT = {
    [0x401] = { id = GRIM, name = 'Grimwald', pet = 0, flags = 0x0D },
    [0x402] = { id = VELL, name = 'Velloria', pet = 0, flags = 0x0D },
    [0x403] = { id = KOPA, name = 'Kopaku', pet = 0, flags = 0x0D },
    [0x404] = { id = DRAV, name = 'Dravos', pet = 0x705, flags = 0x0D },
    [0x705] = { id = CARB, name = 'Carbuncle', pet = 0, flags = 0x102 },
    [0x1A3] = { id = GOB1, name = 'Goblin Ambusher', pet = 0, flags = 0x10 },
    [0x1C0] = { id = GOB2, name = 'Goblin Ambusher', pet = 0, flags = 0x10 },
    [0x234] = { id = BEET, name = 'Snipper', pet = 0, flags = 0x10 },
};
local entity = {
    GetServerId       = function (_, i) return ENT[i] and ENT[i].id or 0; end,
    GetName           = function (_, i) return ENT[i] and ENT[i].name or ''; end,
    GetPetTargetIndex = function (_, i) return ENT[i] and ENT[i].pet or 0; end,
    GetSpawnFlags     = function (_, i) return ENT[i] and ENT[i].flags or 0; end,
};
-- The longest names FFXI allows (15 letters), for checking nothing runs together.
if (PREVIEW_LONG) then
    ENT[0x402].name, ENT[0x403].name, ENT[0x404].name = 'Powercontroller', 'Jimmayusmaximus', 'Vinsanethegreat';
end
local SLOTS = { [0] = 0x401, [1] = 0x402, [2] = 0x403, [3] = 0x404 };
local JOBS  = { [0] = 17, [1] = 1, [2] = 4, [3] = 15 };
local party = {
    GetMemberIsActive    = function (_, s) return SLOTS[s] and 1 or 0; end,
    GetMemberServerId    = function (_, s) return SLOTS[s] and ENT[SLOTS[s]].id or 0; end,
    GetMemberName        = function (_, s) return SLOTS[s] and ENT[SLOTS[s]].name or ''; end,
    GetMemberTargetIndex = function (_, s) return SLOTS[s] or 0; end,
    GetMemberMainJob     = function (_, s) return JOBS[s] or 0; end,
};
local NAMES = { [32] = 'Savage Blade', [24] = 'Fast Blade', [134] = 'Fire Shot', [831] = 'Poison Nails' };
local resources = {
    GetAbilityById = function (_, id) return { Name = { NAMES[id] or '' } }; end,
    GetSpellById   = function (_, id) return { Name = { ({ [147] = 'Fire III', [146] = 'Fire II' })[id] or '' } }; end,
    GetString      = function () return nil; end,
};
AshitaCore = {
    GetMemoryManager   = function () return {
        GetEntity = function () return entity; end,
        GetParty  = function () return party; end,
        GetPlayer = function () return {
            GetMainJob = function () return 17; end,
            GetExpCurrent = function () return 6180; end, GetExpNeeded = function () return 10800; end,
            GetLimitPoints = function () return 0; end,
        }; end,
    }; end,
    GetResourceManager = function () return resources; end,
    GetChatManager     = function () return { QueueCommand = function () end }; end,
    GetInstallPath     = function () return '.'; end,
};

local real_open = io.open;
io.open = function (path, mode)
    if (mode == 'w') then
        return { write = function () end, close = function () end };
    end
    return real_open(path, mode);
end

dofile('addons/pxparse/pxparse.lua');
SETTINGS.x, SETTINGS.y = 16, 16;

-- Packets ----------------------------------------------------------------------------------------
local serial = 0;
local function send(id, data)
    serial = serial + 1;
    handlers.packet_in({ id = id, size = #data, data = data, chunk_data = tostring(serial), injected = false });
end
local function action(a) send(0x028, encode.action(a)); end

local function small_packet(fields)
    local bytes = {};
    for i = 1, 0x1C do bytes[i] = 0; end
    for off, v in pairs(fields) do
        local size = off == 0x18 and 2 or 4;
        for k = 0, size - 1 do bytes[off + k + 1] = math.floor(v / 256 ^ k) % 256; end
    end
    local chars = {};
    for i = 1, #bytes do chars[i] = string.char(bytes[i]); end
    return table.concat(chars);
end
local function kill(actor, target) send(0x029, small_packet({ [0x04] = actor, [0x08] = target, [0x18] = 6 })); end
-- Points for me: plain (message 8), or "EXP chain #n" (253) when `chain` is given.
local function exp(amount, chain)
    send(0x02D, small_packet({ [0x04] = GRIM, [0x10] = amount, [0x14] = chain or 0, [0x18] = chain and 253 or 8 }));
end

-- A melee round: { damage or false (miss) or 'crit:N' }.
local function round(actor, target, swings)
    local results = {};
    for _, s in ipairs(swings) do
        if (s == false) then
            results[#results + 1] = { message = 15, param = 0 };
        elseif (type(s) == 'string') then
            results[#results + 1] = { message = 67, param = tonumber(s:match('%d+')), info = 2 };
        else
            results[#results + 1] = { message = 1, param = s };
        end
    end
    action({ actor = actor, category = 1, targets = { { id = target, results = results } } });
end
local function ranged(actor, target, dmg)
    action({ actor = actor, category = 2, targets = { { id = target, results = {
        dmg and { message = 352, param = dmg } or { message = 354, param = 0 } } } } });
end
local function ws(actor, target, id, dmg, chain)
    local r = { message = 185, param = dmg, kind = 3 };
    if (chain) then
        r.proc = { kind = chain.kind, param = chain.dmg, message = 287 + chain.kind };
    end
    action({ actor = actor, category = 3, id = id, targets = { { id = target, results = { r } } } });
end
local function spell(actor, target, id, dmg, burst)
    action({ actor = actor, category = 4, id = id, targets = { { id = target, results = {
        { message = burst and 252 or 2, param = dmg } } } } });
end
local function pact(target, dmg)
    action({ actor = CARB, category = 13, id = 831, targets = { { id = target, results = { { message = 317, param = dmg } } } } });
end
local function hit_me(mob, target, dmg)
    action({ actor = mob, category = 1, targets = { { id = target, results = { { message = 1, param = dmg } } } } });
end

-- An earlier pull (Snipper), finished: it shows in the fight list.
for i = 1, 8 do
    round(GRIM, BEET, { 48, i % 3 == 0 and false or 52 });
    round(VELL, BEET, { 61, 58 });
    advance(3);
end
kill(VELL, BEET);
exp(180);
advance(20);
PREVIEW_TICK = function () handlers.d3d_present(); end
handlers.d3d_present();

-- The pull on screen: two Goblin Ambushers, about three minutes.
local mobs = { GOB1, GOB2 };
for i = 1, 60 do
    local mob = mobs[(i > 34) and 2 or 1];
    round(GRIM, mob, { 54, i % 4 == 0 and false or 49, i % 9 == 0 and 'crit:96' or 51 });
    round(VELL, mob, { 66, i % 5 == 0 and false or 63, i % 7 == 0 and 'crit:121' or 60 });
    if (i % 2 == 0) then ranged(GRIM, mob, i % 5 == 0 and false or 61); end
    if (i % 6 == 0) then spell(KOPA, mob, 147, 298, i % 12 == 0); end
    if (i % 3 == 0) then round(CARB, mob, { 31, 29 }); end
    if (i % 10 == 0) then pact(mob, 188); end
    if (i % 4 == 0) then hit_me(mob, i % 8 == 0 and VELL or GRIM, 22); end
    if (i % 11 == 0) then ws(VELL, mob, 32, 402); ws(GRIM, mob, 24, 233, { kind = 12, dmg = 180 }); end
    if (i == 34) then kill(VELL, GOB1); exp(254, 1); end
    advance(3);
end

local view = require('view');
PREVIEW = { view = view, settings = SETTINGS, advance = advance, kill = function () kill(GRIM, GOB2); exp(276, 2); end };
