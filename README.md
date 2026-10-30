# pxparse

A damage parser for Phoenix XI, an Ashita v4 addon. It counts what your party does, fight by fight, from the same packets the game uses to draw combat.

## Disclaimer

pxparse is for tracking your own damage and improving your own play. It isn't a tool for harassing, bullying or putting down other players.

## Install

1. Copy the `addons/pxparse` folder into your Ashita `addons` folder, so you have `addons/pxparse/pxparse.lua`.
2. In game, type `/addon load pxparse`.
3. To load it every time you play, add `/addon load pxparse` to your Ashita startup script.

To update, replace the folder. Your settings are kept in `config/addons/pxparse`.

## Using the window

The window starts as just the meter: a bar per player with their damage and share, and a footer with the fight's time, total, DPS and kills. Once you gain experience or limit points, a second line shows your rate per hour, your EXP chain and how long until you level. The dot in the footer is green while a fight is on.

- **Fight dropdown** (top left): the latest fight (named after its main mob between fights), Overall, or any of the last 20 fights.
- **Mob dropdown**: all mobs, every mob with one name ("Goblin Ambusher (all 2)"), or a single mob.
- **Eye:** hides names. Players show as their job ("COR"), in reports too.
- **Gear:** opens the tabs below. Click it again for just the meter.
- **Bars:** hover for DPS; click to open that player on Detail. Your own row always shows, even below the row limit.
- **Sections** (Accuracy, Experience, Sources): click the header to collapse it; hover the ? for what it means.
- **Right-click** anywhere on the window for lock, hide names, mob IDs, job colours, reset, hide, scale and opacity.

| Tab | What it shows |
|---|---|
| Damage | The meter, plus Accuracy (Acc% melee, RAcc% ranged, crit rate and damage taken per player) and Experience (progress to your next level or merit point, points per hour, time to level, total gained and the chain timer) |
| Detail | One player's damage, DPS, active DPS, kills, accuracy and skillchains (closed / opened), and their damage by source: melee, kicks, ranged attacks, weapon skills, spells, abilities, skillchains, pets, spikes and counters. Hover a source for max, min, accuracy, crits and magic bursts |
| Log | The last 60 results, and any attack messages pxparse doesn't recognise yet |
| Settings | Scale, opacity, skin, font, lock, resets, party only, job colours, mob IDs and where skillchain damage goes |

**Chain timer:** "Chain #2 2:41" counts down the time left to keep your EXP chain going. It's green with over half the window left, gold under half, and orange in the last quarter. After a plain kill with no chain running it shows grey, because a chain only started if that mob was Even Match or tougher, and the game doesn't say which.

If the window is too narrow for everything (a wide font, a small scale), the footer leaves out its least useful figures rather than running them together, and long names are shortened with "..".

## Skins

| Skin | Look |
|---|---|
| Phoenix | Dark red and ember. The starting skin. |
| Classic | The game's own window art and font, with rows drawn like the game's lists: text on the window and a thin gauge underneath. |
| Default | Plain ImGui. |

Classic reads the window art from your own game install (`ROM/0/14.DAT` to `21.DAT`) and follows Config > Windows > Shared > Window Type as you change it, or you can pin one type in Settings or with `/pxp wintype`.

If the art can't be read, pxparse says so once in chat and carries on with plain colours. Nothing from the game ships with the addon.

## Fonts

Each skin has its own font, set with the Font button in Settings or `/pxp font`:

| Font | What it is | Starts on |
|---|---|---|
| DejaVu Mono | DejaVu Sans Mono, shipped with pxparse in `fonts/`, at every scale | Phoenix, Default |
| Game | The game's own letters, read from your install (`ROM/119/51.DAT` or another region's copy). It's a bitmap, so it's used at scale 1 | Classic |
| Ashita | Ashita's own ImGui font | |

Under Classic every letter is ringed in dark, the way the game draws its text, so it reads on every window type. If a font can't be used (the game font's file isn't found, or a scale it doesn't have), pxparse says so once in chat and uses Ashita's font for that text.

## How it reads damage

pxparse only reads packets the server sends your client. It never blocks, changes or sends one; `/pxp report` only types into chat when you ask it to.

