--[[
================================================================================
    Grim's Blue Mage ACR - Data Module
    Static reference data: spell registry, buff IDs, cooldown groups, level
    gates. NO MUTABLE STATE here - everything in Data is constant tables that
    are read by Logic / Modes / UI.

    Spell registry is keyed by NAME (case-sensitive, matches the in-game
    action name as returned by ActionList). At OnLoad, Logic.RefreshActions
    walks the live ActionList, looks each action's name up in this registry,
    and populates Runtime.Action[id] with the merged metadata. This makes
    the ACR resilient to action-ID renumbering across patches.

    Tiers (governs Actions tab default sort):
        S - core damage / always-relevant
        A - timing-critical buff or top damage situational
        B - useful utility / specialised damage
        C - niche or low-chance

    Categories:
        damage      - direct damage spell
        dot         - applies a DoT effect
        buff        - self/party buff
        debuff      - target debuff
        heal        - healing spell
        defensive   - damage reduction / mitigation
        utility     - gap-closer / movement / silence / stun / dispel / esuna
        burst_window- Moon Flute (enters Waxing -> Waning)
        suicide     - kills caster (Final Sting / Self-destruct), MANUAL ONLY
        instakill   - low-chance / death-flag (Missile, Tail Screw, Doom)
        stance      - persistent toggle (Mighty Guard, Basic Instinct, Mimicry)

    target flags (mirror xivapi schema used by old ACR):
        selfp    - can target self
        party    - can target party member
        friend   - can target friendly (party or out-of-party ally/pet)
        hostile  - can target hostile
        area     - ground-targeted AoE
        affectsPos - movement-impeding (Loom, Launcher, etc.)
================================================================================
]]

local self = GBLU
self.Data = self.Data or {}
local Data = self.Data

-- ============================================================================
-- Status / buff IDs (constant across patches)
-- ============================================================================

Data.Buffs = {
    -- Generic
    Stun                 = 2,
    Swiftcast            = 167,
    Boost                = 1716,     -- from Bristle (50% next spell)
    Diamondback          = 1722,
    PhysDamageDown       = 1307,
    MagicDamageDown      = 556,

    -- Mimicry stances
    AetherialMimicryTank   = 2124,
    AetherialMimicryDPS    = 2125,
    AetherialMimicryHealer = 2126,

    -- BLU-specific
    Whistle              = 1718,     -- +80% next physical spell
    Tingling             = 2492,     -- from Tingle, +100p next damage spell
    MoonFluteWaxing      = 1727,     -- +50% damage 15s
    MoonFluteWaning      = 1729,     -- lockout 15s after Waxing
    MightyGuard          = 1719,     -- toggle: +def, -40% dmg dealt
    BasicInstinct        = 2498,     -- solo-only stance: +100% dmg
    BrushWithDeath       = 1730,     -- post-Final-Sting "no resurrect"
    SurpanakhasFury      = 2130,     -- stack from Surpanakha (4 charges)
    PeculiarLight        = 1721,     -- target debuff +20% magic dmg
    OffGuard             = 1717,     -- target debuff +10% all dmg
    BleedingMortalFlame  = 3643,     -- Mortal Flame DoT
    BreathOfMagic        = 3712,     -- Breath of Magic DoT
    SongOfTorment        = 1714,     -- Song of Torment DoT
    Bleeding             = 1838,     -- Nightbloom DoT
    DeepFreeze           = 1731,     -- Ram's Voice / Cold Fog
    AuspiciousTrance     = 2497,     -- White Death buff (from Cold Fog kill)
    Surecast             = 160,
    ColdFog              = 2493,     -- Cold Fog active

    -- Defensive buffs the ACR shouldn't interrupt
    DoNotInterruptList = "13+88+280+378+387+457+564+608+625+713+774+783+896+986+1153+1258+1304+1305+1345+1533+1696+1722+1762+1785+1950+1953+1963",
}

-- ============================================================================
-- Cooldown groups - spells that share a CD timer (only one of each set
-- can be cast per CD window). Names here MUST match SpellRegistry keys.
-- ============================================================================

