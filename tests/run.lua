--[[
* pxparse core tests. Plain LuaJIT, no Ashita: run with `luajit tests/run.lua` from the repo root
* (or `python3 tests/run.py`, which uses LuaJIT through lupa).
--]]

package.path = 'addons/pxparse/?.lua;tests/?.lua;' .. package.path;

local decode   = require('core.decode');
local classify = require('core.classify');
local parse    = require('core.parse');
local fights   = require('core.fights');
local exp      = require('core.exp');
local encode   = require('encode');

local passed, failed = 0, 0;

local function check(name, got, want)
    if (got == want) then
        passed = passed + 1;
    else
        failed = failed + 1;
        print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want)));
    end
end

-- A small world: two players, a pet, and a few mobs.
local GRIM, ALME, PET = 0x00100001, 0x00100002, 0x01000701;
local CRAB, CRAB2, GOB = 0x01001234, 0x01001235, 0x01001300;
local OUTSIDER = 0x00100099;

local clock = 0;
local world = {
    credit = function (id)
        if (id == GRIM or id == ALME) then
            return id;
        elseif (id == PET) then
            return GRIM, 'Carbuncle';
        end
        return nil;
    end,
    is_enemy    = function (id) return id >= 0x1000000 and id ~= PET; end,
    name        = function (id)
        return ({ [GRIM] = 'Grimwald', [ALME] = 'Alme', [PET] = 'Carbuncle', [CRAB] = 'Snipper',
                  [CRAB2] = 'Snipper', [GOB] = 'Goblin Thug', [OUTSIDER] = 'Someone' })[id] or '?';
    end,
    action_name = function (kind, id) return ('%s#%d'):format(kind, id); end,
    now         = function () return clock; end,
};

local function feed(p, action)
    local a = decode.action(encode.action(action));
    assert(a, 'decode failed');
    return p:action(a);
end

