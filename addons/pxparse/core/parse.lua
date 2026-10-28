--[[
* pxparse - parse
* Adds decoded actions up. Plain Lua: everything it needs from the game comes through `world`,
* so the tests can drive it with made-up entities.
*
*   world.credit(id)            -> the party member's server id that gets credit for `id` and,
*                                  when `id` is their pet, the pet's name; nil if nobody we count
*   world.is_enemy(id)          -> true for a monster
*   world.name(id)              -> display name
*   world.action_name(kind, id) -> 'weaponskill', 'ability', 'spell', 'mobskill' or 'petskill' name
*   world.now()                 -> seconds
*
* Storage: players[server id].buckets[mob server id] = everything that player did to that mob
* (and took from it). Views add the buckets up when they're drawn: all of them, every mob with one
* name, or a single mob. Each mob has a label with the last three hex digits of its id, which is
* its entity index in the zone: "Goblin Ambusher [1A3]". The label is only shown when two mobs
* share a name (or always, with options.show_ids); otherwise the plain name is enough.
*
* Filters: parse.ALL_MOBS, 'name:<mob name>' (or just the name), or 'id:<mob server id>'.
--]]

local classify = require('core.classify');

local C        = classify.CATEGORY;
local ANIM     = classify.ANIM;
local ACC_HIT  = classify.ACC_HIT;
local ACC_MISS = classify.ACC_MISS;

local parse = {};
parse.__index = parse;

parse.ALL_MOBS     = 'All mobs';
parse.CHAIN_WINDOW = 10; -- seconds a weapon skill stays open for a skillchain
parse.ACTIVE_FLOOR = 3;  -- seconds of activity an action counts for when it starts a stretch
parse.KILL_WINDOW  = 30; -- a mob that dies this long after the party last touched it counts as a kill
parse.ROUND_CAP    = 8;  -- results in a full attack round packet; a full one may have been cut short

-- Messages (0x029) that mean a mob died: "defeats" (with a killer) and "falls to the ground".
local DEFEAT = { [6] = true, [20] = true };

-- Messages that are known not to be attacks, so they aren't reported as unrecognised.
local NOT_ATTACKS = {};
for _, m in ipairs({ 0, 75, 100, 101, 103, 114, 186, 189, 224, 225, 226, 230, 236, 237, 238,
                     242, 243, 266, 267, 319, 320, 323, 362, 370, 378 }) do
    NOT_ATTACKS[m] = true;
end
-- Categories whose every message should be known; spells and abilities have too many effects.
local WATCHED = { [C.MELEE] = true, [C.RANGED] = true, [C.SKILL] = true, [C.MOBSKILL] = true, [C.PETSKILL] = true };

-----------------------------------
-- Construction
-----------------------------------
function parse.new(world, options)
    options = options or {};
    local p = setmetatable({
        world    = world,
        options  = options,  -- shared with the other fights, so settings reach them all
        idle     = options.idle or 6,
        log_size = options.log_size or 200,
        version  = 0,
    }, parse);
    p:reset();
    return p;
end

