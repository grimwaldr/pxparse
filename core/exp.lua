--[[
* pxparse - exp
* Experience and limit points per hour. Plain Lua, tested offline.
*
* Gains come from the server's 0x02D battle message (src/map/packets/s2c/0x02d_battle_message2.h in
* Phoenix): message 8 or 253 (a chain) for experience points, 371 or 372 (a chain) for limit
* points, with the amount and the chain number.
*
* The rate is over the last 10 minutes (or since the first gain, if that's sooner, but never
* under a minute, so the first kill doesn't read as a huge rate).
*
* The chain timer follows Phoenix's era rules (modules/era/lua/globals/toau_experience_points.lua
* and xi.experiencePoints.calculate in scripts/globals/experience_points.lua). A kill on an Even
* Match or tougher mob opens the window: the bracket's start time when no chain is running, or, for
* "EXP chain #n", the (n + 1)th window. A weaker mob's kill gives plain points and leaves the timer
* alone. The client isn't told which a plain kill was, so after one with no chain running the timer
* shows the start window as a chain that may have begun (`open` but not `sure`).
--]]

local exp = {};
exp.__index = exp;

exp.WINDOW = 600;
exp.FLOOR  = 60;

local KIND = { [8] = 'exp', [253] = 'exp', [371] = 'limit', [372] = 'limit' };
local CHAIN = { [253] = true, [372] = true };

-- Seconds to the next kill, by the mob's level: the start window, then one per chain number.
exp.CHAIN_WINDOWS = {
    { max_level =   9, start =  80, windows = {  80,  60,  40,  30, 15 } },
    { max_level =  19, start = 130, windows = { 130, 110,  80,  60, 25 } },
    { max_level =  29, start = 160, windows = { 150, 120,  90,  60, 30 } },
    { max_level =  39, start = 200, windows = { 200, 170, 130,  80, 40 } },
    { max_level =  49, start = 290, windows = { 290, 230, 170, 110, 50 } },
    { max_level =  59, start = 300, windows = { 300, 240, 180, 120, 60 } },
    { max_level = 255, start = 300, windows = { 300, 240, 180, 120, 60 } },
};

-- The bracket for a mob of this level. The mob's level isn't sent, so callers pass the player's
-- own: an Even Match or tougher mob is at least that, and from 50 up every bracket is the same.
function exp.bracket(level)
    for _, b in ipairs(exp.CHAIN_WINDOWS) do
        if ((level or 75) <= b.max_level) then
            return b;
        end
    end
    return exp.CHAIN_WINDOWS[#exp.CHAIN_WINDOWS];
end

function exp.new()
    local e = setmetatable({}, exp);
    e:reset();
    return e;
end

function exp:reset()
    self.gains = {};    -- { t, amount }, oldest first
    self.total = 0;
    self.first = nil;   -- when the first gain came in
    self.kind  = nil;   -- 'exp' or 'limit': whichever came last
    self.chain = 0;
    self.chain_at = nil;
    self.deadline = nil; -- when the chain window closes
    self.window   = nil; -- how long that window was
    self.sure     = false;
end

--[[
* A decoded 0x02D: { message, amount, chain }. Returns true if it was experience or limit points.
--]]
function exp:gain(msg, now, level)
    local kind = msg and KIND[msg.message];
    if (not kind) then
        return false;
    end
    self.gains[#self.gains + 1] = { t = now, amount = msg.amount };
    self.total = self.total + msg.amount;
    self.first = self.first or now;
    self.kind  = kind;
    local bracket = exp.bracket(level);
    if (CHAIN[msg.message]) then
        -- "Chain #n": the server used the (n + 1)th window, the last one from #4 on.
        self.chain    = msg.chain or 0;
        self.chain_at = now;
        self.window   = bracket.windows[math.min(self.chain + 1, #bracket.windows)];
        self.deadline = now + self.window;
        self.sure     = true;
    elseif (not self.deadline or now >= self.deadline) then
        -- No chain running: a tough enough mob started one, a weaker one didn't.
        self.chain    = 0;
        self.window   = bracket.start;
        self.deadline = now + self.window;
        self.sure     = false;
    end
    -- A plain gain inside a running window was a weaker mob: the chain carries on untouched.
    -- Only the window matters for the rate; older gains stay in the total.
    while (#self.gains > 0 and now - self.gains[1].t > exp.WINDOW) do
        table.remove(self.gains, 1);
    end
    return true;
end

--[[
* The rate per hour, and with `left` (points still needed for the next level or merit point) the
* seconds until it at that rate. Nil before the first gain.
--]]
function exp:summary(now, left)
    if (not self.first) then
        return nil;
    end
    local recent = 0;
    for _, g in ipairs(self.gains) do
        if (now - g.t <= exp.WINDOW) then
            recent = recent + g.amount;
        end
    end
    local span = math.max(exp.FLOOR, math.min(exp.WINDOW, now - self.first));
    local rate = recent * 3600 / span;
    local eta  = nil;
    if (left and left > 0 and rate > 0) then
        eta = left * 3600 / rate;
    end
    local left = self.deadline and (self.deadline - now) or nil;
    if (left and left <= 0) then
        left = nil;
    end
    return {
        rate = rate, total = self.total, kind = self.kind, eta = eta,
        chain = left and self.chain or 0,  -- the chain still running, 0 once its window closed
        chain_left = left,                 -- seconds left to keep it going, nil when closed
        chain_window = self.window,
        chain_sure = self.sure,            -- false when a plain kill may or may not have started one
    };
end

return exp;
