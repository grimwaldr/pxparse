addon.name    = 'pxparse';
addon.author  = 'Grimwald';
addon.version   = '0.5.2';
addon.desc    = 'Damage parser for Phoenix XI.';
addon.link    = 'https://github.com/grimwaldr/pxparse';

--[[
* Reads action packets (0x028) and battle messages (0x029) and adds up what the party does, fight
* by fight, plus your experience or limit points per hour (0x02D). Read only: it never blocks, changes or sends a packet; /pxp report only types into
* chat when you ask it to.
*
*   core/    decode, classify, parse, fights: plain Lua, tested offline (tests/run.lua)
*   world    party, pets and names from Ashita's memory
*   view     the window
*   ui       drawing helpers in the active theme
*   themes   Phoenix, Classic and Default
*   skin, gamefont   Classic's window art and the game's font, read from your game install
*   bitmapfont       DejaVu Mono, drawn from the atlases in fonts/
--]]

require('common');

local imgui    = require('imgui');
local settings = require('settings');
local decode   = require('core.decode');
local fights   = require('core.fights');
local exp      = require('core.exp');
local world    = require('world');
local ui       = require('ui');
local view     = require('view');
local themes   = require('themes');

local COLOR   = ui.COLOR;
local PADDING = ui.PADDING;