Data.CDGroups = {
    -- 60s damage cooldowns sharing one slot
    Burst60 = { "The Rose of Destruction", "Chelonian Gate" },

    -- 60s target-debuff slot
    TargetDebuff60 = { "Off-guard", "Peculiar Light" },

    -- 60s phys-AoE slot
    PhysAoE60 = { "Glass Dance", "Veil of the Whorl" },

    -- 60s oGCD slot - lightning/earth burst
    StrikeBurst60 = { "Shock Strike", "Mountain Buster" },

    -- 60s instant DoT-applying nuke
    GroundBurst30 = { "Feather Rain", "Eruption" },

    -- 120s major damage cooldowns
    Burst120A = { "J Kick", "Quasar" },                          -- shared 60s actually
    Burst120B = { "Phantom Flurry", "Sea Shanty" },
    Burst120C = { "Being Mortal", "Apokalypsis" },
    Burst120D = { "Matra Magic", "Dragon Force", "Angel's Snack" },
    Burst120E = { "Nightbloom", "Both Ends" },
}

-- ============================================================================
-- Spell registry - the core data table.
-- Keyed by NAME (must match in-game action name).
-- Logic.RefreshActions matches these against ActionList:Get(1) entries
-- where action.job == 36 (BLU) or 255 (BLU spell pool).
-- ============================================================================

