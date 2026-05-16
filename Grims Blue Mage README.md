# Grim's Blue Mage ACR

A modernised Combat Routine for Blue Mage in FFXIV, written for MMOMinion / FFXIVMinion. Targets the level 80 spell pool (current cap) with explicit support for **leveling / sync content** and **Masked Carnivale**.

Inspired by the architecture of Kali's Blue Mage ACR, but rewritten from scratch against current API conventions and the modern spell list (Apokalypsis, Being Mortal, Sea Shanty, Mortal Flame, Breath of Magic, Winged Reprobation, Tingle, Nightbloom, etc.).

---

## Installation

Place the files in your MMOMinion `LuaMods` folder so they end up at:

```
<MMOMinion install>\LuaMods\ACR\CombatRoutines\
├── Grims Blue Mage.lua            ← entry point
└── Grims Blue Mage\
    ├── Settings.lua               (auto-created on first run)
    ├── Data.lua
    ├── Helpers.lua
    ├── Logic.lua
    ├── Modes.lua
    ├── UI.lua
    └── Images\                    (optional; copy from Kali's ACR if desired)
```

On Windows the typical path is `C:\MINIONAPP\Bots\FFXIVMinion64\LuaMods\ACR\CombatRoutines\`. Restart MMOMinion after copying.

In the ACR dropdown (Skill Manager / ACR selector), choose **Grims Blue Mage** for Blue Mage.

---

## What it does

### Auto Mimicry
Picks `DPS` / `Tank` / `Healer` in the Modes tab. Whenever the corresponding buff is missing on the player, the ACR auto-casts Aetherial Mimicry on the **nearest party member with that role**. Set to `Off` to disable.

### Rotation engine
Walks a user-orderable priority list each tick. Per-spell logic functions decide whether the spell is appropriate right now, considering:

- HP advantage (don't punch above your weight)
- Sync level / spell learn-level
- Cooldown-group exclusivity (Off-guard ↔ Peculiar Light, Matra ↔ Dragon Force ↔ Angel's Snack, J Kick ↔ Quasar, etc.)
- DoT freshness (Song of Torment, Nightbloom, Breath of Magic refresh inside DoT Refresh window; Mortal Flame applied once per target)
- Moon Flute window state (`waxing` / `waning` / none) - heavy 2-min spells are held for the burst window when Moon Flute Auto is on
- AoE threshold (default **3** enemies)
- Magic / Physical damage-down debuffs on target

### Buff prepend
When a high-priority spell is tagged as needing **Bristle**, **Whistle**, or **Tingle**, the engine auto-casts the buff first. Same idea Kali used, extended for the modern spell list. Swiftcast prepends for cast-time spells when moving.

### Smart Diamondback
Fires Diamondback when:
- An enemy is casting a 2s+ action targeting the player AND HP is below the configured threshold, OR
- The casting action ID is in your whitelist (hand-curated tankbusters for Carnivale stages).

Configurable in the **Defensive** tab.

### Mighty Guard / Basic Instinct
- `Mighty Guard` auto-toggles when in **Tank Mimicry** mode or in solo mode with Basic Instinct (which negates the -40% damage penalty).
- `Basic Instinct` auto-applies in solo content if the toggle is on.

### Masked Carnivale
- **Vibe Check combo**: Swiftcast → Ram's Voice → Ultravibration on freezable mobs (auto-chained when the toggle is on).
- **Final Sting / Self-destruct**: **manual only** by design. They remain in the Actions list (disabled) so you can use them via hotbar but the engine will never auto-fire them.
- **Doom / Missile / Tail Screw**: gated behind the **Low Chance** mode toggle plus per-spell enables in the Carnivale tab.

### Interrupts / Stuns / Dispels / Esunas
Same hand-curated ID-list approach as the original ACR. Edit the lists in the Defensive tab.

---

## Configuration tabs

| Tab | Purpose |
|-----|---------|
| General | Action delay, precast, slide-cast timings, draw toggles, healing %s |
| Modes | Mimicry radio, mode toggles, AoE threshold, stance options |
| Rotation | Moon Flute auto, DoT refresh window, status display |
| Actions | Per-spell enable, drag/move-up/down to reorder priority |
| Defensive | Diamondback whitelist + thresholds, interrupt/stun/dispel/esuna ID lists |
| Carnivale | Vibe Check, instakill toggles, tips |

### Floating toggle row

The on-screen toggle bar gives one-click access to the major modes (DPS / AoE / Heal / Defensives / Carnivale / Interrupt / Stun / HpAdv / Magical / Physical / LowChance) plus the Mimicry segmented selector. Green = enabled, red = disabled.

---

## Default priority

The default priority order (re-orderable in the Actions tab) is:

1. Defensives & stances (Diamondback / Mimicry / Mighty Guard / Basic Instinct)
2. Buff prepends (Bristle / Whistle / Tingle / Swiftcast / Off-guard / Peculiar Light)
3. Moon Flute
4. 120s heavy hitters (Apokalypsis, Being Mortal, Sea Shanty, Phantom Flurry, Matra, Nightbloom, Both Ends, Triple Trident)
5. DoTs (Mortal Flame, Breath of Magic, Song of Torment)
6. 60-90s damage (Rose, Glass Dance, J Kick, Quasar, Winged Reprobation, Surpanakha)
7. 30s oGCDs (Shock Strike, Mountain Buster, Feather Rain, Eruption)
8. Utility (Eerie Soundwave, Faze, Perpetual Ray, Sticky Tongue, Bomb Toss, Magic Hammer)
9. Filler (Sonic Boom, Water Cannon)
10. Heals (Pom Cure, Stotram, White Wind, Gobskin, Angel's Snack, Exuviation, Dragon Force)
11. Niche/Low-chance (1000 Needles, Missile, Tail Screw, Doom, Bad Breath, Ink Jet, Launcher, Flying Sardine)
12. Vibe Check chain (Ram's Voice, Ultravibration, Cold Fog)
13. Manual-only (Final Sting, Self-destruct, Toad Oil — disabled by default)

---

## Architecture (for hackers)

```
Grims Blue Mage.lua            ─ ACR loader hook, OnLoad/OnOpen/OnUpdate/Draw
└── Grims Blue Mage/
    ├── Data.lua               ─ Static spell registry, buff IDs, CD groups
    ├── Helpers.lua            ─ Geometry, distance, valid, HP advantage
    ├── Logic.lua              ─ Rotation engine, ActionLogic[id] builder, Cast loop
    ├── Modes.lua              ─ Mimicry, Defensives, Healing prep, Carnivale prep
    └── UI.lua                 ─ Main window, tabs, toggle row
