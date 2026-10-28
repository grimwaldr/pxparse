--[[
* pxparse - world
* What the parser needs to know about the game, from Ashita's memory: who's in the party, whose pet
* is whose, names, and action names. Everything is keyed by server id; names are only for display.
--]]

require('common');

local world = {
    partyonly = true,
};

local REFRESH = 1.0;    -- seconds between party reads
local PET_TTL = 2.0;    -- seconds a pet owner is trusted before checking again
local MAX_INDEX = 0x8FF;

local members   = {};   -- [server id] = { index, name }
local index_of  = {};   -- [server id] = entity index (checked before use)
local names     = {};   -- [server id] = name
local pets      = {};   -- [pet server id] = { owner, name, at }
local jobs      = {};   -- [server id] = the last party entry with a job, kept after they leave
local refreshed = -1;

local function entity()
    return AshitaCore:GetMemoryManager():GetEntity();
end

function world.now()
    return os.clock();
end

--[[
* The entity index for a server id, or nil when it isn't nearby. Monsters, pets and NPCs carry
* their index in the low bits of the id; players need a lookup.
--]]
function world.index(id)
    local ent = entity();
    local i   = index_of[id];
    if (i and ent:GetServerId(i) == id) then
        return i;
    end
    if (id >= 0x1000000) then
        i = bit.band(id, 0xFFF);
        if (i <= MAX_INDEX and ent:GetServerId(i) == id) then
            index_of[id] = i;
            return i;
        end
    end
    local m = members[id];
    if (m and m.index ~= 0 and ent:GetServerId(m.index) == id) then
        index_of[id] = m.index;
        return m.index;
    end
    for n = 0, MAX_INDEX do
        if (ent:GetServerId(n) == id) then
            index_of[id] = n;
            return n;
        end
    end
    index_of[id] = nil;
    return nil;
end

-- Your main job, from your player data. Only the main job is shown, so that's all that's read.
local function own_job()
    local ok, job = pcall(function ()
        return AshitaCore:GetMemoryManager():GetPlayer():GetMainJob();
    end);
    return ok and job or nil;
end

local function refresh_party()
    local now = os.clock();
    if (now - refreshed < REFRESH) then
        return;
    end
    refreshed = now;
    members   = {};
    local party = AshitaCore:GetMemoryManager():GetParty();
    for slot = 0, 17 do
        if (party:GetMemberIsActive(slot) ~= 0) then
            local id = party:GetMemberServerId(slot);
            if (id ~= 0) then
                local name = party:GetMemberName(slot);
                members[id] = {
                    index      = party:GetMemberTargetIndex(slot),
                    name       = name,
                    job        = party:GetMemberMainJob(slot),
                };
                -- Your own job comes from your player data, which always has it; the party list
                -- can report 0 for you (while /anon, for one).
                if (slot == 0) then
                    local job = own_job();
                    if (job and job > 0) then
                        members[id].job = job;
                    end
                end
                -- Remembered past the party, so a member who leaves keeps their colour.
                if (members[id].job and members[id].job > 0) then
                    jobs[id] = members[id];
                end
                if (name and name ~= '') then
                    names[id] = name;
                end
            end
        end
    end
end

-- Forget everything cached (zoning changes indexes).
function world.forget()
    index_of  = {};
    pets      = {};
    refreshed = -1;
end

function world.name(id)
    local n = names[id];
    if (n) then
        return n;
    end
    local i = world.index(id);
    if (i) then
        n = entity():GetName(i);
    end
    if (not n or n == '') then
        return ('#%X'):fmt(id);
    end
    -- Monster names stay the same for a server id; players are cached too.
    names[id] = n;
    return n;
end

-- The party member whose pet this is, if any.
local function pet_owner(id)
    local cached = pets[id];
    local now    = os.clock();
    local ent    = entity();
    local index  = world.index(id);
    if (not index) then
        return cached and cached.owner, cached and cached.name;
    end

    -- Fresh answers, including "nobody's pet", which is what most monster ids get.
    if (cached and now - cached.at < PET_TTL) then
        return cached.owner, cached.name;
    end
    -- Still theirs? The same pet id can come back as someone else's after a resummon.
    if (cached and members[cached.owner] and ent:GetPetTargetIndex(members[cached.owner].index) == index) then
        cached.at = now;
        return cached.owner, cached.name;
    end

    for mid, m in pairs(members) do
        if (m.index ~= 0 and ent:GetPetTargetIndex(m.index) == index) then
            local name = ent:GetName(index);
            pets[id] = { owner = mid, name = (name and name ~= '') and name or 'Pet', at = now };
            return mid, pets[id].name;
        end
    end
    pets[id] = { owner = nil, name = nil, at = now };
    return nil;