Data.SpellRegistry = {
    -- ---------------- Cross-class role actions (job 0 / role) ----------------
    ["Swiftcast"] = {
        tier="A", category="buff", aspect="none", minLevel=18,
        knownId=7561, isRole=true, target={selfp=true},
        notes="Forces next spell to be instant. Pre-empted by buff-prepend logic."
    },

    -- ============================================================================
    -- TIER S DAMAGE
    -- ============================================================================
    ["Sonic Boom"] = {
        tier="S", category="damage", aspect="magical", minLevel=20,
        potency=210, castTime=2, knownId=11383,
        target={hostile=true}, prepend="bristle",
        notes="Reliable filler magical damage."
    },
    ["Water Cannon"] = {
        tier="A", category="damage", aspect="magical", minLevel=1,
        potency=200, castTime=2, knownId=11385,
        target={hostile=true}, prepend="bristle",
        notes="Earliest BLU spell; sync filler."
    },
    ["Flying Sardine"] = {
        tier="C", category="utility", aspect="physical", minLevel=46,
        potency=10, knownId=11406,
        target={hostile=true},
        notes="Silences boss-tier silenceable casts. Low damage."
    },

    -- DoT family
    ["Song of Torment"] = {
        tier="S", category="dot", aspect="magical", minLevel=50,
        potency=50, dotPotency=50, dotDuration=30, castTime=2,
        target={hostile=true}, prepend="bristle", dotBuff="SongOfTorment",
        notes="Primary 30s DoT. Bristle-prepend gives huge tick value."
    },
    ["Nightbloom"] = {
        tier="S", category="dot", aspect="magical", minLevel=70,
        potency=400, dotPotency=75, dotDuration=60, cooldown=120,
        target={hostile=true}, cdGroup="Burst120E",
        notes="120s nuke + 60s DoT. Centerpiece of burst window."
    },
    ["Mortal Flame"] = {
        tier="S", category="dot", aspect="magical", minLevel=80,
        potency=30, dotPotency=30, dotDuration=999, cooldown=60,
        target={hostile=true}, dotBuff="BleedingMortalFlame",
        notes="DoT lasts until target dies. One per target."
    },
    ["Breath of Magic"] = {
        tier="S", category="dot", aspect="magical", minLevel=80,
        potency=0, dotPotency=120, dotDuration=120, cooldown=60,
        target={hostile=true}, dotBuff="BreathOfMagic",
        notes="120s ticking DoT. Refresh every 60s with mini-burst."
    },

    -- Single-cast nukes
    ["The Rose of Destruction"] = {
        tier="S", category="damage", aspect="physical", minLevel=72,
        potency=400, castTime=2, cooldown=30,
        target={hostile=true}, cdGroup="Burst60", prepend="whistle",
        notes="Strong physical nuke; combos with Whistle."
    },
    ["Matra Magic"] = {
        tier="S", category="damage", aspect="magical", minLevel=70,
        potency=400, castTime=2, cooldown=120,
        target={hostile=true}, cdGroup="Burst120D",
        mimicryDouble="DPS",   -- DPS Mimicry doubles potency
        notes="8 random hits. Doubles to 800p under DPS Mimicry."
    },
    ["Triple Trident"] = {
        tier="S", category="damage", aspect="physical", minLevel=66,
        potency=450, cooldown=90, instant=true,
        target={hostile=true}, prepend="whistle_tingle",
        notes="3 hits, 150p each. Combos with Whistle+Tingle for ~1500+."
    },
    ["Phantom Flurry"] = {
        tier="S", category="damage", aspect="physical", minLevel=70,
        potency=1000, cooldown=120, channeled=true,
        target={hostile=true}, cdGroup="Burst120B",
        notes="Channel 5s ending in 1000p hit. Snapshots Moon Flute."
    },
    ["J Kick"] = {
        tier="S", category="damage", aspect="physical", minLevel=70,
        potency=300, cooldown=60, instant=true,
        target={hostile=true}, cdGroup="Burst120A",
        notes="AoE physical, gap-closer animation."
    },
    ["Quasar"] = {
        tier="S", category="damage", aspect="magical", minLevel=60,
        potency=300, cooldown=60, instant=true,
        target={hostile=true}, cdGroup="Burst120A",
        notes="AoE magical. J Kick preferred when both available."
    },
    ["Surpanakha"] = {
        tier="S", category="damage", aspect="physical", minLevel=60,
        potency=200, cooldown=30, charges=4, instant=true,
        target={hostile=true}, special="surpanakha_stack",
        notes="4 charges, 200/300/400/500p when chained. Quad-weave in Moon Flute."
    },
    ["Winged Reprobation"] = {
        tier="A", category="damage", aspect="magical", minLevel=70,
        potency=200, cooldown=90, charges=4, instant=true,
        target={hostile=true}, prepend="bristle",
        notes="4 charges; 4th becomes 400p+stun. CD shortens with use."
    },
    ["Sea Shanty"] = {
        tier="S", category="damage", aspect="magical", minLevel=80,
        potency=500, cooldown=120, instant=true,
        target={hostile=true}, cdGroup="Burst120B",
        notes="1000p AoE under rain/storm weather, else 500p."
    },
    ["Being Mortal"] = {
        tier="S", category="damage", aspect="magical", minLevel=80,
        potency=1100, cooldown=120, instant=true,
        target={hostile=true}, cdGroup="Burst120C",
        notes="1100p AoE; shares CD slot with Apokalypsis."
    },
    ["Apokalypsis"] = {
        tier="S", category="damage", aspect="magical", minLevel=80,
        potency=1400, cooldown=120, channeled=true,
        target={hostile=true}, cdGroup="Burst120C",
        notes="Channeled 10s, ~140p/tick. Stationary."
    },

    -- oGCD instant damage
    ["Feather Rain"] = {
        tier="A", category="damage", aspect="physical", minLevel=60,
        potency=220, cooldown=30, instant=true,
        target={hostile=true}, cdGroup="GroundBurst30", area=false,
        notes="220p + 40p/tick DoT. Shares Eruption CD."
    },
    ["Eruption"] = {
        tier="A", category="damage", aspect="magical", minLevel=60,
        potency=300, cooldown=30, instant=true,
        target={hostile=true, area=true}, cdGroup="GroundBurst30",
        notes="300p AoE ground-target. Shares Feather Rain CD."
    },
    ["Shock Strike"] = {
        tier="A", category="damage", aspect="magical", minLevel=60,
        potency=400, cooldown=60, instant=true,
        target={hostile=true}, cdGroup="StrikeBurst60",
        notes="400p single-target lightning + stun."
    },
    ["Mountain Buster"] = {
        tier="A", category="damage", aspect="physical", minLevel=60,
        potency=400, cooldown=60, instant=true,
        target={hostile=true}, cdGroup="StrikeBurst60",
        notes="400p single-target earth. Shares Shock Strike CD."
    },
    ["Glass Dance"] = {
        tier="A", category="damage", aspect="physical", minLevel=60,
        potency=350, cooldown=90, instant=true,
        target={hostile=true}, cdGroup="PhysAoE60",
        notes="350p PBAoE."
    },
    ["Hydro Pull"] = {
        tier="A", category="utility", aspect="magical", minLevel=60,
        potency=220, cooldown=60, instant=true,
        target={hostile=true},
        notes="Draws enemies. AoE setup before Vibe Check."
    },

    -- ============================================================================
    -- TIER A BUFFS (TIMING CRITICAL)
    -- ============================================================================
    ["Bristle"] = {
        tier="A", category="buff", aspect="none", minLevel=20,
        cooldown=15, castTime=2, knownId=11393,
        target={selfp=true}, prependKey="bristle", buffGranted="Boost",
        notes="+50% next spell potency. Prepended automatically before bristle-tagged casts."
    },
    ["Whistle"] = {
        tier="A", category="buff", aspect="none", minLevel=66,
        cooldown=30, instant=true, target={selfp=true},
        prependKey="whistle", buffGranted="Whistle",
        notes="+80% next physical spell. Combos with Triple Trident / Rose."
    },
    ["Tingle"] = {
        tier="A", category="buff", aspect="none", minLevel=80,
        cooldown=60, instant=true, target={selfp=true},
        prependKey="tingle", buffGranted="Tingling",
        notes="+100p to next damage spell. Combos with Triple Trident."
    },
    ["Moon Flute"] = {
        tier="S", category="burst_window", aspect="none", minLevel=68,
        cooldown=120, castTime=2, target={selfp=true},
        buffGranted="MoonFluteWaxing",
        notes="+50% damage 15s, then 15s Waning (no actions). Centerpiece of opener."
    },
    ["Off-guard"] = {
        tier="A", category="debuff", aspect="none", minLevel=50,
        cooldown=60, castTime=2,
        target={hostile=true}, cdGroup="TargetDebuff60",
        notes="Target takes +10% all damage. Shares Peculiar Light slot."
    },
    ["Peculiar Light"] = {
        tier="A", category="debuff", aspect="none", minLevel=60,
        cooldown=60, castTime=2,
        target={hostile=true}, cdGroup="TargetDebuff60",
        notes="Target takes +20% magic damage. Use when burst is magical (Moon Flute)."
    },
    ["Both Ends"] = {
        tier="A", category="damage", aspect="magical", minLevel=70,
        potency=600, cooldown=120, instant=true,
        target={hostile=true}, cdGroup="Burst120E",
        notes="Strong magic burst; shares Nightbloom slot."
    },

    -- ============================================================================
    -- TIER B - HEALS (HEALER MIMICRY)
    -- ============================================================================
    ["Pom Cure"] = {
        tier="B", category="heal", aspect="none", minLevel=4,
        potency=400, castTime=1.5,
        target={selfp=true, party=true, friend=true},
        mimicryAugment="Healer",
        notes="Primary single-target heal. Low MP."
    },
    ["White Wind"] = {
        tier="B", category="heal", aspect="none", minLevel=50,
        cooldown=90, castTime=0, target={selfp=true},
        mimicryAugment="Healer",
        notes="Heals self+party for 25% of caster max HP."
    },
    ["Stotram"] = {
        tier="B", category="heal", aspect="none", minLevel=66,
        potency=300, castTime=1.5, target={selfp=true},
        mimicryAugment="Healer",
        notes="AoE heal + regen. Also a 300p AoE damage spell."
    },
    ["Gobskin"] = {
        tier="B", category="defensive", aspect="none", minLevel=60,
        cooldown=60, instant=true, target={selfp=true},
        mimicryAugment="Healer",
        notes="Galvanize shield 10% max HP, stackable."
    },
    ["Angel's Snack"] = {
        tier="B", category="heal", aspect="none", minLevel=70,
        cooldown=120, target={selfp=true}, cdGroup="Burst120D",
        mimicryAugment="Healer",
        notes="AoE regen. Shares Matra/Dragon Force slot."
    },
    ["Exuviation"] = {
        tier="B", category="utility", aspect="none", minLevel=70,
        cooldown=60, target={selfp=true, party=true},
        mimicryAugment="Healer",
        notes="Esuna effect + small heal."
    },
    ["Angel Whisper"] = {
        tier="B", category="utility", aspect="none", minLevel=80,
        cooldown=300, target={party=true, friend=true},
        notes="Raise. 5-min CD. Conditional on RaiseOutsideParty setting."
    },

    -- ============================================================================
    -- TIER B - DEFENSIVES
    -- ============================================================================
    ["Diamondback"] = {
        tier="A", category="defensive", aspect="none", minLevel=60,
        cooldown=120, castTime=1, target={selfp=true},
        buffGranted="Diamondback", special="diamondback",
        notes="90% damage reduction 10s. Unmovable. Auto-fired by smart trigger."
    },
    ["Dragon Force"] = {
        tier="B", category="defensive", aspect="none", minLevel=70,
        cooldown=120, target={selfp=true, party=true}, cdGroup="Burst120D",
        notes="Party 10% damage reduction 30s."
    },
    ["Mighty Guard"] = {
        tier="A", category="stance", aspect="none", minLevel=50,
        instant=true, target={selfp=true}, buffGranted="MightyGuard",
        notes="Toggle: +def, -40% damage. Negated by Basic Instinct."
    },
    ["Basic Instinct"] = {
        tier="A", category="stance", aspect="none", minLevel=60,
        instant=true, target={selfp=true}, buffGranted="BasicInstinct",
        notes="Solo-only: +100% damage, +50% healing, +50% def, +20% move."
    },

    -- ============================================================================
    -- TIER A - STANCES
    -- ============================================================================
    ["Aetherial Mimicry"] = {
        tier="A", category="stance", aspect="none", minLevel=70,
        instant=true, target={party=true, friend=true},
        special="mimicry",
        notes="Copies target ally's role: Tank/DPS/Healer stance."
    },

    -- ============================================================================
    -- TIER B - UTILITY
    -- ============================================================================
    ["Loom"] = {
        tier="B", category="utility", aspect="none", minLevel=20,
        cooldown=30, target={hostile=true},
        notes="Gap-closer. No damage."
    },
    ["Eerie Soundwave"] = {
        tier="B", category="utility", aspect="magical", minLevel=70,
        potency=1, cooldown=30, instant=true,
        target={hostile=true},
        notes="Silence + knockback."
    },
    ["Faze"] = {
        tier="B", category="utility", aspect="magical", minLevel=46,
        cooldown=30, instant=true,
        target={hostile=true},
        notes="6s stun."
    },
    ["Bomb Toss"] = {
        tier="C", category="utility", aspect="physical", minLevel=46,
        cooldown=30, instant=true,
        target={hostile=true, area=true},
        notes="3s stun ground-target."
    },
    ["Sticky Tongue"] = {
        tier="C", category="utility", aspect="physical", minLevel=46,
        cooldown=30, instant=true,
        target={hostile=true},
        notes="4s stun + draw-in."
    },
    ["Perpetual Ray"] = {
        tier="B", category="utility", aspect="magical", minLevel=60,
        cooldown=30, instant=true,
        target={hostile=true},
        notes="1s stun, ignores stun resistance."
    },
    ["Launcher"] = {
        tier="C", category="utility", aspect="physical", minLevel=46,
        cooldown=30, target={hostile=true},
        notes="100% accuracy knockback."
    },
    ["Magic Hammer"] = {
        tier="B", category="damage", aspect="magical", minLevel=46,
        potency=200, cooldown=60, instant=true,
        target={hostile=true},
        notes="200p + MP drain. Self-MP refill."
    },

    -- ============================================================================
    -- TIER C - LOW-CHANCE / NICHE
    -- ============================================================================
    ["1000 Needles"] = {
        tier="C", category="damage", aspect="physical", minLevel=50,
        potency=1000, castTime=3,
        target={hostile=true}, prepend="whistle",
        notes="Flat 1000 damage. Useful for level-sync soloing."
    },
    ["Missile"] = {
        tier="C", category="instakill", aspect="physical", minLevel=46,
        cooldown=120, instant=true,
        target={hostile=true}, gateLowChance=true,
        notes="~67% hit, 50% current-HP cut. LowChance toggle."
    },
    ["Tail Screw"] = {
        tier="C", category="instakill", aspect="physical", minLevel=46,
        cooldown=120, instant=true,
        target={hostile=true}, gateLowChance=true,
        notes="~10% hit, 50% current-HP cut. LowChance toggle."
    },
    ["Doom"] = {
        tier="C", category="instakill", aspect="magical", minLevel=70,
        cooldown=120, castTime=2,
        target={hostile=true}, gateLowChance=true,
        notes="~33% hit, 60s death timer. Most bosses immune."
    },
    ["Bad Breath"] = {
        tier="C", category="debuff", aspect="magical", minLevel=46,
        cooldown=60, castTime=2,
        target={hostile=true},
        notes="Heavy/Slow/Blind/Poison/Paralyze/Malodorous AoE cone."
    },
    ["Ink Jet"] = {
        tier="C", category="damage", aspect="magical", minLevel=46,
        potency=200, cooldown=30, instant=true,
        target={hostile=true},
        notes="Blind cone."
    },

    -- ============================================================================
    -- VIBE CHECK COMBO (Carnivale mode)
    -- ============================================================================
    ["Ram's Voice"] = {
        tier="B", category="utility", aspect="physical", minLevel=46,
        potency=220, cooldown=30, castTime=2,
        target={hostile=true}, special="vibe_freeze",
        notes="Inflicts Deep Freeze. Set up for Ultravibration."
    },
    ["Cold Fog"] = {
        tier="B", category="defensive", aspect="none", minLevel=60,
        cooldown=120, instant=true, target={selfp=true},
        notes="Reduces damage; on death-block, grants White Death (large attack)."
    },
    ["Ultravibration"] = {
        tier="A", category="instakill", aspect="magical", minLevel=60,
        cooldown=120, castTime=2,
        target={hostile=true}, special="vibe_kill",
        notes="Instant-kills Deep-Frozen enemies. Carnivale gold."
    },

    -- ============================================================================
    -- SUICIDE SPELLS - MANUAL ONLY (UseFinalStingAuto = false per user)
    -- ============================================================================
    ["Final Sting"] = {
        tier="C", category="suicide", aspect="physical", minLevel=50,
        potency=2000, cooldown=0, castTime=1,
        target={hostile=true}, manualOnly=true,
        notes="2000p but kills caster. ACR will NEVER auto-fire; manual hotbar only."
    },
    ["Self-destruct"] = {
        tier="C", category="suicide", aspect="physical", minLevel=46,
        potency=2150, cooldown=0,
        target={selfp=true, area=true}, manualOnly=true,
        notes="2150p PBAoE but kills caster. Buffed by Toad Oil. Manual only."
    },
    ["Toad Oil"] = {
        tier="C", category="buff", aspect="none", minLevel=46,
        cooldown=60, instant=true, target={selfp=true},
        notes="+15% damage to next physical spell."
    },
}