```

The Logic module's `BuildLogic(name, registry, id)` generates per-spell decision functions from registry metadata. To add a new spell:

1. Add an entry to `Data.SpellRegistry` keyed by exact in-game name.
2. (Optional) add to `Data.DefaultPriority` at the right position.
3. The next `RefreshActions` call (every 5s, or on OnOpen) will pick it up automatically.

To override the auto-generated logic for a specific spell, supply your own function via the Actions-tab logic editor (TODO in v1.1) or directly set `Runtime.ActionLogic[id] = function() ... end` from a side-script.

---

## Known limitations / TODO for v1.1

- In-game spell hotbar (the floating clickable button grid from Kali's ACR) is deferred. The toggle row covers most quick-action needs.
- Per-spell logic editor in the Actions tab is stubbed — for now, edit `Logic.BuildLogic` to customise behaviour.
- Enemy circle/cone overlay is stubbed — copy `DrawCircle` / `DrawCircularSector` from Kali's ACR if you want the visualisation.
- Spell IDs are resolved by name from the live action list, so a name mismatch on a new patch will silently drop that spell from the registry. The Actions tab will show the registered spell count — if it looks wrong after a patch, check the in-game action name and update `Data.SpellRegistry`.

---

## Credits

- Architecture and pattern (priority list + per-spell logic + buff prepend) inspired by [KaliMinion's original Blue Mage ACR](https://github.com/KaliMinion/Blue-Mage-ACR).
- Spell metadata sourced from Icy-Veins, Square Enix's official Blue Mage job guide, and the FFXIV community wiki.
