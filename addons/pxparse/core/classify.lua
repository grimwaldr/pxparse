--[[
* pxparse - classify
* What a result in an action packet means. Every number here comes from Phoenix's server source
* (github.com/phoenixffxi/Phoenix): message ids from src/map/enums/msg_basic.h, the rest from
* src/map/enums/action/*.h and the melee round in src/map/entities/battle_entity.cpp.
--]]

local classify = {};

local function set(list)
    local s = {};
    for _, v in ipairs(list) do
        s[v] = true;
    end
    return s;
end

-- ActionCategory (enums/action/category.h).
classify.CATEGORY = {
    MELEE    = 1,  -- BasicAttack
    RANGED   = 2,  -- RangedFinish
    SKILL    = 3,  -- SkillFinish: weapon skills, and some job abilities (Jump, Mug...)
    MAGIC    = 4,  -- MagicFinish
    ITEM     = 5,
    ABILITY  = 6,  -- AbilityFinish
    MOBSKILL = 11, -- MobSkillFinish: also jug pet and charmed pet TP moves
    PETSKILL = 13, -- PetSkillFinish: blood pacts
    DANCER   = 14,
    RUNE     = 15,
};
local C = classify.CATEGORY;

-- The categories whose results can be damage. Start categories (7, 8, 9, 10, 12) carry none.
classify.COUNTED = set({ 1, 2, 3, 4, 6, 11, 13, 14, 15 });

-- ActionResolution (enums/action/resolution.h).
classify.RESOLUTION = { HIT = 0, MISS = 1, GUARD = 2, PARRY = 3, BLOCK = 4 };

-- The info field is a set of flags (ActionInfo): bit 1 the target was defeated, bit 2 a crit.
classify.INFO_DEFEATED = 1;
classify.INFO_CRIT     = 2;

-- Melee animation (AttackAnimation in attack.h).
classify.ANIM = { MAIN = 0, OFF = 1, KICK_R = 2, KICK_L = 3 };

-- Result messages whose param is damage dealt to the target. Drains count: the mob loses the HP.
classify.DAMAGE = set({
    1,   -- AttackHits
    2,   -- MagicDamage
    67,  -- AttackCrit
    77,  -- UsesSangeTakesDamage
    110, -- UsesAbilityTakesDamage (Jump, Weapon Bash, Chi Blast...)
    157, -- UsesBarrageTakesDamage
    185, -- UsesSkillTakesDamage (weapon skills, pet TP moves)
    187, -- UsesSkillHPDrained
    197, -- UsesAbilityResistsDamage
    227, -- MagicDrainsHP
    252, -- MagicBurstDamage
    264, -- TargetTakesDamage (the other targets of an area action)
    274, -- MagicBurstDrainsHP
    281, -- TargetHPDrained
    317, -- UsesJobAbilityTakeDamage (blood pacts, Steal and friends with damage)
    352, -- RangedAttackHit
    353, -- RangedAttackCrit
    576, -- RangedAttackSquarely
    577, -- RangedAttackPummels
});

classify.CRIT  = set({ 67, 353 });
classify.BURST = set({ 252, 274 });

-- Swings that rolled and missed.
classify.MISS = set({
    15,  -- AttackMisses
    158, -- AbilityMisses
    188, -- UsesSkillMisses
    282, -- TargetEvades
    324, -- UsesButMisses
    354, -- RangedAttackMiss
});

-- Spells that landed nothing.
classify.RESIST = set({ 85, 284, 655 });

-- Swings stopped by the target. In Phoenix's melee round, parry, shadows, anticipate and counter
-- are all checked after the hit roll succeeds, so for accuracy they are hits. Perfect Dodge is
-- checked before the roll, so it says nothing about accuracy.
classify.AVOID = {
    [30]  = 'anticipated', -- TargetAnticipates
    [31]  = 'shadow',      -- ShadowAbsorb (param is shadows lost, not damage)
    [32]  = 'dodged',      -- TargetDodges (Perfect Dodge)
    [70]  = 'parried',     -- TargetParries
    [355] = 'shadow',      -- RangedAttackNoEffect
};

-- Outcomes that count toward accuracy, and how.
classify.ACC_HIT  = set({ 'hit', 'crit', 'parried', 'shadow', 'anticipated', 'countered' });
classify.ACC_MISS = set({ 'miss' });

-- Additional effect messages (proc block) that are damage.
classify.PROC_DAMAGE = set({
    161, -- AddEffectHPDrained
    163, -- AddEffectDamage
    229, -- AddEffectAdditionalDamage
});

-- Skillchains: proc message 287 + chain for damage, 384 + chain when the mob absorbs it
-- (action_result_t::recordSkillchain in src/map/action/action.cpp). The chain is the proc kind.
classify.SKILLCHAIN = {
    'Light', 'Darkness', 'Gravitation', 'Fragmentation', 'Distortion', 'Fusion', 'Compression',
    'Liquefaction', 'Induration', 'Reverberation', 'Transfixion', 'Scission', 'Detonation',
    'Impaction', 'Radiance', 'Umbra',
};

-- React block (ActionReactKind): 1 to 10 are spikes, 63 is a counter or retaliation.
classify.SPIKES = {
    'Blaze Spikes', 'Ice Spikes', 'Dread Spikes', 'Curse Spikes', 'Shock Spikes',
    'Reprisal', 'Wind Spikes', 'Earth Spikes', 'Water Spikes', 'Death Spikes',
};
classify.REACT_COUNTER = 63;

-- React messages whose param is damage to the attacker.
classify.REACT_DAMAGE = {
    [33]  = 'Counter',     -- AttackCounteredDamage
    [44]  = 'Spikes',      -- SpikesEffectDmg
    [132] = 'Spikes',      -- SpikesEffectHPDrain
    [536] = 'Retaliation', -- RetaliateDamage
};

-- Job abilities that the server sends on the weapon skill category: their id is an ability id.
classify.SKILL_AS_ABILITY = set({ 110, 158, 317 });

--[[
* The outcome of one result: 'hit', 'crit', 'miss', 'resist', 'parried', 'shadow',
* 'anticipated', 'dodged', 'deflected', 'countered', or nil when it isn't an attack at all
* (a buff, a heal, a debuff). The second value is the damage.
--]]
function classify.outcome(category, r)
    local msg = r.message;

    -- A countered swing has no message of its own, only the counter in the react block.
    if (msg == 0 and r.react_kind == classify.REACT_COUNTER) then
        return 'countered', 0;
    end
    -- Deflected: AttackHits with a parry resolution and no damage, decided before the hit roll.
    if (msg == 1 and r.resolution == classify.RESOLUTION.PARRY) then
        return 'deflected', 0;
    end
    if (classify.CRIT[msg]) then
        return 'crit', r.param;
    end
    if (classify.DAMAGE[msg]) then
        if (category == C.SKILL and r.info % 4 >= classify.INFO_CRIT) then
            return 'crit', r.param;
        end
        return 'hit', r.param;
    end
    if (classify.MISS[msg]) then
        return 'miss', 0;
    end
    if (classify.RESIST[msg]) then
        return 'resist', 0;
    end
    local avoided = classify.AVOID[msg];
    if (avoided) then
        return avoided, 0;
    end
    return nil, 0;
end

function classify.defeated(r)
    return r.info % 2 == 1;
end

--[[
* A skillchain in the proc block: its name and damage (0 when absorbed), or nil.
--]]
function classify.skillchain(category, r)
    if (category ~= C.SKILL and category ~= C.MOBSKILL and category ~= C.PETSKILL) then
        return nil;
    end
    local msg, kind = r.proc_message, r.proc_kind;
    if (not msg or not kind or kind < 1 or kind > #classify.SKILLCHAIN) then
        return nil;
    end
    if (msg == 287 + kind) then
        return classify.SKILLCHAIN[kind], r.proc_param;
    end
    if (msg == 384 + kind) then
        return classify.SKILLCHAIN[kind], 0;
    end
    return nil;
end

--[[
* Damage the defender dealt back to the attacker in the react block: its name and amount, or nil.
--]]
function classify.react(r)
    local label = r.react_message and classify.REACT_DAMAGE[r.react_message];
    if (not label) then
        return nil;
    end
    if (r.react_kind == classify.REACT_COUNTER) then
        return label == 'Retaliation' and 'Retaliation' or 'Counter', r.react_param;
    end
    return classify.SPIKES[r.react_kind] or label, r.react_param;
end

return classify;
