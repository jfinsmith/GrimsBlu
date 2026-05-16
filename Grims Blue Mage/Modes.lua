--[[
================================================================================
    Grim's Blue Mage ACR - Modes Module
    Mode handlers that run outside the main priority loop:

      * UpdateMimicry      - Auto-apply Aetherial Mimicry to nearest party
                             member of the chosen role (DPS/Tank/Healer).
      * UpdateStanceBuffs  - Mighty Guard toggle, Basic Instinct solo,
                             Cold Fog awareness.
      * UpdateDefensives   - Smart Diamondback trigger (called inside Cast loop
                             check, but logic lives here).

    These run BEFORE the main rotation loop each tick, so a mid-fight Mimicry
    re-cast preempts a damage spell.
================================================================================
]]

local self = GBLU
self.Modes = self.Modes or {}
local Modes = self.Modes

local Data    = self.Data
local H       = self.Helpers
local Runtime = self.Runtime
local Logic   = self.Logic

-- Throttled helpers
local function throttled(stamp, intervalMs)
    return TimeSince(stamp or 0) >= intervalMs
end

-- ============================================================================
-- Aetherial Mimicry
-- ----------------------------------------------------------------------------
-- Behavior (user spec):
--   * Mimicry mode is a CHOICE (Off / DPS / Tank / Healer).
--   * When set to anything other than Off, ACR auto-targets the NEAREST
--     party member with that role and casts Aetherial Mimicry on them.
--   * Skip silently if no matching ally is in range (solo / wrong duty).
--   * Don't recast if we already have the buff for that role.
-- ============================================================================

function Modes.UpdateMimicry()
    local mode = self.Settings.Mimicry.Mode
    if mode == "Off" then return end

    local mimicryAct = Runtime.ActionByName["Aetherial Mimicry"]
    if not mimicryAct then return end                                 -- haven't learned it

    local interval = self.Settings.Mimicry.RecastInterval or 4000
    if not throttled(Runtime.lastMimicryAttempt, interval) then return end

    local player = Player

    -- Already in the desired stance? Done.
    local buffMap = {
        DPS    = Data.Buffs.AetherialMimicryDPS,
        Tank   = Data.Buffs.AetherialMimicryTank,
        Healer = Data.Buffs.AetherialMimicryHealer,
    }
    local wantBuff = buffMap[mode]
    if wantBuff and H.HasBuff(player, wantBuff) then return end

    -- Find nearest party member with that role
    local target = H.NearestPartyMemberByRole(mode, 25)
    if not target then return end

    -- Action must be off cooldown
    if H.CD(mimicryAct.id) > 1500 then return end

    -- Don't try to Mimicry during a cast - lets the active cast finish
    if MIsCasting() then return end

    Runtime.lastMimicryAttempt = Now()
    mimicryAct:Cast(target.id)
end