-- ============================================================================
-- Burst window participants - spells that should fire INSIDE Moon Flute Waxing
-- when MoonFluteAuto is on. Ordered by ideal sequence (oGCDs interleaved by Logic).
-- ============================================================================

Data.MoonFluteBurstSpells = {
    "Triple Trident",
    "Matra Magic",
    "Nightbloom",
    "Both Ends",
    "Sea Shanty",
    "Being Mortal",
    "Apokalypsis",
    "Phantom Flurry",
    "The Rose of Destruction",
    "J Kick",
    "Quasar",
}

-- Oggcds quad-weave candidates inside burst window
Data.BurstWeaveSpells = {
    "Surpanakha",        -- 4-stack quad weave
    "Feather Rain",
    "Shock Strike",
    "Mountain Buster",
    "Eruption",
    "Glass Dance",
}

-- ============================================================================
-- Default Action priority order (by name; resolved to IDs at OnLoad).
-- Higher = checked first. The user can re-order in the Actions tab.
-- ============================================================================

Data.DefaultPriority = {
    -- Defensives / interrupts (handled outside the priority list but listed for reorder)
    "Diamondback",
    "Aetherial Mimicry",
    "Mighty Guard",
    "Basic Instinct",

    -- Buff-prepend (Logic prepends these automatically; listed at high priority for fallback)
    "Swiftcast",
    "Bristle",
    "Whistle",
    "Tingle",
    "Off-guard",
    "Peculiar Light",

    -- Burst window opener
    "Moon Flute",

    -- Major 120s damage
    "Apokalypsis",
    "Being Mortal",
    "Sea Shanty",
    "Phantom Flurry",
    "Matra Magic",
    "Nightbloom",
    "Both Ends",
    "Triple Trident",

    -- DoTs
    "Mortal Flame",
    "Breath of Magic",
    "Song of Torment",

    -- 90/60s damage
    "The Rose of Destruction",
    "Glass Dance",
    "Quasar",
    "J Kick",
    "Winged Reprobation",
    "Surpanakha",

    -- 30s oGCD damage
    "Shock Strike",
    "Mountain Buster",
    "Feather Rain",
    "Eruption",

    -- Utility / control
    "Eerie Soundwave",
    "Faze",
    "Perpetual Ray",
    "Sticky Tongue",
    "Bomb Toss",
    "Magic Hammer",

    -- Filler
    "Sonic Boom",
    "Water Cannon",

    -- Heals (only when Healing mode on)
    "Pom Cure",
    "Stotram",
    "White Wind",
    "Gobskin",
    "Angel's Snack",
    "Exuviation",
    "Angel Whisper",
    "Dragon Force",

    -- Niche / low-chance (gated by LowChance toggle)
    "1000 Needles",
    "Missile",
    "Tail Screw",
    "Doom",
    "Bad Breath",
    "Ink Jet",
    "Launcher",
    "Flying Sardine",

    -- Vibe Check combo
    "Ram's Voice",
    "Ultravibration",
    "Cold Fog",

    -- Suicide (manual only - listed only so they appear in Actions tab disabled)
    "Final Sting",
    "Self-destruct",
    "Toad Oil",
}

-- ============================================================================
-- Spells the user typically does NOT want auto-cast.
-- Logic sets Settings.Actions[id] = false for these on first run.
-- ============================================================================

Data.DisabledByDefault = {
    ["Final Sting"]    = true,
    ["Self-destruct"]  = true,
    ["Toad Oil"]       = true,
    ["Doom"]           = true,
    ["Missile"]        = true,
    ["Tail Screw"]     = true,
    ["1000 Needles"]   = true,
    ["Angel Whisper"]  = true,
    ["Launcher"]       = true,
    ["Flying Sardine"] = true,
}

-- ============================================================================
-- Helpers exposed for Logic / Modes / UI
-- ============================================================================

function Data.GetSpell(name)
    return Data.SpellRegistry[name]
end

function Data.CDGroupMembers(groupName)
    return Data.CDGroups[groupName]
end

-- Lookup a spell by name across registry (case-insensitive convenience)
function Data.FindByName(name)
    if not name then return nil end
    local entry = Data.SpellRegistry[name]
    if entry then return entry end
    local lower = string.lower(name)
    for n, e in pairs(Data.SpellRegistry) do
        if string.lower(n) == lower then return e end
    end
end

return Data