- **Actions (0x028).** Every attack round, weapon skill, spell, ability, ranged shot and pet move arrives as one action packet: who acted, the category (melee, ranged, weapon skill, spell, ability, mob or pet skill), the action's ID, and a list of targets, each with its results. Each result carries a resolution (hit, miss, guard, parry, block), a message ID, a value, flag bits (a crit, a kill) and two optional blocks: an additional effect (enspells, skillchains) and a reaction (spikes, counters). pxparse reads the packet bit by bit, straight through, for only those fields.
- **What a result means.** The message ID says what happened: damage, a crit, a miss, a resist, a shadow absorbed, a parry, an anticipate, a Perfect Dodge. pxparse keeps a table of which messages are damage and which count toward accuracy. A result it doesn't recognise is never guessed at; it's counted in the Log tab under its message ID.
- **Where it goes.** Each result is filed under the actor (or a pet's owner) and the target mob, by source: melee (main hand, off hand, kicks), ranged, each weapon skill, spell and ability by name, skillchains, additional effects, spikes and counters. Names come from the game's own resource tables.
- **Skillchains** arrive in the additional effect block of the weapon skill that closed them. pxparse remembers the last weapon skill on each mob for 10 seconds, so it knows who opened a chain as well as who closed it.
- **Kills (0x029).** The server's "defeats" and "falls to the ground" messages give the killer and the mob. A kill counts if your party fought that mob in the last 30 seconds.
- **Experience (0x02D).** Experience and limit point messages give the amount and the chain number, for points per hour and the chain timer.
- **Repeats.** The server can resend a batch of packets. pxparse compares each packet only against the previous batch, and drops it if it's a copy.

## How it counts

- **Fights** start with the first attack by or on your party, and last while any mob in them is alive, however long the gaps between attacks. Once every mob is dead, the fight ends 3 seconds after the last kill. A mob nobody has touched for 30 seconds (you ran, it despawned) counts as gone, and zoning ends the fight too. Each fight is named after the mob that took the most damage, with "+1" (and so on) for any others: "Goblin Ambusher +1".
- **Pets** count for their owner.
- **DPS** is damage over the fight's active time: gaps of up to 6 seconds between actions count in full, and an action after a longer break counts for 3 seconds, so a quick kill is never 0 seconds. **Active DPS** (on Detail) is damage over the time that player was acting, so someone who joined late isn't diluted.
- **Acc% and RAcc%** follow the server's order: the hit roll comes first, so parried, countered, anticipated and shadowed swings count as hits. Perfect Dodge and deflected swings are left out.
- **Kills** go to the killing blow, or to the party when the killer isn't in it.
- **Skillchains** can go to the closer, be split between opener and closer, get their own bar, or be left out.
- **EXP chains** follow Phoenix's era rules: after a kill on an Even Match or tougher mob you have 300 seconds to start a chain, then 240, 180, 120 and 60 seconds for chain #1, #2, #3 and #4 onward (mobs level 50 and up; lower levels have shorter windows). A kill on a weaker mob gives points without touching the chain.
- **Names** are coloured by job for party members. Other players show in grey. Only the main job is used: levels and sub jobs say little with level sync, and most players are 75.

### Mob IDs

When two mobs share a name, pxparse adds each one's ID so you can tell them apart: "Goblin Ambusher [1A3]" and "Goblin Ambusher [1C0]". The ID is the last three hex digits of the mob's server ID, which is its target index in the zone, the same number targeting tools show. A mob with a name nobody else has is just shown by name.

Turn on **Mob IDs** in the settings (or `/pxp ids`) to show every mob's ID, for matching Log lines to mobs in game. A spawn killed more than once shows a count in the mob dropdown ("x3").

## Limits

- pxparse only sees what the server sends your client. Party or alliance members fighting out of your range aren't counted.
- Damage-over-time ticks aren't sent to clients, so DoT damage isn't counted (the kill is).
- The jobs of party members who are /anon aren't sent, so they show in grey.
- A mob's death only counts as a kill if your party hit it, or it hit you, in the 30 seconds before.
- Fights and EXP rates aren't saved when you log out or reload.
- The chain timer starts when your client hears about the kill, a moment after the server does, and can't tell an Even Match kill from a weaker one when no chain is running. Mob levels aren't sent, so below level 50 the window is taken from your own level.
- A pet skill pxparse can't find a name for shows its ID instead.

## Commands

| Command | What it does |
|---|---|
| `/pxp` | Show or hide the window |
| `/pxp reset` | Clear every fight and the EXP rate |
| `/pxp report [s\|p\|l\|l2] [#]` | Top # (4 by default) to say, party or linkshell. Alone, just to you |
| `/pxp sc [player\|shared\|bar\|off]` | Where skillchain damage goes |
| `/pxp mask` | Hide or show names (shown as jobs, in reports too) |
| `/pxp ids` | Show every mob's ID, or only when two mobs share a name |
| `/pxp jobs` | Job colours on or off |
| `/pxp party` | Only your party and alliance, or every player nearby |
| `/pxp scale <0.5-3>` | Window size |
| `/pxp theme [phoenix\|classic\|default]` | Switch skin. Alone, the next one |
| `/pxp wintype [1-8\|game]` | Classic's window type, or follow the game's setting |
| `/pxp font [mono\|game\|ashita]` | The font for the skin in use. Alone, the next one |
| `/pxp export` | Save the picked fight as a CSV in `config\addons\pxparse` |
| `/pxp debug` | Print the job pxparse sees for you |

## Files

```
addons/pxparse/
  pxparse.lua        events, commands, duplicate filter, window
  world.lua          party, pets and names from Ashita's memory
  view.lua           the tabs
  ui.lua             drawing helpers in the active skin
  themes.lua         Phoenix, Classic and Default
  skin.lua           Classic's window art, from your game install
  gamefont.lua       the game's font, from your game install
  bitmapfont.lua     draws the shipped font from its atlases
  fonts/             DejaVu Sans Mono atlases, one per size, and its licence
  core/decode.lua    reads action packets (0x028) and battle messages (0x029, 0x02D)
  core/classify.lua  what each result means
  core/parse.lua     adds it all up
  core/fights.lua    splits it into fights
  core/exp.lua       experience and limit points per hour, and the chain timer
```

## Why it works this way

**Rules come from Phoenix's server code.** The packet layout, message IDs, the order a swing is resolved and the EXP chain windows are all taken from github.com/phoenixffxi/Phoenix, including its era modules, rather than retail references, since those can differ on an era server. Where the packet has a structured field (skillchain type, spikes and counters, the crit and kill flags), pxparse reads it directly instead of inferring it from a message.

**Nothing is dropped silently.** Results pxparse doesn't recognise are listed in the Log tab, so a gap shows up as a message ID to add instead of a quietly low number.

**Little work per packet.** Each packet is read once, straight through, for only the fields that matter. Players and mobs are tracked by server ID, which is unique and fast to look up; names are only fetched for display. Pet owners are cached for two seconds and re-checked, so a resummoned pet's damage goes to the right owner without scanning the party on every hit.

**Repeats filtered narrowly.** Comparing a packet only against the previous batch catches resends without discarding two real hits that happen to be identical.

**Views are worked out on redraw.** Each player keeps one record per mob. Totals across mobs, the mob filter and skillchain modes are calculated when the window redraws (a few times a second), not on every hit, so new views don't slow down parsing.

**Each fight is its own parse.** A fight is counted by its own copy of the parser, alongside one for the whole session. Every view, filter and setting works the same on one fight as on the session, with no separate code for fights.

**Fights end on kills, not on silence.** Gaps between actions vary a lot (a ranged attacker can go well over 6 seconds between shots), so ending a fight after a fixed quiet spell splits one mob into several fights. Ending it when the mobs are dead keeps one pull as one fight, and two pulls as two.

**Kills come from the server.** The action packet only marks a kill when the killing blow is an attack. The server's defeat messages cover every kill, including ones from damage-over-time effects, and only count if the party was fighting that mob recently.

**Accuracy follows the hit roll.** The server decides whether a swing hits before it checks parry, shadows, anticipate or counter, so those swings say the hit roll succeeded and count as hits. Perfect Dodge is checked before the roll, so it says nothing about accuracy and is left out.

**Skillchains are tracked per mob.** That's what lets pxparse know who opened a chain, and split the credit in shared mode.

**Mobs are told apart by ID, shown only when it helps.** Two mobs with the same name are different entities, so each gets its own record. Most of the time names are already unique, and an ID on every line is noise, so it's only added where it tells two mobs apart, unless you ask for it everywhere.

**EXP per hour uses a 10 minute window.** A rate over the whole session would barely move after a break or a change of camp; a rate over the last few kills would swing wildly. Ten minutes follows your current pace, and the first minute is never counted as shorter than a minute, so one early kill doesn't read as a huge rate.

**The chain timer shows what it can't know.** The client is told the chain number, not the mob's difficulty, so a plain kill might have started a chain or might not. The timer shows that window in grey rather than guessing, and turns coloured once the server confirms a chain.

**The window stays small and steady.** The meter alone covers most of a fight, so everything else sits behind the gear. Footer figures update once a second and keep their place on the line, so a number ticking over doesn't shake the line, and each item has a priority so the least useful ones are left out before anything overlaps. Ashita's font, scale and players' names vary, and a fixed layout that fits one setup runs together on another.

**Classic draws rows the way the game does.** The game never puts a filled bar behind text: its lists are text on the window art, and its gauges are thin strips. Filled bars over the art look out of place and make coloured names harder to read, so Classic shows each player's share as a thin gauge in their job colour under the name.

**Fonts are drawn, not loaded.** Loading a font into ImGui from an addon while the game is running can crash it, and a crash inside the game can't be caught. So both extra fonts are drawn letter by letter as small textured squares: the game's from your install, DejaVu Mono from atlases baked ahead of time, one per size so the letters always land on whole pixels. Each atlas also has a copy with the dark ring baked in, so a ringed letter is still one square and a full Log tab stays well under what ImGui draws in one window.

**Skins only change the look.** Every skin fills the same palette, so the window is drawn by the same code in each. Classic reads its art and letters from your own install when it first needs them and falls back cleanly if it can't, so nothing from the game is shipped and a missing file never stops the meter.

## License

pxparse is free software under the [GNU General Public License v3.0](LICENSE). The DejaVu Sans Mono atlases in `fonts/` are drawn from DejaVu Sans Mono, under its own licence ([fonts/LICENSE-DejaVu.txt](addons/pxparse/fonts/LICENSE-DejaVu.txt)).