-- ============================================================================
-- Stance buffs (Mighty Guard / Basic Instinct)
-- ----------------------------------------------------------------------------
-- Mighty Guard is a toggle and persists. Basic Instinct only works solo.
-- Logic:
--   - If Tank Mimicry + UseMightyGuardTank: ensure Mighty Guard up.
--   - If solo + UseBasicInstinctSolo: ensure Basic Instinct up
--       AND auto-toggle Mighty Guard ON (negates BI's defense penalty).
--   - Otherwise: turn Mighty Guard OFF if it's on (-40% damage hurts).
-- ============================================================================

function Modes.UpdateStanceBuffs()
    if not self.Settings.Modes.Defensives then return end

    local player = Player
    local mgAct  = Runtime.ActionByName["Mighty Guard"]
    local biAct  = Runtime.ActionByName["Basic Instinct"]

    if not throttled(Runtime.lastStanceAttempt, 3000) then return end

    local wantMG = false
    local wantBI = false

    if self.Settings.Mimicry.Mode == "Tank" and self.Settings.UseMightyGuardTank then
        wantMG = true
    end

    if self.Settings.UseBasicInstinctSolo and H.IsSolo() then
        wantBI = true
        wantMG = true              -- Basic Instinct negates MG damage penalty
    end

    local hasMG = H.HasBuff(player, Data.Buffs.MightyGuard)
    local hasBI = H.HasBuff(player, Data.Buffs.BasicInstinct)

    -- Toggle Mighty Guard
    if mgAct and H.CD(mgAct.id) <= 1500 then
        if wantMG and not hasMG then
            Runtime.lastStanceAttempt = Now()
            mgAct:Cast(player.id)
            return
        end
        if not wantMG and hasMG then
            Runtime.lastStanceAttempt = Now()
            mgAct:Cast(player.id)   -- toggle off
            return
        end
    end

    -- Apply Basic Instinct
    if wantBI and biAct and not hasBI and H.CD(biAct.id) <= 1500 then
        -- Only fire BI in actual solo content (verified by IsSolo).
        Runtime.lastStanceAttempt = Now()
        biAct:Cast(player.id)
        return
    end
end

-- ============================================================================
-- Smart Diamondback trigger
-- ----------------------------------------------------------------------------
-- Heuristic (user said "use whenever makes the most sense"):
--   Fire Diamondback if ALL of:
--     1) Mode.Defensives is on.
--     2) Settings.DiamondbackAuto is true.
--     3) Diamondback is off cooldown (within precast).
--     4) Player HP < DiamondbackHpThreshold (default 70%) OR an enemy is
--        casting a known dangerous action.
--     5) Either:
--          a) An enemy is casting and (cast time remaining < DiamondbackPrecastMs)
--             AND that enemy targets the player, OR
--          b) The casting enemy's action ID is in DiamondbackTriggerIDs.
--   The user can hand-curate DiamondbackTriggerIDs (Carnivale tankbusters etc).
-- ============================================================================

function Modes.ShouldFireDiamondback()
    if not self.Settings.Modes.Defensives then return false end
    if not self.Settings.DiamondbackAuto then return false end

    local db = Runtime.ActionByName["Diamondback"]
    if not db then return false end
    if H.CD(db.id) > self.Settings.PrecastTime then return false end

    local player = Player
    if H.HasBuff(player, Data.Buffs.Diamondback) then return false end

    -- Don't waste it healing-bot: skip if HP is full and no scary cast
    local pct = (player.hp.current / player.hp.max) * 100

    -- Look for dangerous enemy cast
    local el = H.EnemyList(40)
    if not H.valid(el) then return false end

    local triggerSet = {}
    for _, id in ipairs(self.Settings.DiamondbackTriggerIDs or {}) do
        triggerSet[id] = true
    end

    local precastMs = self.Settings.DiamondbackPrecastMs or 1200

    for _, e in pairs(el) do
        if e.castinginfo and e.castinginfo.castingid and e.castinginfo.castingid ~= 0 then
            local ci = e.castinginfo
            local castingId = ci.castingid
            local remaining = (ci.casttime - ci.channeltime) * 1000
            local targetsMe = (ci.targetid == player.id) or (e.targetid == player.id)

            -- Whitelisted action ID always fires Diamondback
            if triggerSet[castingId] then
                if remaining > 200 and remaining < precastMs then
                    return true
                end
            end

            -- Heuristic: cast time >= 2s, targets player, HP already below threshold
            if remaining > 200 and remaining < precastMs and targetsMe then
                if pct < self.Settings.DiamondbackHpThreshold then
                    return true
                end
                -- Solo / Carnivale: any 2s+ cast targeting us is suspicious
                if H.IsSolo() and ci.casttime >= 2.0 then return true end
            end
        end
    end

    return false
end

function Modes.UpdateDefensives()
    if Modes.ShouldFireDiamondback() then
        local db = Runtime.ActionByName["Diamondback"]
        if db then
            db:Cast(Player.id)
            Runtime.lastDiamondback = Now()
            Runtime.LastAttempt[db.id] = Now()
            return true
        end
    end
    return false
end

-- ============================================================================
-- Gobskin pre-cast (Healer mode utility)
-- ============================================================================

function Modes.UpdateGobskin()
    if not self.Settings.Modes.Healing then return false end
    local gob = Runtime.ActionByName["Gobskin"]
    if not gob then return false end
    if H.CD(gob.id) > 1500 then return false end

    local player = Player
    local galvanizeRem = H.BuffRemainingMs(player, 1873)
    if galvanizeRem < 30000 then
        gob:Cast(player.id)
        Runtime.LastAttempt[gob.id] = Now()
        return true
    end
    return false