local default_settings = T{
    visible   = true,
    locked    = false,
    scale     = 1.0,
    alpha     = 0.94,
    x         = 440,
    y         = 300,
    tab       = 'damage',
    sc        = 'player',  -- skillchain damage: 'player' (the closer's), 'shared' (split between
                           -- opener and closer), 'bar' (its own bar) or 'off'
    partyonly = true,
    jobcolors = true,      -- names in their job's colour
    masknames = false,     -- names shown as jobs ("NIN"), for screenshots
    showids   = false,     -- every mob's hex id, not just where two share a name
    idle      = 6,         -- seconds without action before a fight ends (and its clock stops)
    maxbars   = 18,
    theme     = 'phoenix', -- 'phoenix', 'classic' (the game's window art and font) or 'default'
    wintype   = -1,        -- Classic's Window Type, 0-7; -1 follows the game's setting
    -- Text in the game's own font, per theme: on for Classic, which is built from the game's UI.
    -- The font per skin: 'mono' (DejaVu Mono, shipped with pxparse), 'game' (the game's own, read
    -- from your install) or 'ashita' (Ashita's ImGui font).
    font      = T{ phoenix = 'mono', classic = 'game', default = 'mono' },
};

local SC_MODES = { 'player', 'shared', 'bar', 'off' };
local SC_SAID  = {
    player = 'Skillchain damage counts for the closer.',
    shared = 'Skillchain damage is split between the opener and the closer.',
    bar    = 'Skillchain damage has its own bar.',
    off    = 'Skillchain damage is left out.',
};

local ctx = T{
    settings       = settings.load(default_settings),
    world          = world,
    reset_position = false,
    place_window   = true,
    pending        = T{},
    last_pos_save  = 0,
    reporting      = false,
};

world.partyonly = ctx.settings.partyonly;
local session = fights.new(world, { idle = ctx.settings.idle, limit = 20 });
ctx.exp = exp.new();
session:set_show_ids(ctx.settings.showids);

-----------------------------------
-- Settings and actions the view calls
-----------------------------------
function ctx.save()
    settings.save();
end

function ctx.reset()
    session:reset();
    ctx.exp:reset();
    view.fight = 'current';
    view.invalidate();
    ui.say('Parse cleared.');
end

function ctx.select_tab(key)
    if (ctx.settings.tab ~= key) then
        ctx.settings.tab = key;
        settings.save();
    end
end

function ctx.set_partyonly(on)
    ctx.settings.partyonly = on;
    world.partyonly = on;
    settings.save();
end

function ctx.toggle_jobcolors()
    ctx.settings.jobcolors = not ctx.settings.jobcolors;
    settings.save();
end

function ctx.toggle_mask()
    ctx.settings.masknames = not ctx.settings.masknames;
    settings.save();
end

function ctx.toggle_ids()
    ctx.settings.showids = not ctx.settings.showids;
    session:set_show_ids(ctx.settings.showids);
    view.invalidate();
    settings.save();
end

function ctx.set_sc(mode)
    ctx.settings.sc = mode;
    view.invalidate();
    settings.save();
end

function ctx.cycle_sc()
    for i, m in ipairs(SC_MODES) do
        if (m == ctx.settings.sc) then
            ctx.set_sc(SC_MODES[i % #SC_MODES + 1]);
            return;
        end
    end
    ctx.set_sc('player');
end

function ctx.set_theme(key)
    ctx.settings.theme = key;
    settings.save();
end

-- Classic's window type: the game's, then Type 1 to 8, then back to the game's.
function ctx.cycle_wintype()
    local t = ctx.settings.wintype + 1;
    ctx.settings.wintype = (t >= themes.WINDOW_TYPES) and -1 or t;
    settings.save();
end

-- The font per skin. Settings from before 0.5.2 held a game font on/off per skin instead: on
-- becomes the game font, off becomes Ashita's for Classic and DejaVu Mono for the others.
local function font_settings()
    local s = ctx.settings;
    if (s.gamefont ~= nil) then
        local old = s.gamefont;
        local on  = function (key)
            if (type(old) == 'table') then
                return old[key] == true;
            end
            return key == 'classic' and old ~= false;
        end
        s.font = T{
            phoenix = on('phoenix') and 'game' or 'mono',
            classic = on('classic') and 'game' or 'ashita',
            default = on('default') and 'game' or 'mono',
        };
        s.gamefont = nil;
        settings.save();
    end
    if (type(s.font) ~= 'table') then
        s.font = T{ phoenix = 'mono', classic = 'game', default = 'mono' };
    end
    return s.font;
end

function ctx.font()
    local f = font_settings()[ctx.settings.theme];
    return ui.FONT_NAMES[f] and f or (ctx.settings.theme == 'classic' and 'game' or 'mono');
end

function ctx.set_font(name)
    font_settings()[ctx.settings.theme] = name;
    settings.save();
end

-- DejaVu Mono, then the game's, then Ashita's.
function ctx.cycle_font()
    local now = ctx.font();
    for i, name in ipairs(ui.FONTS) do
        if (name == now) then
            ctx.set_font(ui.FONTS[i % #ui.FONTS + 1]);
            return;
        end
    end
    ctx.set_font(ui.FONTS[1]);
end

-- Saves once the slider is let go, so scale doesn't resize the window mid-drag.
local function setting_slider(id, key, low, high, format, step, width, live)
    imgui.SetNextItemWidth(width);
    local buffer = { ctx.pending[key] or ctx.settings[key] };
    if (imgui.SliderFloat(('##pxp_%s_%s'):fmt(id, key), buffer, low, high, format, ImGuiSliderFlags_AlwaysClamp)) then
        local value = math.floor(buffer[1] / step + 0.5) * step;
        if (live) then
            ctx.settings[key] = value;
        else
            ctx.pending[key] = value;
        end
    end
    if (imgui.IsItemDeactivatedAfterEdit()) then
        if (ctx.pending[key]) then
            ctx.settings[key] = ctx.pending[key];
            ctx.pending[key]  = nil;
        end
        settings.save();
    end
end

function ctx.settings_row(label, key, low, high, format, step, width, live)
    local indent = math.max(ui.text_width('Scale'), ui.text_width('Opacity')) + 8;
    imgui.AlignTextToFramePadding();
    imgui.TextColored(COLOR.muted, label);
    imgui.SameLine(PADDING + indent);
    setting_slider('panel', key, low, high, format, step, width - indent, live);
end

-----------------------------------
-- Window
-----------------------------------
local function draw_context_menu()
    if (not imgui.BeginPopupContextWindow()) then
        return;
    end
    if (imgui.MenuItem('Lock Window', nil, ctx.settings.locked)) then
        ctx.settings.locked = not ctx.settings.locked;
        settings.save();
    end
    if (imgui.MenuItem('Party Only', nil, ctx.settings.partyonly)) then
        ctx.set_partyonly(not ctx.settings.partyonly);
    end
    if (imgui.MenuItem('Hide Names', nil, ctx.settings.masknames)) then
        ctx.toggle_mask();
    end
    if (imgui.MenuItem('Show Mob IDs', nil, ctx.settings.showids)) then
        ctx.toggle_ids();
    end
    if (imgui.MenuItem('Job Colours', nil, ctx.settings.jobcolors)) then
        ctx.toggle_jobcolors();
    end
    if (imgui.MenuItem('Reset Parse')) then
        ctx.reset();
    end
    if (imgui.MenuItem('Reset Position')) then
        ctx.reset_position = true;
    end
    if (imgui.MenuItem('Hide')) then
        ctx.settings.visible = false;
        settings.save();
    end
    imgui.Separator();
    imgui.TextColored(COLOR.muted, 'Scale');
    setting_slider('menu', 'scale', 0.5, 3.0, '%.2f', 0.05, 160, false);
    imgui.TextColored(COLOR.muted, 'Opacity');
    setting_slider('menu', 'alpha', 0.3, 1.0, '%.2f', 0.01, 160, true);
    imgui.EndPopup();
end

local function remember_position()
    local x, y = ui.vec2(imgui.GetWindowPos());
    if (not x or not y) then
        return;
    end
    x, y = math.floor(x), math.floor(y);
    if (x == ctx.settings.x and y == ctx.settings.y) then
        return;
    end
    ctx.settings.x, ctx.settings.y = x, y;
    if (os.clock() - ctx.last_pos_save > 1.0) then
        ctx.last_pos_save = os.clock();
        settings.save();
    end
end

local function render()
    if (not ctx.settings.visible or not world.me()) then
        return;
    end
    if (ctx.reset_position) then
        ctx.settings.x, ctx.settings.y = default_settings.x, default_settings.y;
        ctx.reset_position = false;
        ctx.place_window   = true;
        settings.save();
    end

    local scale = ctx.settings.scale;
    local width = ui.BASE_WIDTH * scale;
    ui.use_theme(ctx.settings.theme, ctx.settings.wintype);
    ui.font = ctx.font();
    local colors, vars = ui.push_theme(ctx.settings.alpha);

    if (ctx.place_window) then
        imgui.SetNextWindowPos({ ctx.settings.x, ctx.settings.y }, ImGuiCond_Always);
        ctx.place_window = false;
    end

    local open = T{ true };
    if (imgui.Begin('pxparse##pxparse', open, ui.window_flags(ctx.settings.locked))) then
        local font      = imgui.GetFont();
        ui.font_base    = imgui.GetFontSize();
        local font_size = ui.font_base * scale;
        ui.window_art(ctx.settings.alpha);
        imgui.PushFont(font, font_size);
        view.draw(ctx, session, width, scale, font, font_size);
        draw_context_menu();
        remember_position();
        imgui.PopFont();
    end
    imgui.End();

    imgui.PopStyleVar(vars);
    imgui.PopStyleColor(colors);

    if (not open[1]) then
        ctx.settings.visible = false;
        settings.save();
    end
end

-----------------------------------
-- Duplicate packets
-----------------------------------
--[[
* The server can send a chunk again, and its packets come through twice. Thorny's method (as used
* by Metrics and parse): a packet is a repeat only if the previous chunk had the very same bytes.
* Comparing against just the last chunk, not a long history, means two genuinely identical attack
* rounds a few seconds apart are both counted.
--]]
local last_chunk, this_chunk, this_count = {}, {}, 0;

local function repeated(e)
    -- The first packet of a chunk sits at the start of the chunk's data.
    if ((e.chunk_data and e.size and e.chunk_data:sub(1, e.size) == e.data) or this_count > 256) then
        last_chunk, this_chunk, this_count = this_chunk, {}, 0;
    end
    if (e.id ~= 0x028 and e.id ~= 0x029 and e.id ~= 0x02D) then
        return false;
    end
    if (not this_chunk[e.data]) then
        this_chunk[e.data] = true;
        this_count = this_count + 1;
    end
    return last_chunk[e.data] == true;
end

-----------------------------------
-- Commands
-----------------------------------
local REPORT_GAP = 1.1;

local function report(args)
    local mode, n = nil, 4;
    for i = 3, #args do
        local a = args[i]:lower();
        if (a:match('^%d+$')) then
            n = math.min(18, tonumber(a));
        elseif (a == 's' or a == 'p' or a == 'l' or a == 'l2') then
            mode = a;
        else
            ui.warn('Usage: /pxp report [s|p|l|l2] [#]');
            return;
        end
    end
    local fmt   = { number = ui.number, duration = ui.duration, decimal = ui.decimal,
                    name = function (row) return view.display(ctx, row.id, row.name); end };
    local parser = session:pick(view.fight);
    if (not parser) then
        ui.warn('Nothing to report yet.');
        return;
    end
    view.meter(parser, ctx.settings.sc, ctx); -- so hidden names are numbered the same as on screen
    fmt.title = view.title(session, parser);
    local lines = parser:report_lines(view.filter, ctx.settings.sc, n, fmt);
    if (not mode) then
        for _, line in ipairs(lines) do
            ui.say(line);
        end
        return;
    end
    if (ctx.reporting) then
        ui.warn('Still sending the last report.');
        return;
    end
    ctx.reporting = true;
    for i, line in ipairs(lines) do
        ashita.tasks.once(REPORT_GAP * (i - 1), function ()
            AshitaCore:GetChatManager():QueueCommand(1, ('/%s %s'):fmt(mode, line));
            if (i == #lines) then
                ctx.reporting = false;
            end
        end);
    end
end

local function export()
    local folder = ('%s\\config\\addons\\%s\\'):fmt(AshitaCore:GetInstallPath(), addon.name);
    if (not ashita.fs.exists(folder)) then
        ashita.fs.create_directory(folder);
    end
    local parser = session:pick(view.fight);
    if (not parser) then
        ui.warn('Nothing to export yet.');
        return;
    end
    local file_name = ('%s %s.csv'):fmt(os.date('%Y-%m-%d %H-%M-%S'), (view.title(session, parser):gsub('[^%w %+]', '')));
    local f = io.open(folder .. file_name, 'w');
    if (not f) then
        ui.warn('Couldn\'t write the export.');
        return;
    end
    f:write(parser:csv(view.filter));
    f:close();
    ui.say(('Saved config\\addons\\pxparse\\%s'):fmt(file_name));
end

local function help()
    ui.say('/pxp - show or hide the window');
    ui.say('/pxp reset - clear every fight, and the EXP rate');
    ui.say('/pxp report [s|p|l|l2] [#] - top # (4 by default) to say, party or linkshell; alone, just to you');
    ui.say('/pxp sc [player|shared|bar|off] - skillchain damage: the closer\'s, split with the opener, its own bar, or left out');
    ui.say('/pxp jobs - names in job colours, on or off');
    ui.say('/pxp ids - show every mob\'s ID, or only when two mobs share a name');
    ui.say('/pxp mask - hide names (shown as jobs, also in reports), or show them again');
    ui.say('/pxp party - count only your party and alliance, or everyone nearby');
    ui.say('/pxp scale <0.5-3> - window size');
    ui.say('/pxp theme [phoenix|classic|default] - the look; Classic uses the game\'s window art and font');
    ui.say('/pxp wintype [1-8|game] - Classic\'s window type, or follow the game\'s setting');
    ui.say('/pxp font [mono|game|ashita] - the font for this skin: DejaVu Mono, the game\'s, or Ashita\'s; alone, the next one');
    ui.say('/pxp export - save the parse as a CSV in config\\addons\\pxparse');
end

ashita.events.register('command', 'pxparse_command', function (e)
    local args = e.command:args();
    if (#args == 0) then
        return;
    end
    local command = args[1]:lower();
    if (command ~= '/pxp' and command ~= '/pxparse') then
        return;
    end
    e.blocked = true;

    local sub = (args[2] or ''):lower();
    if (sub == '') then
        ctx.settings.visible = not ctx.settings.visible;
        settings.save();
    elseif (sub == 'show' or sub == 'hide') then
        ctx.settings.visible = sub == 'show';
        settings.save();
    elseif (sub == 'reset') then
        ctx.reset();
    elseif (sub == 'report') then
        report(args);
    elseif (sub == 'sc') then
        local mode = (args[3] or ''):lower();
        if (mode == '') then
            ctx.cycle_sc();
        elseif (SC_SAID[mode]) then
            ctx.set_sc(mode);
        elseif (mode == 'closer' or mode == 'split') then
            ctx.set_sc(mode == 'closer' and 'player' or 'shared');
        else
            ui.warn('Usage: /pxp sc player|shared|bar|off');
            return;
        end
        ui.say(SC_SAID[ctx.settings.sc]);
    elseif (sub == 'debug') then
        for _, line in ipairs(world.debug_jobs()) do
            ui.say(line);
        end
    elseif (sub == 'mask' or sub == 'names') then
        ctx.toggle_mask();
        ui.say(ctx.settings.masknames and 'Names hidden: shown as jobs.' or 'Names shown.');
    elseif (sub == 'ids') then
        ctx.toggle_ids();
        ui.say(ctx.settings.showids and 'Every mob shows its ID.' or 'Mob IDs only show when two mobs share a name.');
    elseif (sub == 'jobs' or sub == 'jobcolors' or sub == 'jobcolours') then
        ctx.toggle_jobcolors();
        ui.say(ctx.settings.jobcolors and 'Names in job colours.' or 'Job colours off.');
    elseif (sub == 'party') then
        ctx.set_partyonly(not ctx.settings.partyonly);
        ui.say(ctx.settings.partyonly and 'Counting your party and alliance.' or 'Counting every player nearby.');
    elseif (sub == 'scale') then
        local scale = tonumber(args[3]);
        if (not scale) then
            ui.warn('Usage: /pxp scale <0.5-3>');
            return;
        end
        ctx.settings.scale = math.min(3.0, math.max(0.5, scale));
        settings.save();
    elseif (sub == 'export') then
        export();
    elseif (sub == 'theme') then
        local key = args[3] and themes.find(args[3]);
        if (args[3] and not key) then
            ui.warn('Usage: /pxp theme phoenix|classic|default');
            return;
        end
        if (not key) then
            -- Alone: the next theme.
            for i, k in ipairs(themes.ORDER) do
                if (k == ctx.settings.theme) then
                    key = themes.ORDER[i % #themes.ORDER + 1];
                end
            end
        end
        ctx.set_theme(key or 'phoenix');
        ui.say(('Theme: %s.'):fmt(themes.NAMES[ctx.settings.theme]));
    elseif (sub == 'wintype' or sub == 'window') then
        local value = (args[3] or ''):lower();
        local n     = tonumber(value);
        if (value == 'game' or value == '') then
            ctx.settings.wintype = -1;
        elseif (n and n >= 1 and n <= themes.WINDOW_TYPES) then
            ctx.settings.wintype = math.floor(n) - 1;
        else
            ui.warn('Usage: /pxp wintype 1-8|game');
            return;
        end
        settings.save();
        ui.say(ctx.settings.wintype < 0 and 'Classic follows the game\'s window type.'
            or ('Classic uses window Type %d.'):fmt(ctx.settings.wintype + 1));
    elseif (sub == 'font') then
        local want = (args[3] or ''):lower();
        local alias = { mono = 'mono', dejavu = 'mono', game = 'game', ffxi = 'game', ashita = 'ashita', agave = 'ashita' };
        if (want == '') then
            ctx.cycle_font();
        elseif (alias[want]) then
            ctx.set_font(alias[want]);
        else
            ui.warn('Usage: /pxp font [mono|game|ashita]');
            return;
        end
        ui.say(('%s: %s font.'):fmt(themes.NAMES[ctx.settings.theme] or 'Skin', ui.FONT_NAMES[ctx.font()]));
    else
        help();
    end
end);

-----------------------------------
-- Events
-----------------------------------
-- Categories that start an action carry no results worth reading.
local SKIP = { [0] = true, [7] = true, [8] = true, [9] = true, [10] = true, [12] = true };

ashita.events.register('packet_in', 'pxparse_packet_in', function (e)
    if (e.injected) then
        return;
    end
    if (repeated(e)) then
        return;
    end
    if (e.id == 0x00A) then
        world.forget(); -- zoned: entity indexes change, and the fight is over
        session:tick(true);
        return;
    end
    if (e.id == 0x029) then
        session:defeat(decode.message(e.data));
        return;
    end
    if (e.id == 0x02D) then
        local points = decode.points(e.data);
        if (points and points.actor == world.me()) then
            ctx.exp:gain(points, os.clock(), world.level());
        end
        return;
    end
    if (e.id ~= 0x028) then
        return;
    end
    local _, category = decode.peek(e.data);
    if (SKIP[category]) then
        return;
    end
    session:action(decode.action(e.data));
end);

ashita.events.register('d3d_present', 'pxparse_present', function ()
    session:tick();
    render();
end);

ashita.events.register('unload', 'pxparse_unload', function ()
    settings.save();
    ui.release();
end);

settings.register('settings', 'pxparse_settings_update', function (s)
    if (s) then
        ctx.settings = s;
    end
    world.partyonly = ctx.settings.partyonly;
    session:set_idle(ctx.settings.idle);
    session:set_show_ids(ctx.settings.showids);
    ctx.place_window = true;
    view.invalidate();
    settings.save();
end);