function parse:reset()
    self.players  = {};   -- [server id] = player
    self.mobs     = {};   -- [mob server id] = { id, name, label, kills }
    self.name_count = {}; -- [mob name] = how many mobs have it
    self.engaged  = {};   -- [mob server id] = when the party last touched it
    self.kills    = 0;
    self.chains   = {};   -- [mob server id] = { opener = server id, at = seconds }
    self.names    = {};   -- action name cache
    self.unknown  = {};   -- ['category:message'] = count, for messages not recognised yet
    self.active   = 0;    -- seconds of fighting (gaps over `idle` don't count)
    self.last     = nil;
    self.log      = {};
    self.log_head = 0;
    self.version  = self.version + 1;
end

local function new_acc()
    return { attempts = 0, hits = 0, misses = 0, crits = 0 };
end

local function new_bucket(mob)
    return {
        mob          = mob,  -- the mob's name, for name filters
        sources      = {},   -- [key] = stat
        melee        = new_acc(),
        ranged       = new_acc(),
        rounds       = 0,    -- melee attack rounds
        round_swings = 0,    -- swings across those rounds (multi-attacks)
        taken        = 0,
        kills        = 0,
        sc_closed    = 0,
        sc_opened    = 0,
        sc_share     = 0,    -- skillchain damage split between the two weapon skills that made it
    };
end

function parse:player(id)
    local pl = self.players[id];
    if (not pl) then
        pl = { id = id, name = self.world.name(id), buckets = {}, active = 0, last = nil };
        self.players[id] = pl;
    end
    return pl;
end

-- "Goblin Ambusher [1A3]": the last three hex digits of the id are the mob's index in the zone.
function parse.label(name, id)
    return ('%s [%03X]'):format(name, id % 0x1000);
end

-- The mob's entry, made on first sight. Returns it.
function parse:note_mob(id)
    local m = self.mobs[id];
    if (not m) then
        local name = self.world.name(id);
        m = { id = id, name = name, label = parse.label(name, id), kills = 0 };
        self.mobs[id] = m;
        self.name_count[name] = (self.name_count[name] or 0) + 1;
    end
    return m;
end

function parse:bucket(pl, mob)
    local b = pl.buckets[mob.id];
    if (not b) then
        b = new_bucket(mob.name);
        pl.buckets[mob.id] = b;
    end
    return b;
end

-- How a mob is shown: its plain name, or with its hex id when another mob has the same name
-- (or when options.show_ids asks for it always).
function parse:mob_display(id)
    local m = self.mobs[id];
    if (not m) then
        return '?';
    end
    if (self.options.show_ids or (self.name_count[m.name] or 0) > 1) then
        return m.label;
    end
    return m.name;
end

-- Whether a filter takes the bucket for mob `id`.
function parse.matches(filter, id, b)
    if (not filter or filter == parse.ALL_MOBS) then
        return true;
    end
    local kind, value = filter:match('^(%a+):(.*)$');
    if (kind == 'id') then
        return tonumber(value) == id;
    end
    return b.mob == (kind == 'name' and value or filter);
end

-- What a filter is called on screen and in reports.
function parse:filter_label(filter)
    if (not filter or filter == parse.ALL_MOBS) then
        return parse.ALL_MOBS;
    end
    local kind, value = filter:match('^(%a+):(.*)$');
    if (kind == 'id') then
        return self:mob_display(tonumber(value));
    end
    return kind == 'name' and value or filter;
end

-- Whether a filter still points at something (after a reset, it may not).
function parse:filter_valid(filter)
    if (not filter or filter == parse.ALL_MOBS) then
        return true;
    end
    local kind, value = filter:match('^(%a+):(.*)$');
    if (kind == 'id') then
        return self.mobs[tonumber(value)] ~= nil;
    end
    local name = kind == 'name' and value or filter;
    for _, m in pairs(self.mobs) do
        if (m.name == name) then
            return true;
        end
    end
    return false;
end

--[[
* The mob filter's choices, sorted by name: one entry per mob, and when several mobs share a name,
* an "(all)" entry for them first. Each is { filter, label, indent }.
--]]
function parse:mob_choices()
    local by_name, names = {}, {};
    for _, m in pairs(self.mobs) do
        if (not by_name[m.name]) then
            by_name[m.name] = {};
            names[#names + 1] = m.name;
        end
        table.insert(by_name[m.name], m);
    end
    table.sort(names);
    local out = { { filter = parse.ALL_MOBS, label = parse.ALL_MOBS } };
    for _, name in ipairs(names) do
        local list = by_name[name];
        table.sort(list, function (a, b) return a.id < b.id; end);
        if (#list > 1) then
            out[#out + 1] = { filter = 'name:' .. name, label = ('%s (all %d)'):format(name, #list) };
        end
        for _, m in ipairs(list) do
            local label = self:mob_display(m.id);
            if (m.kills > 1) then
                label = ('%s x%d'):format(label, m.kills);
            end
            out[#out + 1] = { filter = 'id:' .. m.id, label = label, indent = #list > 1 };
        end
    end
    return out;
end

local function stat(b, key, name, kind)
    local s = b.sources[key];
    if (not s) then
        s = { key = key, name = name, kind = kind, total = 0, count = 0, attempts = 0, hits = 0,
              misses = 0, crits = 0, bursts = 0, max = 0, min = nil };
        b.sources[key] = s;
    end
    return s;
end

-- One outcome into a source: damage, how many landed, accuracy.
local function record(s, outcome, dmg)
    if (outcome == 'dodged' or outcome == 'deflected') then
        return;
    end
    s.attempts = s.attempts + 1;
    if (outcome == 'hit' or outcome == 'crit') then
        s.count = s.count + 1;
        s.total = s.total + dmg;
        if (dmg > s.max) then
            s.max = dmg;
        end
        if (not s.min or dmg < s.min) then
            s.min = dmg;
        end
        if (outcome == 'crit') then
            s.crits = s.crits + 1;
        end
    end
    if (ACC_HIT[outcome]) then
        s.hits = s.hits + 1;
    elseif (ACC_MISS[outcome] or outcome == 'resist') then
        s.misses = s.misses + 1;
    end
end

local function record_acc(acc, outcome)
    if (ACC_HIT[outcome]) then
        acc.attempts = acc.attempts + 1;
        acc.hits     = acc.hits + 1;
        if (outcome == 'crit') then
            acc.crits = acc.crits + 1;
        end
    elseif (ACC_MISS[outcome]) then
        acc.attempts = acc.attempts + 1;
        acc.misses   = acc.misses + 1;
    end
end

-- Active time: gaps up to `idle` count in full; the first action, and one after a longer break,
-- counts for ACTIVE_FLOOR seconds (about one attack round), so a short fight is never 0 seconds.
function parse:mark(now)
    local gap = self.last and (now - self.last) or nil;
    if (gap and gap <= self.idle) then
        self.active = self.active + math.max(0, gap);
    else
        self.active = self.active + parse.ACTIVE_FLOOR;
    end
    self.last    = now;
    self.version = self.version + 1;
end

-- A player's own active time: gaps up to `idle` count in full; an action after a longer break
-- counts for ACTIVE_FLOOR seconds (about one attack round).
function parse:mark_player(pl, now)
    if (pl.last and now - pl.last <= self.idle) then
        pl.active = pl.active + (now - pl.last);
    else
        pl.active = pl.active + parse.ACTIVE_FLOOR;
    end
    pl.last = now;
end

function parse:add_log(now, pl, mob, what, outcome, value)
    self.log_head = self.log_head % self.log_size + 1;
    self.log[self.log_head] = { t = now, id = pl.id, who = pl.name, mob = mob.id, what = what, outcome = outcome, value = value };
end

function parse:action_name(kind, id)
    local key = kind .. ':' .. id;
    local n   = self.names[key];
    if (not n) then
        n = self.world.action_name(kind, id) or ('%s %d'):format(kind, id);
        self.names[key] = n;
    end
    return n;
end

-----------------------------------
-- Sources
-----------------------------------
-- The source a result goes into: key, display name, kind.
function parse:source_for(a, r, pet)
    local cat, id = a.category, a.id;

    if (pet) then
        if (cat == C.MELEE) then
            return 'pet:' .. pet .. ':melee', pet .. ' - Melee', 'pet';
        end
        -- Pets' TP moves come on the weapon skill or monster skill category, blood pacts on the
        -- pet skill category.
        local kind = (cat == C.MAGIC and 'spell') or (cat == C.PETSKILL and 'petskill')
            or ((cat == C.MOBSKILL or cat == C.SKILL) and 'mobskill') or 'ability';
        return ('pet:%s:%d:%d'):format(pet, cat, id), pet .. ' - ' .. self:action_name(kind, id), 'pet';
    end

    if (cat == C.MELEE) then
        if (r.animation == ANIM.KICK_R or r.animation == ANIM.KICK_L) then
            return 'kick', 'Kick Attacks', 'melee';
        end
        return 'melee', 'Melee', 'melee';
    elseif (cat == C.RANGED) then
        return 'ranged', 'Ranged Attack', 'ranged';
    elseif (cat == C.SKILL) then
        if (classify.SKILL_AS_ABILITY[r.message]) then
            return 'ja:' .. id, self:action_name('ability', id), 'ja';
        end
        return 'ws:' .. id, self:action_name('weaponskill', id), 'ws';
    elseif (cat == C.MAGIC) then
        return 'ma:' .. id, self:action_name('spell', id), 'magic';
    elseif (cat == C.MOBSKILL or cat == C.PETSKILL) then
        return 'ms:' .. id, self:action_name('mobskill', id), 'ws';
    end
    return 'ja:' .. id, self:action_name('ability', id), 'ja';
end

-----------------------------------
-- Actions
-----------------------------------
--[[
* Reads one decoded action. Returns true if anything was counted.
--]]
function parse:action(a)
    if (not a or a.actor == 0 or a.category == 0) then
        return false;
    end
    local credit, pet = self.world.credit(a.actor);
    if (credit) then
        return self:offense(a, credit, pet);
    end
    if (self.world.is_enemy(a.actor)) then
        return self:defense(a);
    end
    return false;
end

function parse:skillchain(credit, b, pl, mob, name, dmg, pet, now)
    local mob_id = mob.id;
    local key  = 'sc:' .. name;
    local s    = stat(b, key, 'SC: ' .. name, 'sc');
    record(s, 'hit', dmg);
    b.sc_closed = b.sc_closed + 1;

    -- Shared mode: half to the closer, half to whoever made the step before (all of it to the
    -- closer when they made both, say with their own pet, or when the opener isn't known).
    local chain = self.chains[mob_id];
    if (chain and now - chain.at <= parse.CHAIN_WINDOW and self.players[chain.opener] and chain.opener ~= credit) then
        local ob = self:bucket(self.players[chain.opener], mob);
        ob.sc_opened = ob.sc_opened + 1;
        ob.sc_share  = ob.sc_share + dmg / 2;
        b.sc_share   = b.sc_share + dmg / 2;
    else
        b.sc_share = b.sc_share + dmg;
    end
    -- The closer opens the next step.
    self.chains[mob_id] = { opener = credit, at = now };
    self:add_log(now, pl, mob, 'SC: ' .. name, 'hit', dmg);
end

function parse:offense(a, credit, pet)
    local cat = a.category;
    if (not classify.COUNTED[cat]) then
        return false;
    end

    local world   = self.world;
    local now     = world.now();
    local pl      = self:player(credit);
    local counted = false;

    for _, t in ipairs(a.targets) do
        -- Actions on the party (cures, buffs) aren't damage.
        if (not world.credit(t.id)) then
            local mob       = self:note_mob(t.id);
            local b         = self:bucket(pl, mob);
            local swings    = 0;
            -- A round cut short (the mob died, or the packet is full) has fewer swings than the
            -- player's multi-attack rate would give, so it's left out of hits per round.
            local truncated = #t.results >= parse.ROUND_CAP;
            self.engaged[t.id] = now;

            for _, r in ipairs(t.results) do
                local outcome, dmg = classify.outcome(cat, r);
                if (outcome) then
                    local key, name, kind = self:source_for(a, r, pet);
                    local s = stat(b, key, name, kind);
                    record(s, outcome, dmg);
                    if (classify.BURST[r.message]) then
                        s.bursts = s.bursts + 1;
                    end

                    if (not pet and (cat == C.MELEE or cat == C.RANGED)) then
                        record_acc(cat == C.RANGED and b.ranged or b.melee, outcome);
                        if (cat == C.MELEE and r.animation <= ANIM.KICK_L) then
                            swings = swings + 1;
                        end
                    end
                    counted = true;
                    self:add_log(now, pl, mob, name, outcome, dmg);
                elseif (WATCHED[cat] and not NOT_ATTACKS[r.message]) then
                    local k = ('%d:%d'):format(cat, r.message);
                    self.unknown[k] = (self.unknown[k] or 0) + 1;
                end

                -- Additional effects: a skillchain on a weapon skill, or proc damage.
                local sc_name, sc_dmg = classify.skillchain(cat, r);
                if (sc_name) then
                    self:skillchain(credit, b, pl, mob, sc_name, sc_dmg, pet, now);
                    counted = true;
                elseif (r.proc_message and classify.PROC_DAMAGE[r.proc_message] and cat ~= C.ABILITY) then
                    local key  = pet and ('pet:' .. pet .. ':add') or 'add';
                    local name = pet and (pet .. ' - Additional Effect') or 'Additional Effect';
                    record(stat(b, key, name, pet and 'pet' or 'add'), 'hit', r.proc_param);
                    counted = true;
                end

                -- A weapon skill that landed without closing a chain opens one.
                if (not sc_name and (outcome == 'hit' or outcome == 'crit')
                    and (cat == C.SKILL or cat == C.MOBSKILL or cat == C.PETSKILL)) then
                    self.chains[t.id] = { opener = credit, at = now };
                end

                -- The mob's spikes or counter on our own swing: damage taken.
                if (not pet) then
                    local _, react_dmg = classify.react(r);
                    if (react_dmg) then
                        b.taken = b.taken + react_dmg;
                    end
                end

                if (classify.defeated(r)) then
                    truncated = true;
                end
            end

            if (swings > 0 and not truncated) then
                b.rounds       = b.rounds + 1;
                b.round_swings = b.round_swings + swings;
            end
        end
    end

    if (counted) then
        self:mark(now);
        self:mark_player(pl, now);
    end
    return counted;
end

-- A monster's action on the party: damage taken, and the spikes and counters it ran into.
function parse:defense(a)
    local world   = self.world;
    local now     = world.now();
    local mob     = self:note_mob(a.actor);
    local counted = false;

    for _, t in ipairs(a.targets) do
        local credit, pet = world.credit(t.id);
        if (credit) then
            local pl = self:player(credit);
            local b  = self:bucket(pl, mob);
            self.engaged[a.actor] = now;

            for _, r in ipairs(t.results) do
                local outcome, dmg = classify.outcome(a.category, r);
                if (not pet and (outcome == 'hit' or outcome == 'crit')) then
                    b.taken = b.taken + dmg;
                    counted = true;
                end

                local react, react_dmg = classify.react(r);
                if (react) then
                    local key  = pet and ('pet:' .. pet .. ':' .. react) or ('react:' .. react);
                    local name = pet and (pet .. ' - ' .. react) or react;
                    record(stat(b, key, name, pet and 'pet' or 'react'), 'hit', react_dmg);
                    self:add_log(now, pl, mob, name, 'hit', react_dmg);
                    counted = true;
                end
            end
        end
    end

    if (counted) then
        self:mark(now);
    end
    return counted;
end

--[[
* A battle message (0x029): { actor, target, message }. Counts a kill when a mob the party was
* fighting dies, whatever killed it (a damage-over-time effect included). The killer, when there
* is one and it's in the party, gets the kill. Returns true if a kill was counted.
--]]
function parse:defeat(msg)
    if (not msg or not DEFEAT[msg.message]) then
        return false;
    end
    local id   = (msg.target and msg.target ~= 0) and msg.target or msg.actor;
    local seen = self.engaged[id];
    local now  = self.world.now();
    if (not seen or now - seen > parse.KILL_WINDOW) then
        return false;
    end
    self.engaged[id] = nil;
    self.chains[id]  = nil;

    local mob = self:note_mob(id);
    mob.kills  = mob.kills + 1;
    self.kills = self.kills + 1;

    local credit = msg.message == 6 and msg.actor ~= id and self.world.credit(msg.actor);
    if (credit) then
        local pl = self:player(credit);
        local b  = self:bucket(pl, mob);
        b.kills  = b.kills + 1;
        self:add_log(now, pl, mob, 'Defeated', 'kill', 0);
    else
        -- Died to something with no killing blow of ours (a DoT, say): the party's kill.
        self:add_log(now, { id = 0, name = 'Party' }, mob, 'Defeated', 'kill', 0);
    end
    self.version = self.version + 1;
    return true;
end

-----------------------------------
-- Views
-----------------------------------
local function add_acc(into, from)
    into.attempts = into.attempts + from.attempts;
    into.hits     = into.hits + from.hits;
    into.misses   = into.misses + from.misses;
    into.crits    = into.crits + from.crits;
end

-- One player's buckets added up: all of them, one mob name's, or one mob's.
function parse:merged(pl, filter)
    local m = new_bucket();
    for id, b in pairs(pl.buckets) do
        if (parse.matches(filter, id, b)) then
            for key, s in pairs(b.sources) do
                local into = m.sources[key];
                if (not into) then
                    into = { key = key, name = s.name, kind = s.kind, total = 0, count = 0, attempts = 0,
                             hits = 0, misses = 0, crits = 0, bursts = 0, max = 0, min = nil };
                    m.sources[key] = into;
                end
                into.total    = into.total + s.total;
                into.count    = into.count + s.count;
                into.attempts = into.attempts + s.attempts;
                into.hits     = into.hits + s.hits;
                into.misses   = into.misses + s.misses;
                into.crits    = into.crits + s.crits;
                into.bursts   = into.bursts + s.bursts;
                into.max      = math.max(into.max, s.max);
                if (s.min and (not into.min or s.min < into.min)) then
                    into.min = s.min;
                end
            end
            add_acc(m.melee, b.melee);
            add_acc(m.ranged, b.ranged);
            m.rounds       = m.rounds + b.rounds;
            m.round_swings = m.round_swings + b.round_swings;
            m.taken        = m.taken + b.taken;
            m.kills        = m.kills + b.kills;
            m.sc_closed    = m.sc_closed + b.sc_closed;
            m.sc_opened    = m.sc_opened + b.sc_opened;
            m.sc_share     = m.sc_share + b.sc_share;
        end
    end

    m.damage, m.sc = 0, 0;
    for _, s in pairs(m.sources) do
        if (s.kind == 'sc') then
            m.sc = m.sc + s.total;
        else
            m.damage = m.damage + s.total;
        end
    end
    return m;
end

-- The skillchain damage a player's total gets in each mode.
function parse.sc_credit(m, sc_mode)
    if (sc_mode == 'player') then
        return m.sc;
    elseif (sc_mode == 'shared') then
        return m.sc_share;
    end
    return 0;
end

--[[
* The meter: one row per player, biggest first. sc_mode is 'player' (skillchains count for the
* closer), 'shared' (split between opener and closer), 'bar' (their own row) or 'off'.
--]]
function parse:view(filter, sc_mode)
    local rows, grand, chains = {}, 0, 0
    local seconds = math.max(self.active, 1);

    for id, pl in pairs(self.players) do
        local m     = self:merged(pl, filter or parse.ALL_MOBS);
        local total = m.damage + parse.sc_credit(m, sc_mode);
        chains = chains + m.sc;
        if (total > 0 or m.taken > 0) then
            rows[#rows + 1] = { id = id, name = pl.name, total = total, data = m };
            grand = grand + total;
        end
    end

    if (sc_mode == 'bar' and chains > 0) then
        rows[#rows + 1] = { id = 'sc', name = 'Skillchains', total = chains, sc_row = true };
        grand = grand + chains;
    end

    table.sort(rows, function (x, y)
        if (x.total == y.total) then
            return tostring(x.name) < tostring(y.name);
        end
        return x.total > y.total;
    end);

    for _, row in ipairs(rows) do
        row.share = grand > 0 and row.total / grand or 0;
        row.dps   = row.total / seconds;
    end

    -- Kills: every mob the filter takes that died, whoever (or whatever) killed it.
    local kills = 0;
    for id, m in pairs(self.mobs) do
        if (parse.matches(filter, id, { mob = m.name })) then
            kills = kills + m.kills;
        end
    end

    return { rows = rows, total = grand, active = self.active, dps = grand / seconds, kills = kills };
end

--[[
* One player's sources, biggest first, with each one's share of that player's damage.
--]]
function parse:detail(id, filter)
    local pl = self.players[id];
    if (not pl) then
        return nil;
    end
    local m       = self:merged(pl, filter or parse.ALL_MOBS);
    local list    = {};
    local overall = m.damage + m.sc;
    for _, s in pairs(m.sources) do
        if (s.total > 0 or s.attempts > 0) then
            s.share = overall > 0 and s.total / overall or 0;
            list[#list + 1] = s;
        end
    end
    table.sort(list, function (x, y)
        if (x.total == y.total) then
            return x.name < y.name;
        end
        return x.total > y.total;
    end);
    m.list       = list;
    m.name       = pl.name;
    m.dps        = m.damage / math.max(self.active, 1);
    -- Over the time this player was actually acting, not the whole fight.
    m.active     = pl.active;
    m.active_dps = m.damage / math.max(pl.active, parse.ACTIVE_FLOOR);
    return m;
end

-- Newest first.
function parse:recent(n)
    local out = {};
    local count = math.min(n, #self.log);
    for i = 0, count - 1 do
        local index = (self.log_head - 1 - i) % self.log_size + 1;
        out[#out + 1] = self.log[index];
    end
    return out;
end

-- Plain text lines for /pxp report: a title, then one line per row.
function parse:report_lines(filter, sc_mode, n, fmt)
    local v     = self:view(filter, sc_mode);
    local title = fmt.title or self:filter_label(filter);
    local lines = { ('pxparse: %s, %s total, %s'):format(title, fmt.number(v.total), fmt.duration(v.active)) };
    for i, row in ipairs(v.rows) do
        if (i > n) then
            break;
        end
        local name = (fmt.name and not row.sc_row) and fmt.name(row) or row.name;
        lines[#lines + 1] = ('%d. %s %s (%.1f%%) %s DPS'):format(i, name, fmt.number(row.total), row.share * 100, fmt.decimal(row.dps));
    end
    return lines;
end

-- A CSV of every player's sources, for /pxp export.
function parse:csv(filter)
    local out = { 'player,source,kind,total,landed,attempts,hits,misses,crits,max,min' };
    for id, pl in pairs(self.players) do
        local d = self:detail(id, filter);
        if (d) then
            for _, s in ipairs(d.list) do
                out[#out + 1] = ('%s,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d'):format(pl.name, (s.name:gsub(',', ' ')), s.kind,
                    s.total, s.count, s.attempts, s.hits, s.misses, s.crits, s.max, s.min or 0);
            end
        end
    end
    return table.concat(out, '\n') .. '\n';
end

return parse;