end

-- ============================================================================
-- Carnivale helpers - used by ActionLogic for Ram's Voice / Ultravibration
-- (declared in Logic.lua). Modes also drives auto-Swiftcast for the combo.
-- ============================================================================

function Modes.UpdateCarnivaleHelpers()
    if not self.Settings.Modes.Carnivale then return end
    if not self.Settings.Carnivale.VibeCheck then return end

    -- Vibe Check Swiftcast prep: if Ultravibration off CD, target is solo elite,
    -- and we're not currently casting, pre-cast Swiftcast then chain Ram's Voice.
    local sc = Runtime.ActionByName["Swiftcast"]
    local ram = Runtime.ActionByName["Ram's Voice"]
    local ultra = Runtime.ActionByName["Ultravibration"]
    if not (sc and ram and ultra) then return end

    if H.CD(ultra.id) > 5000 then return end
    if H.CD(sc.id) > 1500 then return end
    if H.HasBuff(Player, Data.Buffs.Swiftcast) then return end
    if MIsCasting() then return end

    local target = Logic.GetTarget()
    if not target or not H.HpAdvantage(target) then return end
    if H.HasBuff(target, Data.Buffs.DeepFreeze) then return end

    -- Only fire if Ram's Voice will follow immediately
    if H.CD(ram.id) > 1500 then return end

    sc:Cast(Player.id)
    Runtime.lastSwiftCast = Now()
    Runtime.LastAttempt[sc.id] = Now()
end

-- ============================================================================
-- Interrupt / stun / dispel / esuna handlers
-- These have first-class priority in the rotation but live here for clarity.
-- ============================================================================

function Modes.UpdateInterrupts()
    if not self.Settings.Modes.Interrupts then return end
    local sound = Runtime.ActionByName["Eerie Soundwave"]
    if not sound or H.CD(sound.id) > 1500 then return end

    local interruptSet = {}
    for _, id in ipairs(self.Settings.InterruptIDs or {}) do interruptSet[id] = true end

    local el = H.EnemyList(20)
    if not H.valid(el) then return end

    for _, e in pairs(el) do
        if e.castinginfo and e.castinginfo.castingid ~= 0 then
            local castingId = e.castinginfo.castingid
            if interruptSet[castingId] then
                if e.id ~= Runtime.lastInterruptTarget then
                    Runtime.lastInterruptTarget = e.id
                    sound:Cast(e.id)
                    Runtime.LastAttempt[sound.id] = Now()
                    return
                end
            end
        end
    end
end

function Modes.UpdateStuns()
    if not self.Settings.Modes.Stuns then return end

    -- Try Perpetual Ray first (ignores resist), then Faze, Sticky Tongue, Bomb Toss
    local stunOptions = { "Perpetual Ray", "Faze", "Sticky Tongue", "Bomb Toss" }

    local stunSet = {}
    for _, id in ipairs(self.Settings.StunCastingIDs or {}) do stunSet[id] = true end

    local el = H.EnemyList(20)
    if not H.valid(el) then return end

    for _, e in pairs(el) do
        if e.castinginfo and e.castinginfo.castingid ~= 0 then
            if stunSet[e.castinginfo.castingid] then
                if e.id ~= Runtime.lastStunTarget then
                    for _, name in ipairs(stunOptions) do
                        local act = Runtime.ActionByName[name]
                        if act and act.usable and H.CD(act.id) <= 1500 then
                            Runtime.lastStunTarget = e.id
                            act:Cast(e.id)
                            Runtime.LastAttempt[act.id] = Now()
                            return
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- Entry point - called from Grims Blue Mage.lua's OnUpdate.
-- This is the "stuff that runs every tick BEFORE the main cast loop".
-- ============================================================================

function Modes.Tick()
    -- Defensives run first - Diamondback is highest priority when triggered
    if Modes.UpdateDefensives() then return true end

    -- Interrupts / stuns are time-sensitive
    Modes.UpdateInterrupts()
    Modes.UpdateStuns()

    -- Carnivale combo prep (Swiftcast before Ram's Voice)
    Modes.UpdateCarnivaleHelpers()

    -- Gobskin pre-shielding
    Modes.UpdateGobskin()

    return false
end

return Modes
