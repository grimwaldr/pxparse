--[[
* Builds action packets the way Phoenix's server does (GP_SERV_COMMAND_BATTLE2::pack and
* packBitsBE in src/common/utils.cpp), so the decoder is tested against the server's own layout.
--]]

local encode = {};

local function put(buf, pos, len, value)
    for i = 0, len - 1 do
        if (math.floor(value / 2 ^ i) % 2 == 1) then
            local index = math.floor((pos + i) / 8) + 1;
            buf[index] = buf[index] + 2 ^ ((pos + i) % 8);
        end
    end
    return pos + len;
end

--[[
* action = { actor, category, id, targets = { { id, results = { result, ... } }, ... } }
* result = { resolution, kind, animation, info, param, message,
*            proc = { kind, param, message } or nil, react = { kind, param, message } or nil }
--]]
function encode.action(action)
    local buf = {};
    for i = 1, 1024 do
        buf[i] = 0;
    end

    local pos = 40;
    pos = put(buf, pos, 32, action.actor);
    pos = put(buf, pos, 6, #action.targets);
    pos = put(buf, pos, 4, 0);
    pos = put(buf, pos, 4, action.category);
    pos = put(buf, pos, 32, action.id or 0);
    pos = put(buf, pos, 32, 0);

    for _, t in ipairs(action.targets) do
        pos = put(buf, pos, 32, t.id);
        pos = put(buf, pos, 4, #t.results);
        for _, r in ipairs(t.results) do
            pos = put(buf, pos, 3, r.resolution or 0);
            pos = put(buf, pos, 2, r.kind or 1);
            pos = put(buf, pos, 12, r.animation or 0);
            pos = put(buf, pos, 5, r.info or 0);
            pos = put(buf, pos, 2, 0);
            pos = put(buf, pos, 3, 0);
            pos = put(buf, pos, 17, r.param or 0);
            pos = put(buf, pos, 10, r.message or 0);
            pos = put(buf, pos, 31, 0);
            if (r.proc) then
                pos = put(buf, pos, 1, 1);
                pos = put(buf, pos, 6, r.proc.kind);
                pos = put(buf, pos, 4, 0);
                pos = put(buf, pos, 17, r.proc.param);
                pos = put(buf, pos, 10, r.proc.message);
            else
                pos = put(buf, pos, 1, 0);
            end
            if (r.react) then
                pos = put(buf, pos, 1, 1);
                pos = put(buf, pos, 6, r.react.kind);
                pos = put(buf, pos, 4, 0);
                pos = put(buf, pos, 14, r.react.param);
                pos = put(buf, pos, 10, r.react.message);
            else
                pos = put(buf, pos, 1, 0);
            end
        end
    end

    -- Packets are padded to a multiple of 4 bytes.
    local size = math.ceil(pos / 8);
    size = size + (4 - size % 4) % 4;
    local chars = {};
    for i = 1, size do
        chars[i] = string.char(buf[i]);
    end
    return table.concat(chars);
end

return encode;
