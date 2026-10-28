--[[
* pxparse - decode
* Reads an action packet (0x028) into a table. Plain Lua: no Ashita calls, so it runs in the tests.
*
* The layout follows Phoenix's own writer, GP_SERV_COMMAND_BATTLE2::pack
* (src/map/packets/s2c/0x028_battle2.cpp). Bit positions count from the start of the packet,
* header included, least significant bit first (Phoenix's unpackBitsBE, despite the name).
*
*   40 actor (32), 72 target count (6), 76 result sum (4, always 0), 82 category (4),
*   86 action id (32), 118 recast (32), then each target from bit 150:
*     id (32), result count (4), then each result:
*       +0 resolution (3), +3 kind (2), +5 animation (12), +17 info (5), +22 distortion (2),
*       +24 knockback (3), +27 param (17), +44 message (10), +54 modifier (31),
*       +85 proc flag (1)  [+ kind (6), info (4), param (17), message (10)],
*       then react flag (1) [+ kind (6), info (4), param (14), message (10)].
--]]

local decode = {};

local byte  = string.byte;
local floor = math.floor;

local POW = {};
for i = 0, 32 do
    POW[i] = 2 ^ i;
end

--[[
* Reads `len` bits (up to 32) starting at bit `pos` of the string `s`. Arithmetic rather than
* the bit library, so ids above 0x7FFFFFFF don't come back negative.
--]]
function decode.bits(s, pos, len)
    local value, shift = 0, 0;
    local index  = floor(pos / 8) + 1;
    local offset = pos % 8;
    while (len > 0) do
        local b    = byte(s, index) or 0;
        local take = 8 - offset;
        if (take > len) then
            take = len;
        end
        value  = value + (floor(b / POW[offset]) % POW[take]) * POW[shift];
        shift  = shift + take;
        len    = len - take;
        index  = index + 1;
        offset = 0;
    end
    return value;
end

local u = decode.bits;

--[[
* The actor and category alone, to decide whether the rest is worth reading.
--]]
function decode.peek(s)
    return u(s, 40, 32), u(s, 82, 4);
end

--[[
* The whole action, or nil if the packet is shorter than its own counts say (never trust a
* count without checking the length).
--]]
function decode.action(s)
    if (not s or #s < 19) then
        return nil;
    end

    local action = {
        actor    = u(s, 40, 32),
        category = u(s, 82, 4),
        id       = u(s, 86, 32),
        targets  = {},
    };

    local limit = #s * 8;
    local pos   = 150;
    for t = 1, u(s, 72, 6) do
        if (pos + 36 > limit) then
            return nil;
        end
        local target = { id = u(s, pos, 32), results = {} };
        local count  = u(s, pos + 32, 4);
        pos = pos + 36;

        for r = 1, count do
            if (pos + 87 > limit) then
                return nil;
            end
            local result = {
                resolution = u(s, pos,      3),
                kind       = u(s, pos + 3,  2),
                animation  = u(s, pos + 5,  12),
                info       = u(s, pos + 17, 5),
                param      = u(s, pos + 27, 17),
                message    = u(s, pos + 44, 10),
            };
            pos = pos + 85;

            if (u(s, pos, 1) == 1) then
                result.proc_kind    = u(s, pos + 1,  6);
                result.proc_param   = u(s, pos + 11, 17);
                result.proc_message = u(s, pos + 28, 10);
                pos = pos + 38;
            else
                pos = pos + 1;
            end

            if (u(s, pos, 1) == 1) then
                result.react_kind    = u(s, pos + 1,  6);
                result.react_param   = u(s, pos + 11, 14);
                result.react_message = u(s, pos + 25, 10);
                pos = pos + 35;
            else
                pos = pos + 1;
            end

            target.results[r] = result;
        end
        action.targets[t] = target;
    end

    if (pos > limit) then
        return nil;
    end
    return action;
end

--[[
* A battle message (0x029): actor at 0x04, target at 0x08, param at 0x0C, message at 0x18 (its top
* bit is a flag, not part of the id). Used for kills, which arrive here rather than as an action.
--]]
function decode.message(s)
    if (not s or #s < 0x1A) then
        return nil;
    end
    return {
        actor   = u(s, 0x04 * 8, 32),
        target  = u(s, 0x08 * 8, 32),
        param   = u(s, 0x0C * 8, 32),
        message = u(s, 0x18 * 8, 15),
    };
end

--[[
* Experience and limit points (0x02D): actor at 0x04, amount at 0x10, chain number at 0x14,
* message at 0x18 (top bit a flag), per GP_SERV_COMMAND_BATTLE_MESSAGE2 in Phoenix.
--]]
function decode.points(s)
    if (not s or #s < 0x1A) then
        return nil;
    end
    return {
        actor   = u(s, 0x04 * 8, 32),
        amount  = u(s, 0x10 * 8, 32),
        chain   = u(s, 0x14 * 8, 32),
        message = u(s, 0x18 * 8, 15),
    };
end

return decode;
