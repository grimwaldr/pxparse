--[[
* pxparse - fights
* Splits the parse into fights. A fight starts with the first thing the party does to a mob (or
* a mob does to the party). It lasts while any mob in it is alive and was touched in the last
* ENGAGED seconds, however long the gaps between actions (slow ranged attacks, a mob that's
* walking back). Once every mob in it is dead (or gone), it ends SETTLE seconds after the last
* action or kill. Each fight is its own parse;
* one more, `overall`, takes everything since the last reset. The last `limit` fights are kept,
* newest first, each named after the mob that took the most damage: "Goblin Ambusher +1" when one
* other mob was in it too ("Goblin Ambusher [1A3] +1" when two Goblin Ambushers were).
*
* Plain Lua, like the rest of core: the tests drive it with a made-up world.
--]]

local parse = require('core.parse');

local fights = {};
fights.__index = fights;

fights.LINGER  = 30; -- seconds a finished fight still takes kills (a DoT can finish a mob late)
fights.ENGAGED = 30; -- a mob nobody has touched for this long is taken to be gone
fights.SETTLE  = 3;  -- seconds after the last mob dies before the fight ends

function fights.new(world, options)
    local f = setmetatable({ world = world, options = options or {} }, fights);
    f.limit = f.options.limit or 20;
    f:reset();
    return f;
end

function fights:reset()
    self.overall = parse.new(self.world, self.options);
    self.current = nil;
    self.history = {};
    self.serial  = 0;
end

function fights:set_idle(idle)
    self.options.idle = idle;
    self.overall.idle = idle;
    if (self.current) then
        self.current.idle = idle;
    end
end

-- One decoded action. Returns true if it counted (and so started or continued a fight).
function fights:action(a)
    if (not self.overall:action(a)) then
        return false;
    end
    local now = self.world.now();
    if (not self.current) then
        self.serial  = self.serial + 1;
        self.current = parse.new(self.world, self.options);
        self.current.number  = self.serial;
        self.current.started = now;
    end
    self.current:action(a);
    self.current.last_at = now;
    return true;
end

-- A battle message: kills go to the session and to the fight the mob died in.
function fights:defeat(msg)
    if (not self.overall:defeat(msg)) then
        return false;
    end
    local fight = self.current;
    local now   = self.world.now();
    if (not fight and self.history[1] and now - self.history[1].ended <= fights.LINGER) then
        fight = self.history[1];
    end
    if (fight) then
        fight:defeat(msg);
        if (fight == self.current) then
            fight.last_at = now;
        end
    end
    return true;
end

-- The mob that took the most damage, and how many others took any.
local function top_of(fight)
    local taken = {};
    for _, pl in pairs(fight.players) do
        for id, b in pairs(pl.buckets) do
            local total = 0;
            for _, s in pairs(b.sources) do
                total = total + s.total;
            end
            taken[id] = (taken[id] or 0) + total;
        end
    end
    local top, best, others = nil, -1, 0;
    for id, total in pairs(taken) do
        if (total > best) then
            top, best = id, total;
        end
    end
    for id, total in pairs(taken) do
        if (id ~= top and total > 0) then
            others = others + 1;
        end
    end
    return top, others;
end

-- A finished fight's name: its top mob (with its hex id when the setting or a same-named mob
-- calls for it), "+N" for the others.
function fights:name(fight, short)
    if (not fight.top or not fight.mobs[fight.top]) then
        return ('Fight %d'):format(fight.number or 0);
    end
    -- `short` leaves the hex id off, for tight spots (the list of fights keeps it).
    local name = short and fight.mobs[fight.top].name or fight:mob_display(fight.top);
    return fight.others > 0 and ('%s +%d'):format(name, fight.others) or name;
end

-- Ends the current fight once it's been quiet for `idle` seconds (or right away with `force`).
function fights:tick(force)
    local fight = self.current;
    if (not fight) then
        return;
    end
    local now = self.world.now();
    if (not force) then
        -- A mob still alive and fought recently keeps the fight going.
        for _, at in pairs(fight.engaged) do
            if (now - at <= fights.ENGAGED) then
                return;
            end
        end
        if (now - fight.last_at <= fights.SETTLE) then
            return;
        end
    end
    self.current = nil;
    fight.ended  = fight.last_at;
    fight.top, fight.others = top_of(fight);
    table.insert(self.history, 1, fight);
    while (#self.history > self.limit) do
        table.remove(self.history);
    end
end

--[[
* The parse to show for a choice: 'current' (the fight going on, or the last one when it's quiet),
* 'overall', or one of the kept fights (the parse itself). A fight that has dropped off the list
* falls back to 'current'. Returns the parse (or nil before any fighting) and the choice in use.
--]]
function fights:pick(choice)
    if (choice == 'overall') then
        return self.overall, 'overall';
    end
    if (type(choice) == 'table') then
        for _, fight in ipairs(self.history) do
            if (fight == choice) then
                return fight, choice;
            end
        end
    end
    return self.current or self.history[1], 'current';
end

-- What a choice is called on screen.
function fights:label(choice)
    if (choice == 'overall') then
        return 'Overall';
    end
    if (type(choice) == 'table') then
        return self:name(choice);
    end
    if (self.current) then
        return 'Current fight';
    end
    return self.history[1] and ('Last: %s'):format(self:name(self.history[1])) or 'Current fight';
end

-- Show every mob's hex id, not just where two share a name.
function fights:set_show_ids(on)
    self.options.show_ids = on;
end

function fights:live()
    return self.current ~= nil;
end

return fights;
