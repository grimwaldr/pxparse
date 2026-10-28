--[[
* pxparse - view
* The window. Closed, it's just the meter: a row of dropdowns (which fight, which mobs) with the
* hide-names and gear buttons, the bars, and a footer line or two. The gear opens the rest as tabs:
* Damage (the meter with its Accuracy and Experience sections), Detail (one player's sources), Log
* (recent results, and messages pxparse doesn't recognise yet) and Settings.
--]]

require('common');

local imgui = require('imgui');
local ui    = require('ui');
local parse  = require('core.parse');
local themes = require('themes');

local COLOR         = ui.COLOR;
local PADDING       = ui.PADDING;
local text_width    = ui.text_width;
local right_text    = ui.right_text;
local stat_cell     = ui.stat_cell;
local toggle_button = ui.toggle_button;
local fmt_number    = ui.number;
local fmt_percent   = ui.percent;

local COG           = ICON_FA_GEAR or 'Set';
local COG_CODEPOINT = 0xF013;
-- The hide-names button: an eye, crossed out while names are hidden.
local EYE           = { on = ICON_FA_EYE_SLASH or 'Hide', off = ICON_FA_EYE or 'Show' };
local EYE_CODEPOINT = { on = 0xF070, off = 0xF06E };

local TABS = {
    { key = 'damage',   label = 'Damage' },
    { key = 'detail',   label = 'Detail' },
    { key = 'log',      label = 'Log' },
    { key = 'settings', label = 'Settings' },
};

local SC_LABELS = {
    player = 'Skillchains: closer',
    shared = 'Skillchains: shared',
    bar    = 'Skillchains: own bar',
    off    = 'Skillchains: off',
};

-- Source colours by kind, from the theme's accents.
local KIND_COLOR = {
    ws     = COLOR.secondary,
    ja     = COLOR.secondary,
    magic  = COLOR.peach,
    sc     = COLOR.gold,
    pet    = COLOR.ember,
    react  = COLOR.muted,
    add    = COLOR.muted,
};

local view = {
    expanded      = false,     -- the gear: tabs shown
    fight         = 'current', -- 'current', 'overall', or a kept fight
    filter        = parse.ALL_MOBS,
    selected      = nil,       -- server id shown on the Detail tab
    cache         = nil,       -- the meter, rebuilt a few times a second
    cache_at      = -1,
    cache_version = -1,
    cache_key     = '',
    masked        = {},        -- [server id] = "NIN", "NIN (2)"... while names are hidden
};

local REBUILD = 0.25;

-- A player's name colour, and the outline it needs if any: their job's with job colours on,
-- otherwise `plain` (peach for you).
local function name_color(ctx, id, plain)
    if (ctx.settings.jobcolors) then
        local job = ctx.world.job(id) or 0;
        return ui.JOB_COLOR[job] or ui.JOB_COLOR[0], ui.JOB_OUTLINE[job];
    end
    if (id == ctx.world.me()) then
        return COLOR.peach;
    end
    return plain or COLOR.text;
end

-- "COR" (main job only; levels say little with level sync), or nil when the job isn't known.
local function job_label(ctx, id)
    local job = ctx.world.job(id);
    if (not job or job == 0) then
        return nil;
    end
    return ui.JOB_ABBR[job] or '?';
end

-- The job a hidden name shows as, or "Player" when the job isn't known.
local function mask_label(ctx, id)
    return job_label(ctx, id) or 'Player';
end

-- Hidden names for the meter's rows, numbered in rank order when two share a job.
local function build_masks(ctx, meter)
    local seen = {};
    view.masked = {};
    for _, row in ipairs(meter.rows) do
        if (not row.sc_row) then
            local label = mask_label(ctx, row.id);
            seen[label] = (seen[label] or 0) + 1;
            view.masked[row.id] = seen[label] > 1 and ('%s (%d)'):fmt(label, seen[label]) or label;
        end
    end
end

-- A player's name as shown: their own, or their job while names are hidden.
function view.display(ctx, id, name)
    if (not ctx.settings.masknames or id == 0) then
        return name;
    end
    return view.masked[id] or mask_label(ctx, id);
end

-----------------------------------
-- Data
-----------------------------------
function view.meter(p, sc, ctx)
    local now = os.clock();
    local key = tostring(p) .. '|' .. view.filter .. '|' .. sc;
    if (view.cache and key == view.cache_key and
        (p.version == view.cache_version or now - view.cache_at < REBUILD)) then
        return view.cache;
    end
    view.cache         = p:view(view.filter, sc);
    if (ctx) then
        build_masks(ctx, view.cache);
    end
    view.cache_at      = now;
    view.cache_version = p.version;
    view.cache_key     = key;
    return view.cache;
end

function view.invalidate()
    view.cache = nil;
end

-- The fight (and mob, when one is picked) a report or export is about.
function view.title(session, p)
    local base = (p == session.overall and 'Overall') or (p.top and session:name(p)) or 'Current fight';
    if (view.filter ~= parse.ALL_MOBS) then
        return ('%s, %s'):fmt(base, p:filter_label(view.filter));
    end
    return base;
end

-- Opens the gear on a tab.
function view.open(ctx, tab)
    view.expanded = true;
    ctx.select_tab(tab);
end

-----------------------------------
-- Top row: dropdowns, eye, gear
-----------------------------------
-- An icon button: no frame until hovered, filled while on. The glyph is centred on its drawn
-- bounds, since its advance width would leave it off-centre as a label.
local function icon_button(id, on, glyph_text, codepoint, w)
    imgui.PushStyleColor(ImGuiCol_Button, on and COLOR.royal or COLOR.clear);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, on and COLOR.hover or COLOR.tint);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR.royal);
    local clicked = imgui.Button(id, { w, 0 });
    imgui.PopStyleColor(3);
    local x0, y0  = ui.vec2(imgui.GetItemRectMin());
    local x1, y1  = ui.vec2(imgui.GetItemRectMax());
    ui.glyph_at(imgui.GetWindowDrawList(), codepoint, glyph_text, (x0 + x1) / 2, (y0 + y1) / 2,
        on and COLOR.text or COLOR.muted);
    return clicked;