end

--[[
* Who gets credit for an action by `id`: a party or alliance member, or their pet's owner (with
* the pet's name). With party only off, any other player counts too.
--]]
function world.credit(id)
    if (not id or id == 0) then
        return nil;
    end
    refresh_party();
    if (members[id]) then
        return id;
    end
    if (id >= 0x1000000) then
        return pet_owner(id);
    end
    if (not world.partyonly) then
        return id;
    end
    return nil;
end

--[[
* A party member's job: main job id (1 WAR ... 22 RUN) and the party entry it came from, or nil
* for anyone whose job isn't known (players outside the party).
--]]
function world.job(id)
    refresh_party();
    local m = jobs[id];
    if (not m) then
        return nil;
    end
    return m.job, m;
end

-- What pxparse sees for your job, for /pxp debug.
function world.debug_jobs()
    local party = AshitaCore:GetMemoryManager():GetParty();
    local lines = {};
    lines[#lines + 1] = ('party list: job %s'):fmt(tostring(party:GetMemberMainJob(0)));
    lines[#lines + 1] = ('player data: job %s'):fmt(tostring(own_job()));
    refreshed = -1;
    local id = party:GetMemberServerId(0);
    local used = world.job(id);
    lines[#lines + 1] = ('using: main %s'):fmt(tostring(used));
    return lines;
end

function world.is_enemy(id)
    if (id < 0x1000000) then
        return false;
    end
    local i = world.index(id);
    if (not i) then
        return true;
    end
    -- Spawn flag 0x10 is a monster; anything else (NPCs, other players' pets) isn't fighting us.
    return bit.band(entity():GetSpawnFlags(i), 0x10) ~= 0;
end

local function resource_name(r)
    if (r and r.Name and r.Name[1] and r.Name[1] ~= '') then
        return r.Name[1];
    end
    return nil;
end

--[[
* Action names from the game's own resources:
*   weapon skills (and trust and pet TP moves on the same category): ids under 256 are in the
*     ability table as they are; 256 and up are monster abilities, at id - 256
*   job abilities: 512 higher in the ability table
*   blood pacts and other pet skills: 512 higher in the ability table, like job abilities
*   spells: as they are
* Anything not found is shown with its id, so it can be checked.
--]]
function world.action_name(kind, id)
    local rm = AshitaCore:GetResourceManager();
    local ok, name = pcall(function ()
        if (kind == 'weaponskill' or kind == 'mobskill') then
            if (id < 256) then
                return resource_name(rm:GetAbilityById(id));
            end
            return rm:GetString('monsters.abilities', id - 256);
        elseif (kind == 'ability' or kind == 'petskill') then
            return resource_name(rm:GetAbilityById(id + 512));
        elseif (kind == 'spell') then
            return resource_name(rm:GetSpellById(id));
        end
        return nil;
    end);
    if (ok and type(name) == 'string' and name ~= '') then
        return (name:gsub('%z.*', ''));
    end
    return nil;
end

--[[
* Progress toward the next level ('exp') or merit point ('limit'): points so far and points
* needed, or nil when Ashita can't say. A merit point is 10,000 limit points.
--]]
local MERIT_COST = 10000;
function world.progress(kind)
    local ok, have, need = pcall(function ()
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        if (kind == 'limit') then
            return player:GetLimitPoints(), MERIT_COST;
        end
        return player:GetExpCurrent(), player:GetExpNeeded();
    end);
    if (not ok or not have or not need or need <= 0) then
        return nil;
    end
    return have, need;
end

-- Your level, for the EXP chain window's bracket (never shown: with level sync it says little).
function world.level()
    local ok, level = pcall(function ()
        return AshitaCore:GetMemoryManager():GetPlayer():GetMainJobLevel();
    end);
    return (ok and type(level) == 'number' and level > 0) and level or nil;
end

function world.me()
    local party = AshitaCore:GetMemoryManager():GetParty();
    local id    = party:GetMemberServerId(0);
    local name  = party:GetMemberName(0);
    if (not id or id == 0 or not name or name == '') then
        return nil, nil;
    end
    return id, name;
end

return world;