-----------------------------------
-- Decoder
-----------------------------------
do
    local packet = encode.action({ actor = 0x01ABCDEF, category = 3, id = 0xFFFFFFFF, targets = {
        { id = CRAB, results = {
            { resolution = 3, kind = 3, animation = 4095, info = 31, param = 131071, message = 1023,
              proc = { kind = 63, param = 131071, message = 1023 }, react = { kind = 63, param = 16383, message = 1023 } },
            { param = 7, message = 1 },
        } },
        { id = GOB, results = { { param = 9, message = 15 } } },
    } });
    local a = decode.action(packet);
    check('decode actor', a.actor, 0x01ABCDEF);
    check('decode category', a.category, 3);
    check('decode id (32 bits, no sign)', a.id, 0xFFFFFFFF);
    check('decode targets', #a.targets, 2);
    local r = a.targets[1].results[1];
    check('decode resolution', r.resolution, 3);
    check('decode animation', r.animation, 4095);
    check('decode info', r.info, 31);
    check('decode param', r.param, 131071);
    check('decode message', r.message, 1023);
    check('decode proc param', r.proc_param, 131071);
    check('decode react param', r.react_param, 16383);
    check('decode result after proc+react', a.targets[1].results[2].param, 7);
    check('decode second target', a.targets[2].id, GOB);
    check('decode second target message', a.targets[2].results[1].message, 15);

    local actor, category = decode.peek(packet);
    check('peek actor', actor, 0x01ABCDEF);
    check('peek category', category, 3);

    check('truncated packet is nil', decode.action(packet:sub(1, 30)), nil);
end

-----------------------------------
-- Melee
-----------------------------------
local p = parse.new(world, { idle = 6 });

clock = 0;
feed(p, { actor = GRIM, category = 1, targets = { { id = CRAB, results = {
    { animation = 0, param = 100, message = 1 },
    { animation = 1, param = 150, message = 67 },
} } } });
clock = 3;
feed(p, { actor = GRIM, category = 1, targets = { { id = CRAB, results = {
    { animation = 0, resolution = 1, message = 15 },
    { animation = 1, resolution = 1, param = 1, message = 31 },            -- shadow: param is shadows lost
    { animation = 0, resolution = 3, message = 70 },                       -- parried
    { animation = 0, resolution = 1, message = 32 },                       -- Perfect Dodge
    { animation = 0, resolution = 1, react = { kind = 63, param = 35, message = 33 } }, -- countered
} } } });

local d = p:detail(GRIM, parse.ALL_MOBS);
check('melee damage', d.sources.melee.total, 250);
check('melee landed', d.sources.melee.count, 2);
check('melee crits', d.sources.melee.crits, 1);
check('shadow not damage', d.sources.melee.max, 150);
check('melee acc attempts (dodge excluded)', d.melee.attempts, 6);
check('melee acc hits (parry, shadow, counter are hits)', d.melee.hits, 5);
check('melee acc misses', d.melee.misses, 1);
check('rounds', d.rounds, 2);
check('swings', d.round_swings, 7);
check('counter on my swing is damage taken', d.taken, 35);
check('active time (first action counts 3s, then the 3s gap)', p.active, 6);

-----------------------------------
-- Weapon skills and skillchains
-----------------------------------
clock = 5;
feed(p, { actor = ALME, category = 3, id = 34, targets = { { id = CRAB, results = {
    { kind = 3, param = 800, message = 185 },
} } } });
clock = 9;
feed(p, { actor = GRIM, category = 3, id = 40, targets = { { id = CRAB, results = {
    { kind = 3, param = 600, message = 185, info = 2, proc = { kind = 6, param = 400, message = 293 } },
} } } });

d = p:detail(GRIM, parse.ALL_MOBS);
check('ws damage', d.sources['ws:40'].total, 600);
check('ws crit from info flag', d.sources['ws:40'].crits, 1);
check('skillchain damage', d.sources['sc:Fusion'].total, 400);
check('skillchain name', d.sources['sc:Fusion'].name, 'SC: Fusion');
check('sc closed', d.sc_closed, 1);
check('sc opened by Alme', p:detail(ALME, parse.ALL_MOBS).sc_opened, 1);
check('damage leaves sc out', d.damage, 250 + 600);
check('sc total', d.sc, 400);

-- Absorbed skillchain: 384 + chain, no damage.
check('absorbed sc', select(2, classify.skillchain(3, { proc_kind = 6, proc_message = 390, proc_param = 99 })), 0);
-- An additional effect 384 on a melee swing isn't a skillchain.
check('melee 384 not sc', classify.skillchain(1, { proc_kind = 0, proc_message = 384 }), nil);

-- Job ability sent on the weapon skill category.
feed(p, { actor = GRIM, category = 3, id = 66, targets = { { id = CRAB, results = {
    { kind = 3, param = 120, message = 110 },
} } } });
check('jump on ws category is an ability', p:detail(GRIM, parse.ALL_MOBS).sources['ja:66'].total, 120);

-----------------------------------
-- Pets
-----------------------------------
feed(p, { actor = PET, category = 13, id = 831, targets = { { id = CRAB, results = {
    { param = 300, message = 317 },
} } } });
feed(p, { actor = PET, category = 1, targets = { { id = CRAB, results = {
    { param = 20, message = 1, proc = { kind = 1, param = 15, message = 163 } },
} } } });
d = p:detail(GRIM, parse.ALL_MOBS);
check('blood pact for owner', d.sources['pet:Carbuncle:13:831'].total, 300);
check('pet melee', d.sources['pet:Carbuncle:melee'].total, 20);
check('pet additional effect', d.sources['pet:Carbuncle:add'].total, 15);
check('pet swings stay out of owner accuracy', d.melee.attempts, 6);

-----------------------------------
-- Magic
-----------------------------------
feed(p, { actor = ALME, category = 4, id = 147, targets = {
    { id = CRAB, results = { { param = 900, message = 252 } } },
    { id = CRAB2, results = { { param = 0, message = 85 } } },
} });
d = p:detail(ALME, parse.ALL_MOBS);
check('magic burst damage', d.sources['ma:147'].total, 900);
check('magic burst counted', d.sources['ma:147'].bursts, 1);
check('resist counted as a miss', d.sources['ma:147'].misses, 1);

-- A cure on the party isn't damage.
check('cure ignored', feed(p, { actor = ALME, category = 4, id = 1, targets = { { id = GRIM, results = { { param = 90, message = 7 } } } } }), false);

-----------------------------------
-- Defense: damage taken, spikes, retaliation
-----------------------------------
clock = 12;
feed(p, { actor = CRAB, category = 1, targets = { { id = GRIM, results = {
    { param = 40, message = 1, react = { kind = 1, param = 20, message = 44 } },
    { param = 30, message = 1, react = { kind = 63, param = 25, message = 536 } },
} } } });
d = p:detail(GRIM, parse.ALL_MOBS);
check('taken', d.taken, 35 + 70);
check('blaze spikes', d.sources['react:Blaze Spikes'].total, 20);
check('retaliation', d.sources['react:Retaliation'].total, 25);

-----------------------------------
-- Kills, mob filter, unknown messages, outsiders
-----------------------------------
clock = 30; -- long gap: doesn't count as fighting
feed(p, { actor = GRIM, category = 1, targets = { { id = GOB, results = {
    { param = 77, message = 1, info = 1 },
    { param = 0, message = 500 },
} } } });
check('active: a long gap counts as a fresh 3s, not its length', p.active, 18);
-- The killing blow's info flag alone doesn't count a kill: the server's defeat message does.
check('no kill without the defeat message', p:detail(GRIM, 'Goblin Thug').kills, 0);
check('defeat message counted', p:defeat({ actor = GRIM, target = GOB, message = 6 }), true);
check('kill counted for the killer', p:detail(GRIM, 'Goblin Thug').kills, 1);
check('same mob twice is not two kills', p:defeat({ actor = GRIM, target = GOB, message = 6 }), false);
check('goblin filter damage', p:detail(GRIM, 'Goblin Thug').damage, 77);
check('snipper filter excludes goblin', p:detail(GRIM, 'Snipper').sources.melee.total, 250);
local labels = {};
for _, c in ipairs(p:mob_choices()) do
    labels[#labels + 1] = c.label;
end
check('mob choices grouped by name', table.concat(labels, ','),
    'All mobs,Goblin Thug,Snipper (all 2),Snipper [234],Snipper [235]');
check('hex label', parse.label('Goblin Ambusher', 0x0101D1A3), 'Goblin Ambusher [1A3]');
check('one mob by id', p:detail(ALME, 'id:' .. CRAB2).sources['ma:147'].misses, 1);
check('one mob by id leaves the other', p:detail(ALME, 'id:' .. CRAB2).sources['ma:147'].total, 0);
check('name filter takes both', p:detail(ALME, 'name:Snipper').sources['ma:147'].attempts, 2);
check('filter label', p:filter_label('id:' .. CRAB), 'Snipper [234]');
check('kills in the view', p:view(parse.ALL_MOBS, 'player').kills, 1);
check('unknown message noted', p.unknown['1:500'], 1);
check('outsider ignored', feed(p, { actor = OUTSIDER, category = 1, targets = { { id = CRAB, results = { { param = 9, message = 1 } } } } }), false);

-----------------------------------
-- Views
-----------------------------------
local v = p:view(parse.ALL_MOBS, 'player');
check('view first row', v.rows[1].name, 'Grimwald');
local grim_total = 250 + 600 + 400 + 120 + 300 + 20 + 15 + 20 + 25 + 77;
check('view grim total', v.rows[1].total, grim_total);
check('view grand', v.total, grim_total + 800 + 900);

v = p:view(parse.ALL_MOBS, 'bar');
local sc_row;
for _, row in ipairs(v.rows) do
    if (row.sc_row) then
        sc_row = row;
    end
end
check('sc bar row', sc_row and sc_row.total, 400);
-- Shared: Alme opened, Grimwald closed the 400 Fusion, so 200 each.
v = p:view(parse.ALL_MOBS, 'shared');
local shared = {};
for _, row in ipairs(v.rows) do
    shared[row.name] = row.total;
end
check('shared closer gets half', shared.Grimwald, grim_total - 200);
check('shared opener gets half', shared.Alme, 800 + 900 + 200);
check('shared grand total unchanged', v.total, grim_total + 800 + 900);
check('shared has no sc row', shared.Skillchains, nil);
check('sc off leaves it out', p:view(parse.ALL_MOBS, 'off').total, grim_total - 400 + 800 + 900);

local fmt = { number = tostring, duration = function (s) return s .. 's'; end, decimal = function (x) return ('%.1f'):format(x); end };
local lines = p:report_lines(parse.ALL_MOBS, 'player', 2, fmt);
check('report title + rows', #lines, 3);
check('csv header', p:csv(parse.ALL_MOBS):match('^[^\n]+'), 'player,source,kind,total,landed,attempts,hits,misses,crits,max,min');

local recent = p:recent(3);
check('log newest first', recent[1].what, 'Defeated');
check('log keeps the mob', recent[1].mob, GOB);
check('a mob with a unique name shows plainly', p:mob_display(GOB), 'Goblin Thug');
check('same-named mobs show their ids', p:mob_display(CRAB2), 'Snipper [235]');
p.options.show_ids = true;
check('Mob IDs on: every mob shows its id', p:mob_display(GOB), 'Goblin Thug [300]');
p.options.show_ids = false;

p:reset();
check('reset', next(p.players), nil);

-- Shared with nobody to share with: the pet's blood pact opens, its owner closes. All to Grimwald.
clock = 100;
feed(p, { actor = PET, category = 13, id = 831, targets = { { id = GOB, results = { { param = 100, message = 317 } } } } });
clock = 103;
feed(p, { actor = GRIM, category = 3, id = 40, targets = { { id = GOB, results = {
    { kind = 3, param = 200, message = 185, proc = { kind = 12, param = 300, message = 299 } },
} } } });
-- A chain with no opener seen at all (opened before the reset): all to the closer too.
feed(p, { actor = ALME, category = 3, id = 34, targets = { { id = CRAB, results = {
    { kind = 3, param = 50, message = 185, proc = { kind = 6, param = 90, message = 293 } },
} } } });
v = p:view(parse.ALL_MOBS, 'shared');
shared = {};
for _, row in ipairs(v.rows) do
    shared[row.name] = row.total;
end
check('own pet opener: closer keeps it all', shared.Grimwald, 100 + 200 + 300);
check('unknown opener: closer keeps it all', shared.Alme, 50 + 90);
check('own pet opener is not an opened chain', p:detail(GRIM, parse.ALL_MOBS).sc_opened, 0);

-----------------------------------
-- Kills without a killing blow, stale kills, cut-short rounds, active time
-----------------------------------
p:reset();
clock = 200;
feed(p, { actor = GRIM, category = 1, targets = { { id = CRAB, results = { { param = 10, message = 1 }, { animation = 1, param = 10, message = 1 } } } } });
check('falls to the ground counts for the party', p:defeat({ actor = CRAB, target = CRAB, message = 20 }), true);
check('party kill, nobody credited', p:detail(GRIM, parse.ALL_MOBS).kills, 0);
check('party kill in the view', p:view(parse.ALL_MOBS, 'player').kills, 1);
clock = 300;
check('a mob nobody touched lately is not our kill', p:defeat({ actor = GRIM, target = CRAB2, message = 6 }), false);

-- A round that kills the mob is cut short: its swings stay out of hits per round.
feed(p, { actor = GRIM, category = 1, targets = { { id = GOB, results = { { param = 10, message = 1, info = 1 } } } } });
local d2 = p:detail(GRIM, parse.ALL_MOBS);
check('full round counted', d2.rounds, 1);
check('killing round left out of hits per round', d2.round_swings, 2);
check('killing round still counts as damage', d2.sources.melee.total, 30);
-- An 8-result packet may have been cut off too.
local eight = {};
for i = 1, 8 do eight[i] = { param = 1, message = 1, animation = (i % 2 == 0) and 1 or 0 }; end
feed(p, { actor = GRIM, category = 1, targets = { { id = GOB, results = eight } } });
check('full packet left out of hits per round', p:detail(GRIM, parse.ALL_MOBS).rounds, 1);

-- Active time: Grimwald acted at 200 (a fresh stretch: 3s) and 300 (another: 3s), then 300 again.
check('player active time', p:detail(GRIM, parse.ALL_MOBS).active, 6);
clock = 304;
feed(p, { actor = GRIM, category = 1, targets = { { id = GOB, results = { { param = 1, message = 1 } } } } });
check('player active time continues', p:detail(GRIM, parse.ALL_MOBS).active, 10);
check('active dps', p:detail(GRIM, parse.ALL_MOBS).active_dps, 39 / 10);

-- Battle message decode (0x029).
do
    local bytes = {};
    for i = 1, 0x1C do bytes[i] = 0; end
    local function put32(off, v) for k = 0, 3 do bytes[off + k + 1] = math.floor(v / 256 ^ k) % 256; end end
    put32(0x04, GRIM); put32(0x08, GOB);
    bytes[0x18 + 1] = 6; bytes[0x19 + 1] = 0x80; -- message 6 with the flag bit set
    local chars = {};
    for i = 1, #bytes do chars[i] = string.char(bytes[i]); end
    local m = decode.message(table.concat(chars));
    check('0x029 actor', m.actor, GRIM);
    check('0x029 target', m.target, GOB);
    check('0x029 message ignores the flag bit', m.message, 6);
end

-----------------------------------
-- Fights
-----------------------------------
do
    local f = fights.new(world, { idle = 6, limit = 2 });
    local function hit(actor, mob, dmg)
        local a = decode.action(encode.action({ actor = actor, category = 1, targets = { { id = mob, results = { { param = dmg, message = 1 } } } } }));
        return f:action(a);
    end

    check('nothing yet', (f:pick('current')), nil);
    clock = 1000; hit(GRIM, CRAB, 100);
    clock = 1003; hit(ALME, CRAB, 50);
    clock = 1004; hit(GRIM, CRAB2, 20);   -- a second Snipper joins
    check('fight live', f:live(), true);
    check('current fight total', f:pick('current'):view(parse.ALL_MOBS, 'player').total, 170);

    -- Long gaps (a COR's ranged attacks, a mob walking back) don't split a fight while the mobs live.
    clock = 1008; f:tick();
    check('still live inside a short gap', f:live(), true);
    clock = 1020; f:tick();
    check('still live after a long gap: the mobs are alive', f:live(), true);
    check('one fight, not fragments', #f.history, 0);

    -- One dies, one doesn't: still one fight.
    check('kill counted', f:defeat({ actor = GRIM, target = CRAB, message = 6 }), true);
    clock = 1030; f:tick();
    check('one mob left alive keeps it going', f:live(), true);
    check('kill in the current fight', f:pick('current'):view(parse.ALL_MOBS, 'player').kills, 1);
    check('fight active time', f:pick('current').active, 3 + 3 + 1);

    -- Both dead: the fight ends a few seconds after the last kill.
    check('second kill', f:defeat({ actor = ALME, target = CRAB2, message = 6 }), true);
    clock = 1032; f:tick();
    check('settling after the last kill', f:live(), true);
    clock = 1034; f:tick();
    check('ended once every mob is dead', f:live(), false);
    check('named after the top mob, plus others', f:name(f.history[1]), 'Snipper [234] +1');
    check('short name leaves the id off', f:name(f.history[1], true), 'Snipper +1');
    check('quiet: current shows the last fight', f:label('current'), 'Last: Snipper [234] +1');

    -- Two mobs one after the other: two fights.
    clock = 1040; hit(GRIM, GOB, 9);
    f:defeat({ actor = GRIM, target = GOB, message = 6 });
    clock = 1044; f:tick();
    check('next pull is its own fight', #f.history, 2);
    check('a one-hit fight still has active time', f.history[1].active, 3);
    check('so its DPS is sane', f.history[1]:view(parse.ALL_MOBS, 'player').dps, 3);

    -- A mob that's never killed (you ran, it despawned) ends the fight after 30 quiet seconds.
    clock = 1050; hit(GRIM, CRAB, 1);
    clock = 1079; f:tick();
    check('alive and recent: still on', f:live(), true);
    clock = 1081; f:tick();
    check('untouched for 30s: over', f:live(), false);
    f:reset();

    clock = 1100; hit(GRIM, GOB, 40);
    clock = 1200; f:tick();
    clock = 1300; hit(ALME, GOB, 7);
    clock = 1400; f:tick();
    check('history newest first', f.history[1]:view(parse.ALL_MOBS, 'player').total, 7);
    check('history kept to the limit', #f.history, 2);
    check('overall has everything since the reset', f:pick('overall'):view(parse.ALL_MOBS, 'player').total, 47);
    local old = f.history[2];
    check('a kept fight can be picked', select(2, f:pick(old)), old);
    clock = 1500; hit(GRIM, GOB, 1);
    clock = 1600; f:tick();
    check('a dropped fight falls back to current', select(2, f:pick(old)), 'current');
    f:reset();
    check('reset clears history', #f.history, 0);

    -- A fight against one mob reads plainly; Mob IDs on adds its id, even to fights already kept.
    clock = 2000; hit(GRIM, GOB, 5);
    clock = 2100; f:tick();
    check('lone mob fight name', f:name(f.history[1]), 'Goblin Thug');
    f:set_show_ids(true);
    check('Mob IDs on reaches kept fights', f:name(f.history[1]), 'Goblin Thug [300]');
    f:set_show_ids(false);
end

-----------------------------------
-- Experience per hour
-----------------------------------
do
    local x = exp.new();
    check('nothing before a gain', x:summary(0), nil);
    check('other messages ignored', x:gain({ message = 6, amount = 100 }, 0), false);
    x:gain({ message = 8, amount = 100 }, 0);
    -- One gain at the start: never measured over less than a minute.
    check('first gain floored to a minute', x:summary(10).rate, 100 * 60);
    x:gain({ message = 253, amount = 120, chain = 1 }, 120);
    x:gain({ message = 253, amount = 150, chain = 2 }, 240);
    local s1 = x:summary(300, 740);
    check('rate over the time so far', s1.rate, 370 * 3600 / 300);
    check('chain number', s1.chain, 2);
    check('time to level at that rate', s1.eta, 740 * 3600 / (370 * 3600 / 300));
    check('total', s1.total, 370);
    -- Ten minutes later the first gain has left the window, but it stays in the total.
    x:gain({ message = 8, amount = 50 }, 700);
    local s2 = x:summary(700);
    check('window drops old gains', s2.rate, (120 + 150 + 50) * 3600 / 600);
    check('a plain gain ends the chain', s2.chain, 0);
    check('total keeps everything', s2.total, 420);
    x:gain({ message = 371, amount = 300 }, 710);
    check('limit points switch the kind', x:summary(710).kind, 'limit');
    x:reset();
    check('reset', x:summary(800), nil);

    -- Chain timer, by Phoenix's era windows (level 50+: 300 to start, then 240, 180, 120, 60).
    local c = exp.new();
    c:gain({ message = 8, amount = 200 }, 0, 75);
    local t0 = c:summary(10);
    check('plain kill: a chain may have started', t0.chain_left, 290);
    check('plain kill: not sure it did', t0.chain_sure, false);
    check('plain kill: no chain number yet', t0.chain, 0);
    c:gain({ message = 253, amount = 240, chain = 1 }, 100, 75);
    local t1 = c:summary(100);
    check('chain #1 uses the second window', t1.chain_left, 240);
    check('chain #1 is sure', t1.chain_sure, true);
    check('chain #1 number', t1.chain, 1);
    -- A weaker mob inside the window gives plain points and leaves the chain alone.
    c:gain({ message = 8, amount = 40 }, 200, 75);
    local t2 = c:summary(200);
    check('weaker mob keeps the chain', t2.chain, 1);
    check('weaker mob keeps the deadline', t2.chain_left, 140);
    c:gain({ message = 253, amount = 300, chain = 4 }, 300, 75);
    check('chain #4 and up: the last window', c:summary(300).chain_left, 60);
    c:gain({ message = 253, amount = 300, chain = 9 }, 350, 75);
    check('chain #9: still the last window', c:summary(350).chain_left, 60);
    local gone = c:summary(411);
    check('window closed: no time left', gone.chain_left, nil);
    check('window closed: chain shows 0', gone.chain, 0);
    -- Low levels use their own bracket.
    local low = exp.new();
    low:gain({ message = 253, amount = 50, chain = 2 }, 0, 25);
    check('level 20-29 bracket, chain #2', low:summary(0).chain_left, 90);
    check('limit chain uses the same windows', (function ()
        local l = exp.new(); l:gain({ message = 372, amount = 300, chain = 1 }, 0, 75); return l:summary(0).chain_left;
    end)(), 240);

    -- 0x02D decode.
    local bytes = {};
    for i = 1, 0x1C do bytes[i] = 0; end
    local function put32(off, v) for k = 0, 3 do bytes[off + k + 1] = math.floor(v / 256 ^ k) % 256; end end
    put32(0x04, GRIM); put32(0x10, 1234); put32(0x14, 3);
    bytes[0x18 + 1] = 253 % 256; bytes[0x19 + 1] = 0x80;
    local chars = {};
    for i = 1, #bytes do chars[i] = string.char(bytes[i]); end
    local m = decode.points(table.concat(chars));
    check('0x02D actor', m.actor, GRIM);
    check('0x02D amount', m.amount, 1234);
    check('0x02D chain', m.chain, 3);
    check('0x02D message ignores the flag bit', m.message, 253);
end

print(('%d passed, %d failed'):format(passed, failed));
return failed;