end

-- What the fight dropdown says: "Current fight" while one's on, the last fight's name between them.
local function fight_label(session)
    if (view.fight == 'current' and not session.current and session.history[1]) then
        return session:name(session.history[1], true);
    end
    if (type(view.fight) == 'table') then
        return session:name(view.fight, true);
    end
    return session:label(view.fight);
end

local function fight_popup(session)
    if (not imgui.BeginPopup('##pxp_fight_popup')) then
        return;
    end
    if (imgui.Selectable('Latest fight##pxp_fight_current', view.fight == 'current')) then
        view.fight = 'current';
    end
    if (imgui.Selectable('Overall##pxp_fight_overall', view.fight == 'overall')) then
        view.fight = 'overall';
    end
    if (#session.history > 0) then
        imgui.Separator();
    end
    for i, fight in ipairs(session.history) do
        local label = ('%s  %s##pxp_fight_%d'):fmt(session:name(fight), ui.duration(fight.active), fight.number or i);
        if (imgui.Selectable(label, view.fight == fight)) then
            view.fight = fight;
        end
    end
    imgui.EndPopup();
end

local function mob_popup(p)
    if (not imgui.BeginPopup('##pxp_mob_popup')) then
        return;
    end
    for _, c in ipairs(p:mob_choices()) do
        local label = ('%s%s##pxp_mob_%s'):fmt(c.indent and '   ' or '', c.label, c.filter);
        if (imgui.Selectable(label, c.filter == view.filter)) then
            view.filter = c.filter;
        end
    end
    imgui.EndPopup();
end

local function draw_top(ctx, session, p, width, scale)
    local masked = ctx.settings.masknames;
    local state  = masked and 'on' or 'off';
    local btn_w  = math.max(text_width(COG), text_width(EYE.on), text_width(EYE.off)) + 10 * scale;
    local room   = width - 2 * btn_w - 16;

    -- The Log and Settings tabs don't use the mob filter, so it's left off there.
    local mobs = p and not (view.expanded and (ctx.settings.tab == 'log' or ctx.settings.tab == 'settings'));
    if (p and not p:filter_valid(view.filter)) then
        view.filter = parse.ALL_MOBS;
    end

    if (not p) then
        ui.text(COLOR.muted, 'Waiting for a fight', true);
    else
        local fight = fight_label(session);
        local mob   = mobs and p:filter_label(view.filter) or nil;
        -- Each gets what it needs; when both don't fit, they split the room.
        local extra  = text_width(' ' .. ui.CARET) + 12;
        local need_f = text_width(fight) + extra;
        local need_m = mob and (text_width(mob) + extra) or 0;
        local room_f, room_m = room, room;
        if (mob and need_f + need_m + 4 > room) then
            room_f = math.max(room / 2, room - need_m - 4);
            room_m = room - math.min(need_f, room_f) - 4;
        end
        if (ui.dropdown('pxp_fight', fight, COLOR.peach, room_f)) then
            imgui.OpenPopup('##pxp_fight_popup');
        end
        fight_popup(session);
        if (mob) then
            imgui.SameLine(0, 4);
            if (ui.dropdown('pxp_mob', mob, COLOR.secondary, room_m)) then
                imgui.OpenPopup('##pxp_mob_popup');
            end
            mob_popup(p);
        end
    end

    imgui.SameLine(PADDING + width - 2 * btn_w - 4);
    if (icon_button('##pxp_mask', masked, EYE[state], EYE_CODEPOINT[state], btn_w)) then
        ctx.toggle_mask();
    end
    if (imgui.IsItemHovered()) then
        ui.tooltip({ masked and 'Names hidden: shown as jobs. Click to show them.'
            or 'Hide names (show jobs instead), for screenshots' }, COLOR.secondary);
    end

    imgui.SameLine(PADDING + width - btn_w);
    if (icon_button('##pxp_gear', view.expanded, COG, COG_CODEPOINT, btn_w)) then
        view.expanded = not view.expanded;
    end
    if (imgui.IsItemHovered()) then
        ui.tooltip({ view.expanded and 'Back to just the meter' or 'Detail, log and settings' }, COLOR.secondary);
    end
end

local function draw_tabs(ctx, width, scale)
    imgui.Dummy({ 0, 2 * scale });
    local labels, states, keys = {}, {}, {};
    for i, tab in ipairs(TABS) do
        labels[i], states[i], keys[i] = tab.label, ctx.settings.tab == tab.key, tab.key;
    end
    local clicked = ui.button_row('pxp_tab', labels, states, width);
    if (clicked) then
        ctx.select_tab(keys[clicked]);
    end
    imgui.Dummy({ 0, 2 * scale });
end

-----------------------------------
-- Settings
-----------------------------------
local function draw_settings(ctx, width)
    local s = ctx.settings;
    imgui.Spacing();
    ctx.settings_row('Scale', 'scale', 0.5, 3.0, '%.2f', 0.05, width, false);
    ctx.settings_row('Opacity', 'alpha', 0.3, 1.0, '%.2f', 0.01, width, true);
    imgui.Spacing();

    -- Theme: Phoenix, Classic (the game's window art and font) or Default (plain ImGui).
    local labels, states = {}, {};
    for i, key in ipairs(themes.ORDER) do
        labels[i], states[i] = themes.NAMES[key], s.theme == key;
    end
    local picked = ui.button_row('pxp_theme', labels, states, width);
    if (picked) then
        ctx.set_theme(themes.ORDER[picked]);
    end
    -- The game's own letters, read from your install: on for Classic, and a toggle on any theme.
    local game_font = ctx.game_font();
    if (s.theme == 'classic') then
        local window = s.wintype >= 0 and ('Window: Type %d'):fmt(s.wintype + 1)
            or ('Window: game (Type %d)'):fmt((ui.theme.skin or 0) + 1);
        picked = ui.button_row('pxp_classic', { 'Game font', window }, { game_font, s.wintype >= 0 }, width);
        if (picked == 1) then
            ctx.toggle_gamefont();
        elseif (picked == 2) then
            ctx.cycle_wintype();
        end
        if (imgui.IsItemHovered()) then
            ui.tooltip({
                'Click to pick a Window Type, or follow the game\'s',
                '(Config > Windows > Shared > Window Type).',
            }, COLOR.secondary);
        end
    else
        if (ui.toggle_button('Game font##pxp_font', game_font, width)) then
            ctx.toggle_gamefont();
        end
        if (imgui.IsItemHovered()) then
            ui.tooltip({
                'Text in the game\'s own font, read from your install',
                '(used at scale 1). Classic has it on by default.',
            }, COLOR.secondary);
        end
    end

    local clicked = ui.button_row('pxp_win', { 'Lock', 'Reset Position', 'Reset Parse' }, { s.locked, false, false }, width);
    if (clicked == 1) then
        s.locked = not s.locked;
        ctx.save();
    elseif (clicked == 2) then
        ctx.reset_position = true;
    elseif (clicked == 3) then
        ctx.reset();
    end

    clicked = ui.button_row('pxp_opts', { 'Party only', 'Job colours', 'Mob IDs' },
        { s.partyonly, s.jobcolors, s.showids }, width);
    if (clicked == 1) then
        ctx.set_partyonly(not s.partyonly);
    elseif (clicked == 2) then
        ctx.toggle_jobcolors();
    elseif (clicked == 3) then
        ctx.toggle_ids();
    end
    if (imgui.IsItemHovered()) then
        ui.tooltip({
            'Mob IDs on: every mob shows its ID, like Goblin Ambusher [1A3].',
            'Off: IDs only show when two mobs share a name, to tell them apart.',
        }, COLOR.secondary);
    end

    -- One button that steps through the modes: closer, shared, own bar, off.
    if (toggle_button(SC_LABELS[s.sc] .. '##pxp_sc', s.sc ~= 'off', width)) then
        ctx.cycle_sc();
    end
    if (imgui.IsItemHovered()) then
        ui.tooltip({
            'Click to change where skillchain damage goes:',
            'closer: all of it to whoever closed the chain',
            'shared: half to the closer, half to whoever opened that step',
            'own bar: a Skillchains bar of its own',
            'off: left out of the totals',
        }, COLOR.secondary);
    end
end

-----------------------------------
-- Meter: bars and footer
-----------------------------------
local function accuracy(acc)
    return fmt_percent(acc.hits, acc.attempts);
end

-- Ember under 80% (worth a look at gear or food), plain otherwise; nil for stat_cell's default.
local function acc_color(acc, cell)
    if (acc.attempts > 0 and acc.hits / acc.attempts < 0.8) then
        return COLOR.ember;
    end
    return (not cell) and COLOR.text or nil;
end

local function draw_bars(ctx, width, scale, meter)
    if (#meter.rows == 0) then
        ui.note(width, COLOR.faint, 'Nothing yet. Damage from your party (and their pets) shows up here as you fight.');
        return;
    end

    local my_id = ctx.world.me();
    local deep  = ctx.settings.jobcolors;
    local top   = meter.rows[1].total;
    local h     = imgui.GetTextLineHeight() + 6 * scale;

    -- Up to maxbars rows; when you're further down, you take the last one.
    local shown = {};
    for i, row in ipairs(meter.rows) do
        if (i <= ctx.settings.maxbars) then
            shown[#shown + 1] = { rank = i, row = row };
        elseif (row.id == my_id) then
            shown[#shown] = { rank = i, row = row };
        end
    end

    for _, item in ipairs(shown) do
        local i, row = item.rank, item.row;
        if (row.total > 0) then
            local color;
            if (row.sc_row) then
                color = deep and COLOR.gold_deep or COLOR.gold;
            else
                color = deep and COLOR.bar_deep or COLOR.royal;
            end
            local name  = row.sc_row and row.name or view.display(ctx, row.id, row.name);
            local left  = ('%d. %s'):fmt(i, name);
            local left_color, left_outline = COLOR.text, nil;
            if (not row.sc_row) then
                left_color, left_outline = name_color(ctx, row.id);
            end
            -- With job colours on your name isn't peach any more, so your bar gets an outline.
            local outline = (deep and row.id == my_id) and COLOR.peach or nil;
            local clicked, hovered = ui.meter_bar(('##pxp_bar_%s'):fmt(tostring(row.id)), width, h,
                top > 0 and row.total / top or 0, color, left, fmt_number(row.total), left_color, outline,
                left_outline, fmt_percent(row.share, 1));
            if (clicked and not row.sc_row) then
                view.selected = row.id;
                view.open(ctx, 'detail');
            end
            if (hovered) then
                local lines = { ('%s: %s damage, %s DPS'):fmt(name, fmt_number(row.total), ui.decimal(row.dps)) };
                if (not row.sc_row) then
                    lines[2] = 'Click for where it came from';
                end
                ui.tooltip(lines, COLOR.secondary);
            end
        end
    end
end

-- "● 3m 01s    1,918    29.0 DPS    2 kills": spread across the line, the dot green while the
-- fight's on. On a narrow window or a wide font the total goes first, then kills.
local function draw_footer(ctx, width, meter, live)
    imgui.Dummy({ 0, 1 });
    local kills = meter.kills or 0;
    ui.spread('fight', {
        { ui.duration(meter.active), COLOR.muted, 1, dot = live and COLOR.success or COLOR.faint },
        { fmt_number(meter.total), COLOR.muted, 3 },
        { ('%s DPS'):fmt(ui.decimal(meter.dps)), COLOR.muted, 1 },
        { kills == 1 and '1 kill' or ('%d kills'):fmt(kills), COLOR.muted, 2 },
    }, width);
end

-- The experience summary, or nil before any gain.
local function exp_summary(ctx)
    -- Whole seconds: the rate, time to level and chain timer then change once a second, not
    -- every frame, so the figures read steadily.
    local now   = math.floor(os.clock());
    local probe = ctx.exp:summary(now);
    if (not probe) then
        return nil;
    end
    local have, need = ctx.world.progress(probe.kind);
    local left       = (have and need) and math.max(0, need - have) or nil;
    return ctx.exp:summary(now, left), have, need, left;
end

--[[
* The chain countdown: "Chain #2 2:41", green with over half the window left, gold under half,
* orange under a quarter (time to pull). After a plain kill with no chain running, the timer is
* for a chain that may have started (it did if the mob was Even Match or tougher), shown muted.
* Returns text, colour and the share of the window left, or nil when no window is open.
--]]
local function chain_state(x)
    if (not x or not x.chain_left) then
        return nil;
    end
    local share = x.chain_window and x.chain_window > 0 and (x.chain_left / x.chain_window) or 0;
    if (not x.chain_sure) then
        return ('Chain %s'):fmt(ui.clock(x.chain_left)), COLOR.muted, share;
    end
    local color = (share > 0.5 and COLOR.success) or (share > 0.25 and COLOR.gold) or COLOR.ember;
    return ('Chain #%d %s'):fmt(x.chain, ui.clock(x.chain_left)), color, share;
end

-- The closed window's EXP line: "21.1k exp/hr   Chain #2 2:41   4m 55s to lvl   575 exp".
local function draw_exp_footer(ctx, width)
    local x = exp_summary(ctx);
    if (not x) then
        return;
    end
    local limit = x.kind == 'limit';
    local unit  = limit and 'lp' or 'exp';
    local chain, chain_color = chain_state(x);
    ui.spread('exp', {
        { ('%s %s/hr'):fmt(ui.compact(x.rate), unit), COLOR.muted, 1 },
        { chain, chain_color, 1 },
        { x.eta and ('%s to %s'):fmt(ui.duration(x.eta), limit and 'merit' or 'lvl') or nil, COLOR.muted, 2 },
        { ('%s %s'):fmt(fmt_number(x.total), unit), COLOR.muted, 3 },
    }, width);
end

-----------------------------------
-- Damage tab sections
-----------------------------------
local TABLE_FLAGS = bit.bor(ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerH, ImGuiTableFlags_PadOuterX);

local function fixed_column(label, sample, scale)
    imgui.TableSetupColumn(label, ImGuiTableColumnFlags_WidthFixed,
        math.max(text_width(label), text_width(sample)) + 4 * scale, 0);
end

local function draw_accuracy(ctx, width, scale, meter)
    if (#meter.rows == 0) then
        return;
    end
    imgui.Spacing();
    if (not ui.section('accuracy', 'Accuracy', {
        'Acc% is melee, RAcc% ranged; under 80% shows in orange.',
        'Parried, countered and shadowed swings count as hits:',
        'Phoenix rolls to hit first. Perfect Dodge is left out.',
    }, width)) then
        return;
    end
    if (imgui.BeginTable('##pxp_acc', 5, TABLE_FLAGS, { width, 0 })) then
        imgui.TableSetupColumn('Name', ImGuiTableColumnFlags_WidthStretch, 0, 0);
        fixed_column('Acc%', '100%', scale);
        fixed_column('RAcc%', '100%', scale);
        fixed_column('Crit', '100%', scale);
        fixed_column('Taken', '99,999', scale);
        ui.header_row({ { 'Name' }, { 'Acc%', true }, { 'RAcc%', true }, { 'Crit', true }, { 'Taken', true } });
        for _, row in ipairs(meter.rows) do
            local m = row.data;
            if (m) then
                imgui.TableNextRow();
                imgui.TableNextColumn();
                local c, o = name_color(ctx, row.id, COLOR.secondary);
                ui.cell_text(c, view.display(ctx, row.id, row.name), o);
                imgui.TableNextColumn();
                ui.cell_right(acc_color(m.melee), accuracy(m.melee));
                imgui.TableNextColumn();
                ui.cell_right(acc_color(m.ranged), accuracy(m.ranged));
                imgui.TableNextColumn();
                ui.cell_right(COLOR.text, fmt_percent(m.melee.crits, m.melee.hits));
                imgui.TableNextColumn();
                ui.cell_right(COLOR.muted, m.taken > 0 and fmt_number(m.taken) or '-');
            end
        end
        imgui.EndTable();
    end
end

local function draw_experience(ctx, width, scale)
    local x, have, need, left = exp_summary(ctx);
    if (not x) then
        return;
    end
    local limit = x.kind == 'limit';
    local unit  = limit and 'LP' or 'EXP';

    imgui.Spacing();
    if (not ui.section('experience', limit and 'Limit Points' or 'Experience',
        { 'Rate over the last 10 minutes.', 'Chain is your current experience chain.' }, width)) then
        return;
    end

    -- Progress to the next level or merit point.
    if (have and need) then
        imgui.ProgressBar(math.min(1, have / need), { width, 8 * scale }, '');
        ui.text(COLOR.secondary, ('%s / %s %s'):fmt(fmt_number(have), fmt_number(need), unit));
        right_text(width, COLOR.muted, ('%s to %s'):fmt(fmt_number(left), limit and 'merit' or 'level'));
    end

    if (imgui.BeginTable('##pxp_exp', 4, ImGuiTableFlags_SizingStretchSame, { width, 0 })) then
        stat_cell(('%s/hr'):fmt(unit), fmt_number(x.rate), COLOR.success);
        stat_cell(limit and 'Merit in' or 'Level in', x.eta and ui.duration(x.eta) or '-');
        stat_cell('Gained', fmt_number(x.total));
        local chain, chain_color = chain_state(x);
        stat_cell('Chain', chain and (chain:gsub('^Chain ', '')) or '-', chain_color);
        imgui.EndTable();
    end
    -- The chain window running down, so you can see at a glance when to pull.
    local _, color, share = chain_state(x);
    if (share) then
        local cx, cy = ui.vec2(imgui.GetCursorScreenPos());
        local list   = imgui.GetWindowDrawList();
        local h      = math.max(3, math.floor(3 * scale + 0.5));
        list:AddRectFilled({ cx, cy }, { cx + width, cy + h }, imgui.GetColorU32(COLOR.surface2), h / 2);
        list:AddRectFilled({ cx, cy }, { cx + width * math.max(0, math.min(1, share)), cy + h }, imgui.GetColorU32(color), h / 2);
        imgui.Dummy({ width, h });
        if (imgui.IsItemHovered()) then
            ui.tooltip({
                'Time left to keep your EXP chain going.',
                'After a plain kill it shows the window a chain may have',
                'started: it did if that mob was Even Match or tougher.',
            }, COLOR.secondary);
        end
    end
end

-----------------------------------
-- Detail
-----------------------------------
-- The font's ascent as a share of its size, for lining up text of two sizes on one baseline.
local function ascent_ratio()
    local ok, ratio = pcall(function ()
        local baked = imgui.GetFontBaked();
        return baked.Ascent / imgui.GetFontSize();
    end);
    return (ok and type(ratio) == 'number' and ratio > 0) and ratio or 0.8;
end

--[[
* A big figure with small text beside it, all on one baseline;
* `right` (with `right_color`) goes at the right edge on that baseline too.
--]]
local function big_figure(font, font_size, width, value, side, right, right_color)
    local top = imgui.GetCursorPosY();
    imgui.PushFont(font, font_size * 1.8);
    local big = imgui.GetFontSize();
    ui.text(COLOR.text, value);
    imgui.PopFont();
    local small = imgui.GetFontSize();
    local drop  = math.floor((big - small) * ascent_ratio() + 0.5);
    imgui.SameLine();
    imgui.SetCursorPosY(top + drop);
    ui.text(COLOR.muted, side);
    if (right) then
        imgui.SameLine(PADDING + width - text_width(right));
        imgui.SetCursorPosY(top + drop);
        ui.text(right_color, right);
    end
end

local function who_popup(ctx, meter)
    if (not imgui.BeginPopup('##pxp_who_popup')) then
        return;
    end
    for _, row in ipairs(meter.rows) do
        if (not row.sc_row) then
            local c = name_color(ctx, row.id, COLOR.text);
            imgui.PushStyleColor(ImGuiCol_Text, c);
            local label = ('%s##pxp_who_%s'):fmt(view.display(ctx, row.id, row.name), tostring(row.id));
            if (imgui.Selectable(label, row.id == view.selected)) then
                view.selected = row.id;
            end
            imgui.PopStyleColor(1);
        end
    end
    imgui.EndPopup();
end

local function draw_detail(ctx, p, width, scale, font, font_size, meter)
    -- Default to yourself, then the top of the meter.
    if (not view.selected or not p.players[view.selected]) then
        view.selected = ctx.world.me();
        if (not p.players[view.selected or -1] and meter.rows[1] and not meter.rows[1].sc_row) then
            view.selected = meter.rows[1].id;
        end
    end

    local d = view.selected and p:detail(view.selected, view.filter);
    if (not d) then
        ui.note(width, COLOR.faint, 'Nobody to show yet. Click a bar once the fighting starts.');
        return;
    end

    -- Who: a text dropdown in their colour, with their job on the right.
    local c   = name_color(ctx, view.selected, COLOR.text);
    local job = job_label(ctx, view.selected);
    if (ui.dropdown('pxp_who', view.display(ctx, view.selected, d.name), c, width - 40)) then
        imgui.OpenPopup('##pxp_who_popup');
    end
    who_popup(ctx, meter);
    if (job and not ctx.settings.masknames) then
        right_text(width, COLOR.muted, job, true);
    end

    -- What this player's skillchains add, in the current mode.
    local sc, extra, extra_color = ctx.settings.sc, nil, COLOR.gold;
    if (sc == 'player' and d.sc > 0) then
        extra = ('+%s skillchain'):fmt(fmt_number(d.sc));
    elseif (sc == 'shared' and d.sc_share > 0) then
        extra = ('+%s SC share'):fmt(fmt_number(d.sc_share));
    elseif ((sc == 'bar' or sc == 'off') and d.sc > 0) then
        extra, extra_color = ('%s SC not in total'):fmt(fmt_number(d.sc)), COLOR.muted;
    end
    big_figure(font, font_size, width, fmt_number(d.damage), ('%s DPS'):fmt(ui.decimal(d.dps)), extra, extra_color);

    imgui.Spacing();
    if (imgui.BeginTable('##pxp_detail_stats', 4, ImGuiTableFlags_SizingStretchSame, { width, 0 })) then
        -- Active DPS is over the time this player was acting, which can be well under the fight's.
        stat_cell('Active DPS', ui.decimal(d.active_dps));
        stat_cell('Active', ui.duration(d.active));
        stat_cell('Taken', d.taken > 0 and fmt_number(d.taken) or '-', d.taken > 0 and COLOR.ember or nil);
        stat_cell('Kills', tostring(d.kills));
        stat_cell('Acc%', accuracy(d.melee), acc_color(d.melee, true));
        stat_cell('RAcc%', accuracy(d.ranged), acc_color(d.ranged, true));
        stat_cell('Crit rate', fmt_percent(d.melee.crits, d.melee.hits));
        stat_cell('SCs', (d.sc_closed + d.sc_opened > 0) and ('%d / %d'):fmt(d.sc_closed, d.sc_opened) or '-',
            d.sc_closed > 0 and COLOR.gold or nil);
        imgui.EndTable();
    end
    if (imgui.IsItemHovered()) then
        ui.tooltip({ 'SCs: skillchains closed / opened.', 'Active DPS: over the time this player was acting.' }, COLOR.secondary);
    end
    imgui.Spacing();

    if (not ui.section('sources', 'Sources', { 'Hover a source for max, min, accuracy, crits and bursts.' }, width)) then
        return;
    end
    if (#d.list == 0) then
        ui.text(COLOR.faint, 'No damage against this mob.');
        return;
    end

    local flags = TABLE_FLAGS;
    local size  = { width, 0 };
    if (#d.list > 12) then
        flags = bit.bor(flags, ImGuiTableFlags_ScrollY);
        size  = { width, 13 * imgui.GetTextLineHeightWithSpacing() };
    end
    if (imgui.BeginTable('##pxp_sources', 5, flags, size)) then
        imgui.TableSetupColumn('Source', ImGuiTableColumnFlags_WidthStretch, 0, 0);
        fixed_column('Total', '999,999', scale);
        fixed_column('%', '100%', scale);
        fixed_column('Hits', '999/999', scale);
        fixed_column('Avg', '9,999', scale);
        imgui.TableSetupScrollFreeze(0, 1);
        ui.header_row({ { 'Source' }, { 'Total', true }, { '%', true }, { 'Hits', true }, { 'Avg', true } });

        for _, s in ipairs(d.list) do
            imgui.TableNextRow();
            imgui.TableNextColumn();
            ui.cell_text(KIND_COLOR[s.kind] or COLOR.text, s.name);
            if (imgui.IsItemHovered()) then
                local lines = {
                    ('Max %s   Min %s'):fmt(fmt_number(s.max), s.min and fmt_number(s.min) or '-'),
                    ('Accuracy %s (%d of %d)'):fmt(fmt_percent(s.hits, s.hits + s.misses), s.hits, s.hits + s.misses),
                };
                if (s.crits > 0) then
                    lines[#lines + 1] = ('Crits %d (%s)'):fmt(s.crits, fmt_percent(s.crits, s.count));
                end
                if (s.bursts > 0) then
                    lines[#lines + 1] = ('Magic bursts %d'):fmt(s.bursts);
                end
                ui.tooltip(lines);
            end
            imgui.TableNextColumn();
            ui.cell_right(COLOR.text, fmt_number(s.total));
            imgui.TableNextColumn();
            ui.cell_right(COLOR.muted, fmt_percent(s.share, 1));
            imgui.TableNextColumn();
            ui.cell_right(s.misses > 0 and COLOR.secondary or COLOR.text,
                s.misses > 0 and ('%d/%d'):fmt(s.count, s.hits + s.misses) or tostring(s.count));
            imgui.TableNextColumn();
            ui.cell_right(COLOR.text, s.count > 0 and fmt_number(s.total / s.count) or '-');
        end
        imgui.EndTable();
    end
end

-----------------------------------
-- Log
-----------------------------------
local OUTCOME_COLOR = {
    crit = COLOR.gold, miss = COLOR.muted, resist = COLOR.muted, kill = COLOR.success,
    parried = COLOR.muted, shadow = COLOR.muted, anticipated = COLOR.muted, countered = COLOR.ember,
    dodged = COLOR.muted, deflected = COLOR.muted,
};

local function draw_log(ctx, p, width, scale)
    local recent = p:recent(60);
    if (#recent == 0) then
        ui.note(width, COLOR.faint, 'The last results pxparse counted show up here, newest first.');
    else
        local flags = bit.bor(TABLE_FLAGS, ImGuiTableFlags_ScrollY);
        local size  = { width, 14 * imgui.GetTextLineHeightWithSpacing() };
        if (imgui.BeginTable('##pxp_log', 3, flags, size)) then
            imgui.TableSetupColumn('Who', ImGuiTableColumnFlags_WidthFixed, text_width('Wwwwwwwwww') + 4 * scale, 0);
            imgui.TableSetupColumn('What', ImGuiTableColumnFlags_WidthStretch, 0, 0);
            fixed_column('Dmg', '99,999', scale);
            imgui.TableSetupScrollFreeze(0, 1);
            ui.header_row({ { 'Who' }, { 'What' }, { 'Dmg', true } });
            local now = os.clock();
            for _, e in ipairs(recent) do
                imgui.TableNextRow();
                imgui.TableNextColumn();
                local c, o = name_color(ctx, e.id, COLOR.peach);
                ui.cell_text(c, view.display(ctx, e.id, e.who), o);
                imgui.TableNextColumn();
                local outcome = (e.outcome ~= 'hit' and e.outcome ~= 'kill') and (' (%s)'):fmt(e.outcome) or '';
                local target = p:mob_display(e.mob);
                -- Which mob: named on a kill; otherwise just its hex id, and only when that's shown
                -- (two mobs share a name, or Mob IDs is on). The tag keeps its room; the action
                -- gives way.
                local hex = target:match('(%[%x+%])$');
                local tag = (e.outcome == 'kill') and target or hex;
                local room = ui.room() - (tag and (text_width(tag) + 8) or 0);
                ui.text(OUTCOME_COLOR[e.outcome] or COLOR.secondary, ui.fit(('%s%s'):fmt(e.what, outcome), math.max(30, room)));
                if (imgui.IsItemHovered()) then
                    ui.tooltip({ ('%s, %ds ago'):fmt(target, math.floor(now - e.t)) }, COLOR.secondary);
                end
                if (tag) then
                    imgui.SameLine();
                    ui.text(COLOR.muted, ui.fit(tag, math.max(20, ui.room())));
                    if (imgui.IsItemHovered()) then
                        ui.tooltip({ target }, COLOR.secondary);
                    end
                end
                imgui.TableNextColumn();
                local value = (e.outcome == 'hit' or e.outcome == 'crit') and fmt_number(e.value) or '';
                ui.cell_right(e.outcome == 'crit' and COLOR.gold or COLOR.text, value);
            end
            imgui.EndTable();
        end
    end

    imgui.Spacing();
    local unknown = {};
    for key, count in pairs(p.unknown) do
        unknown[#unknown + 1] = { key = key, count = count };
    end
    if (ui.section('unknown', ('Unrecognised messages (%d)'):fmt(#unknown), nil, width, true)) then
        if (#unknown == 0) then
            ui.text(COLOR.faint, 'None so far.');
        else
            table.sort(unknown, function (a, b) return a.count > b.count; end);
            for _, u in ipairs(unknown) do
                local cat, msg = u.key:match('(%d+):(%d+)');
                ui.text(COLOR.secondary, ('Category %s, message %s'):fmt(cat, msg));
                right_text(width, COLOR.muted, ('x%d'):fmt(u.count));
            end
            ui.note(width, COLOR.faint, 'Attack results pxparse skipped. Each one is a message id to add to core/classify.lua.');
        end
    end
end

-----------------------------------
-- Entry
-----------------------------------
function view.draw(ctx, session, width, scale, font, font_size)
    local s = ctx.settings;
    local p, choice = session:pick(view.fight);
    view.fight = choice;

    local meter = p and view.meter(p, s.sc, ctx) or { rows = {}, total = 0, active = 0, dps = 0, kills = 0 };
    local live  = session:live() and view.fight == 'current';
    draw_top(ctx, session, p, width, scale);

    local tab = view.expanded and s.tab or 'damage';
    if (view.expanded) then
        draw_tabs(ctx, width, scale);
    else
        imgui.Dummy({ 0, 2 * scale });
    end

    if (tab == 'settings') then
        draw_settings(ctx, width);
        return;
    end
    if (not p) then
        ui.note(width, COLOR.faint, 'Damage from your party (and their pets) shows up here as you fight.');
        return;
    end

    if (tab == 'detail') then
        draw_detail(ctx, p, width, scale, font, font_size, meter);
    elseif (tab == 'log') then
        draw_log(ctx, p, width, scale);
    else
        draw_bars(ctx, width, scale, meter);
        draw_footer(ctx, width, meter, live);
        if (view.expanded) then
            draw_accuracy(ctx, width, scale, meter);
            draw_experience(ctx, width, scale);
        else
            draw_exp_footer(ctx, width);
        end
    end
end

return view;
