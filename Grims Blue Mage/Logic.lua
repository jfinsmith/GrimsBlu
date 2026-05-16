--[[
================================================================================
    Grim's Blue Mage ACR - Logic Module
    The rotation engine.

    Responsibilities:
      * RefreshActions  - Walk ActionList, match action names against the
                          spell registry, populate Runtime.Action /
                          ActionLogic / Settings.Actions / ActionPriority.
      * BuildLogic      - Per-spell logic functions (returns shouldCast,
                          target, pos) generated from registry metadata.
      * Cast            - Main per-tick loop: walk priority, prepend
                          buffs as needed, cast first valid action.
      * Moon Flute window state machine.
      * Buff-prepend handlers for Bristle / Whistle / Tingle / Swiftcast.
================================================================================
]]

local self = GBLU
self.Logic = self.Logic or {}
local Logic = self.Logic

local Data    = self.Data
local H       = self.Helpers
local Runtime = self.Runtime

-- Pull these locals once to reduce table indexing in the tight Cast loop
local valid       = H.valid
local Distance3D  = H.Distance3D
local HpAdvantage = H.HpAdvantage
local HasBuff     = H.HasBuff
local MissingBuff = H.MissingBuff
local CD          = H.CD

-- ============================================================================
-- Action discovery + registry resolution
-- Walks ActionList:Get(1), keeps every entry whose job is 36 (BLU base) or
-- 255 (BLU spell pool) or 0 (cross-class role actions used by BLU).
-- ============================================================================

function Logic.RefreshActions()
    local actions = ActionList:Get(1)
    if not actions then return end

    -- Clear old name index (action IDs may shift if spell pool changes)
    Runtime.ActionByName = {}

    for _, v in pairs(actions) do
        local id, job, usable, name = v.id, v.job, v.usable, v.name
        if id and name then
            local isBlu  = (job == 36 or job == 255)
            local isRole = (job == 0 and name == "Swiftcast")
            if isBlu or isRole then
                Runtime.Action[id] = v
                Runtime.Action[id].name = name
                Runtime.ActionByName[name] = v

                if usable then
                    Runtime.AvailableSpells[id] = true
                end

                -- First-time registration into Settings
                local registry = Data.FindByName(name)
                if registry then
                    Runtime.Action[id].registry = registry

                    -- Default enable: respect DisabledByDefault list
                    if self.Settings.Actions[id] == nil then
                        local off = Data.DisabledByDefault[name]
                        self.Settings.Actions[id] = (off == nil)
                    end

                    -- Default target flags from registry.target
                    if not self.Settings.ActionData[id] then
                        local t = registry.target or {}
                        self.Settings.ActionData[id] = {
                            CanTargetSelf     = t.selfp   == true,
                            CanTargetParty    = t.party   == true,
                            CanTargetFriendly = t.friend  == true,
                            CanTargetHostile  = t.hostile == true,
                            TargetArea        = t.area    == true,
                            AffectsPosition   = t.affectsPos == true,
                            AttackTypeTargetID = (registry.aspect == "magical") and 5 or 1,
                        }
                    end

                    -- Build the logic function if user hasn't overridden it
                    if not Runtime.ActionLogic[id] then
                        Runtime.ActionLogic[id] = Logic.BuildLogic(name, registry, id)
                    end
                end
            end
        end
    end

    -- Build / refresh the priority list from DefaultPriority, preserving
    -- any user re-ordering already stored in Settings.ActionPriority.
    Logic.RebuildPriority()
end

function Logic.RebuildPriority()
    local existing = self.Settings.ActionPriority or {}
    local seen = {}
    for i = 1, #existing do seen[existing[i]] = true end

    -- First, drop any priorities whose action isn't registered
    local cleaned = {}
    for i = 1, #existing do
        local id = existing[i]
        if Runtime.Action[id] then cleaned[#cleaned + 1] = id end
    end

    -- Then append any registry spells we have but aren't in the priority list,
    -- in the order defined by Data.DefaultPriority.
    for _, name in ipairs(Data.DefaultPriority) do
        local act = Runtime.ActionByName[name]
        if act and not seen[act.id] then
            cleaned[#cleaned + 1] = act.id
            seen[act.id] = true
        end
    end

    self.Settings.ActionPriority = cleaned
end

-- ============================================================================
-- Target selection
-- ============================================================================

function Logic.GetTarget()
    local t = MGetTarget()
    if valid(t) and t.attackable and t.hp and t.hp.current > 0 then
        return t
    end
    return nil
end

-- ============================================================================
-- Moon Flute window state machine
-- Reads buff state each tick.
-- ============================================================================

function Logic.UpdateBurstWindow()
    local player = Player
    if HasBuff(player, Data.Buffs.MoonFluteWaxing) then
        Runtime.MoonFluteState = "waxing"
    elseif HasBuff(player, Data.Buffs.MoonFluteWaning) then
        Runtime.MoonFluteState = "waning"
    else
        Runtime.MoonFluteState = false
    end
end

function Logic.InBurstWindow()    return Runtime.MoonFluteState == "waxing" end
function Logic.InWaningWindow()   return Runtime.MoonFluteState == "waning" end

-- Should we trigger Moon Flute right now?
-- Auto-fire only if MoonFluteAuto is on, we're in combat with valid target,
-- and at least 2 of the major 2-min damage CDs are off cooldown.
function Logic.ShouldOpenBurst()
    if not self.Settings.MoonFluteAuto then return false end
    if not self.Settings.Modes.DPS then return false end
    if Logic.InBurstWindow() or Logic.InWaningWindow() then return false end

    local target = Logic.GetTarget()
    if not target then return false end
    if not HpAdvantage(target) then return false end

    -- Only open if Bristle is up and ready - the window collapses without it.
    local bristle = Runtime.ActionByName["Bristle"]
    if not bristle or CD(bristle.id) > 1500 then
        -- Bristle not ready; skip unless we have Boost up.
        if MissingBuff(Player, Data.Buffs.Boost) then return false end
    end

    -- Count how many 2-min CDs are ready
    local readyHeavies = 0
    local heavies = { "Matra Magic", "Nightbloom", "Both Ends",
                      "Phantom Flurry", "Sea Shanty", "Being Mortal",
                      "Apokalypsis", "Triple Trident" }
    for _, name in ipairs(heavies) do
        local a = Runtime.ActionByName[name]
        if a and a.usable and CD(a.id) <= 1500 then
            readyHeavies = readyHeavies + 1
        end
    end

    return readyHeavies >= 2
end

-- ============================================================================
-- Buff prepend helpers - given an action ID, do we need to fire a buff first?
-- ============================================================================

function Logic.NeedsBristleBefore(id)
    local act = Runtime.Action[id]
    if not act or not act.registry then return false end
    local reg = act.registry
    if reg.prepend ~= "bristle" and reg.prepend ~= "whistle_tingle" then
        if reg.prepend == "bristle_whistle" then return true end
        return false
    end
    if reg.aspect == "physical" then return false end           -- Bristle is for spells, Whistle is for physical
    return MissingBuff(Player, Data.Buffs.Boost)
end

function Logic.NeedsWhistleBefore(id)
    local act = Runtime.Action[id]
    if not act or not act.registry then return false end
    local reg = act.registry
    if reg.prepend ~= "whistle" and reg.prepend ~= "whistle_tingle" then return false end
    if reg.aspect ~= "physical" then return false end
    return MissingBuff(Player, Data.Buffs.Whistle)
end

function Logic.NeedsTingleBefore(id)
    local act = Runtime.Action[id]
    if not act or not act.registry then return false end
    local reg = act.registry
    if reg.prepend ~= "whistle_tingle" then return false end
    return MissingBuff(Player, Data.Buffs.Tingling)
end

function Logic.NeedsSwiftcastBefore(id)
    -- Only relevant for cast-time spells while moving
    local act = Runtime.Action[id]
    if not act then return false end
    local castTime = act.casttime or 0
    if castTime == 0 then return false end
    if not MIsMoving() then return false end
    return MissingBuff(Player, Data.Buffs.Swiftcast)
end

-- ============================================================================
-- Cooldown group blocking
-- Returns true if another spell sharing this spell's CD group has been used
-- recently and is still on shared cooldown.
-- ============================================================================

function Logic.CDGroupBlocked(name, registry)
    if not registry or not registry.cdGroup then return false end
    local members = Data.CDGroups[registry.cdGroup]
    if not members then return false end

    for _, otherName in ipairs(members) do
        if otherName ~= name then
            local otherAct = Runtime.ActionByName[otherName]
            if otherAct and CD(otherAct.id) > 1500 then
                return true
            end
        end
    end
    return false
end

-- ============================================================================
-- Generic per-spell logic builder
-- Returns a function that the Cast loop will invoke.
-- The function returns (shouldCast, target, pos).
-- ============================================================================

function Logic.BuildLogic(name, registry, id)
    local category = registry.category

    -- ----- SUICIDE SPELLS - never auto-fire (per user preference) -----
    if registry.manualOnly or category == "suicide" then
        return function() return false end
    end

    -- ----- INSTAKILL / LOW-CHANCE - gated by LowChance toggle -----
    if registry.gateLowChance then
        return function()
            if not self.Settings.Modes.LowChance then return false end
            local target = Logic.GetTarget()
            if not target or not HpAdvantage(target) then return false, nil end
            if registry.aspect == "magical" and MissingBuff(Player, Data.Buffs.Boost) then
                -- Doom + Bristle for magical instakill spells
                if Runtime.ActionByName["Bristle"] and CD(Runtime.ActionByName["Bristle"].id) <= 1500 then
                    -- Let bristle-prepend handle it
                end
            end
            return true, target
        end
    end

    -- ----- VIBE CHECK COMBO (Carnivale mode) -----
    if registry.special == "vibe_freeze" then
        return function()
            if not self.Settings.Modes.Carnivale or not self.Settings.Carnivale.VibeCheck then
                return false
            end
            local target = Logic.GetTarget()
            if not target or not HpAdvantage(target) then return false, nil end
            -- Only cast Ram's Voice if Ultravibration is ready and target not already frozen
            local ultra = Runtime.ActionByName["Ultravibration"]
            if not ultra or CD(ultra.id) > 5000 then return false, nil end
            if HasBuff(target, Data.Buffs.DeepFreeze) then return false, nil end
            return true, target
        end
    end

    if registry.special == "vibe_kill" then
        return function()
            if not self.Settings.Modes.Carnivale or not self.Settings.Carnivale.VibeCheck then
                return false
            end
            local target = Logic.GetTarget()
            if not target then return false, nil end
            if not HasBuff(target, Data.Buffs.DeepFreeze) then return false, nil end
            return true, target
        end
    end

    -- ----- HEALS - gated by Healing mode + thresholds -----
    if category == "heal" then
        return function()
            if not self.Settings.Modes.Healing then return false end

            local s = self.Settings
            local player = Player

            -- White Wind: self heal when low + AoE pressure
            if name == "White Wind" then
                local pct = (player.hp.current / player.hp.max) * 100
                if pct > s.PlayerCurePercent then return false end
                return true, player
            end

            -- Stotram: AoE heal when 3+ party low
            if name == "Stotram" then
                local members = H.GetPartyMembers()
                local low = 0
                for i = 1, #members do
                    local m = members[i]
                    if (m.hp.current / m.hp.max) * 100 < s.PartyAoECurePercent then
                        low = low + 1
                    end
                end
                if low >= 3 then return true, player end
                return false
            end

            -- Pom Cure: single-target heal (party or self)
            if name == "Pom Cure" then
                -- Self priority
                local ppct = (player.hp.current / player.hp.max) * 100
                if ppct < s.PlayerCurePercent then return true, player end

                -- Lowest party member
                local members = H.GetPartyMembers()
                local worst, worstPct = nil, 100
                for i = 1, #members do
                    local m = members[i]
                    if m.id ~= player.id then
                        local pct = (m.hp.current / m.hp.max) * 100
                        local thr = (H.GetRoleFromJob(m.job) == "Tank") and s.TankCurePercent or s.PartyCurePercent
                        if pct < thr and pct < worstPct then
                            worst, worstPct = m, pct
                        end
                    end
                end
                if worst then return true, worst end
                return false
            end

            -- Gobskin: stack shields on self when shielded shorter than 30s
            if name == "Gobskin" then
                local rem = H.BuffRemainingMs(player, 1873)   -- Galvanize
                if rem < 30000 then return true, player end
                return false
            end

            -- Angel's Snack: AoE regen when ~2+ low
            if name == "Angel's Snack" then
                local members = H.GetPartyMembers()
                local low = 0
                for i = 1, #members do
                    if (members[i].hp.current / members[i].hp.max) * 100 < s.PartyCurePercent then
                        low = low + 1
                    end
                end
                if low >= 2 then return true, player end
                return false
            end

            -- Exuviation: TODO esuna mapping (just fire on debuff for now)
            if name == "Exuviation" then
                return false
            end

            -- Angel Whisper: raise; let Modes handle - default off
            if name == "Angel Whisper" then return false end

            return false
        end
    end

    -- ----- BUFF / STANCE - handled by Modes module, not the priority list -----
    if category == "stance" then
        return function() return false end
    end

    -- ----- BURST WINDOW OPENER (Moon Flute) -----
    if category == "burst_window" then
        return function()
            if not Logic.ShouldOpenBurst() then return false end
            return true, Player
        end
    end

    -- ----- DEBUFFS (Off-guard / Peculiar Light) -----
    if category == "debuff" then
        return function()
            if not self.Settings.Modes.DPS then return false end
            local target = Logic.GetTarget()
            if not target or not HpAdvantage(target) then return false, nil end
            -- Prefer Peculiar Light when burst is magical & in window
            if Logic.CDGroupBlocked(name, registry) then return false, nil end
            -- Maintain uptime: re-apply when target debuff missing
            if name == "Off-guard" and HasBuff(target, Data.Buffs.OffGuard) then return false, nil end
            if name == "Peculiar Light" and HasBuff(target, Data.Buffs.PeculiarLight) then return false, nil end
            return true, target
        end
    end

    -- ----- DEFENSIVE (handled by Modes for Diamondback, but Mighty Guard etc here is no-op) -----
    if category == "defensive" then
        if registry.special == "diamondback" then
            return function() return false end          -- Modes.UpdateDefensives handles it
        end
        if name == "Dragon Force" then
            return function()
                if not self.Settings.Modes.Defensives then return false end
                if not self.Settings.Modes.Healing then return false end
                -- Fire when at least 2 party members below 70%
                local members = H.GetPartyMembers()
                local low = 0
                for i = 1, #members do
                    if (members[i].hp.current / members[i].hp.max) * 100 < 70 then
                        low = low + 1
                    end
                end
                if low >= 2 then return true, Player end
                return false
            end
        end
        return function() return false end
    end

    -- ----- DAMAGE / DOT / UTILITY (the main rotation body) -----
    if category == "damage" or category == "dot" or category == "utility" or category == "buff" then
        return function()
            local s = self.Settings
            if category == "damage" or category == "dot" then
                if not s.Modes.DPS then return false end
            end
            if registry.aspect == "magical" and not s.Modes.Magical then return false end
            if registry.aspect == "physical" and not s.Modes.Physical then return false end

            -- Buffs are gated by the prepend system - don't auto-cast Bristle alone
            if category == "buff" and registry.prependKey then
                -- Buff prepend handled in main Cast loop; allow standalone only if
                -- about to fall off and we're in combat
                local target = Logic.GetTarget()
                if not target then return false end
                if not HpAdvantage(target) then return false, nil end
                -- Bristle: only fire if we have a bristle-tagged high-priority spell ready
                if name == "Bristle" then
                    if not Logic.AnyBristleConsumerReady() then return false, nil end
                    if HasBuff(Player, Data.Buffs.Boost) then return false, nil end
                    return true, Player
                end
                if name == "Whistle" then
                    if not Logic.AnyWhistleConsumerReady() then return false, nil end
                    if HasBuff(Player, Data.Buffs.Whistle) then return false, nil end
                    return true, Player
                end
                if name == "Tingle" then
                    if not Logic.AnyTingleConsumerReady() then return false, nil end
                    if HasBuff(Player, Data.Buffs.Tingling) then return false, nil end
                    return true, Player
                end
                if name == "Swiftcast" then
                    -- Fire Swiftcast if a cast-time spell will go next while moving
                    if not MIsMoving() then return false end
                    if HasBuff(Player, Data.Buffs.Swiftcast) then return false end
                    return true, Player
                end
                return false
            end

            -- Damage / DoT / utility shared body
            local target = Logic.GetTarget()
            if not target then return false end
            if not HpAdvantage(target) then return false, nil end

            -- Range check (handled by Cast loop too, but cheap to check here)
            local range = (registry.range or 25)
            if Distance3D(Player, target) > (range + 2) then return false, nil end

            -- Shared CD group exclusivity
            if Logic.CDGroupBlocked(name, registry) then return false, nil end

            -- DoT-only: skip if already applied and plenty of duration left
            if category == "dot" then
                local dotBuffId = Data.Buffs[registry.dotBuff or ""]
                if dotBuffId then
                    local rem = H.BuffRemainingMs(target, dotBuffId)
                    if rem > self.Settings.DotRefreshMs then return false, nil end
                end
                -- Mortal Flame is one-per-target permanent
                if name == "Mortal Flame" and HasBuff(target, Data.Buffs.BleedingMortalFlame) then
                    return false, nil
                end
            end

            -- AoE branch: skip ST damage spells if mob count >= threshold and an AoE alt exists
            if registry.target and registry.target.area then
                -- Ground-target AoE: prefer when N+ enemies clustered around target
                local count = H.CountAroundTarget(target, range, registry.radius or 5)
                if count < self.Settings.AoEThreshold then return false, nil end
                local pos = target.pos
                return true, target, pos
            end

            -- AoE damage threshold for non-area spells (Quasar / J Kick / Glass Dance / Sea Shanty / Stotram damage / Being Mortal)
            local aoeSpells = { ["Quasar"]=true, ["J Kick"]=true, ["Glass Dance"]=true,
                                ["Sea Shanty"]=true, ["Being Mortal"]=true, ["Apokalypsis"]=true,
                                ["Hydro Pull"]=true, ["Eerie Soundwave"]=true }
            if aoeSpells[name] and self.Settings.Modes.AoE then
                -- These are powerful single-target too; require AoEThreshold only for the "pure AoE" subset
                local pureAoE = { ["Glass Dance"]=true, ["Hydro Pull"]=true, ["Eerie Soundwave"]=true }
                if pureAoE[name] then
                    local count = H.CountAroundTarget(target, range, registry.radius or 5)
                    if count < self.Settings.AoEThreshold then return false, nil end
                end
            end

            -- Surpanakha 4-stack handling
            if registry.special == "surpanakha_stack" then
                local act = Runtime.ActionByName[name]
                if not act then return false end
                -- Only burn stacks inside burst window OR when about to cap
                local lastAttempt = TimeSince(Runtime.LastAttempt[act.id] or 0)
                if Logic.InBurstWindow() or (act.cd == 0 and lastAttempt < 1250) then
                    return true, target
                end
                -- Cap protection: if all 4 charges + close to next refresh, dump
                if act.cdmax > 0 and act.cd > 30 and lastAttempt < 1250 then
                    return true, target
                end
                if not Logic.InBurstWindow() then return false, nil end
                return true, target
            end

            -- Burst-only spells (heavy hitters): conserve for Moon Flute window
            local burstOnly = { ["Triple Trident"]=true, ["Matra Magic"]=true,
                                ["Phantom Flurry"]=true, ["Apokalypsis"]=true,
                                ["Being Mortal"]=true, ["Sea Shanty"]=true,
                                ["Both Ends"]=true, ["Nightbloom"]=true }
            if burstOnly[name] then
                -- If we're outside a burst window AND Moon Flute is close to ready, hold
                local mf = Runtime.ActionByName["Moon Flute"]
                local mfReady = mf and CD(mf.id) <= 8000
                if not Logic.InBurstWindow() and mfReady and self.Settings.MoonFluteAuto then
                    return false, nil
                end
                -- During Waning - cannot cast anyway, returns false harmlessly
                if Logic.InWaningWindow() then return false, nil end
            end

            -- Magic Hammer: refresh self MP when low
            if name == "Magic Hammer" then
                local mp = Player.mp
                if mp and mp.max > 0 then
                    local pct = (mp.current / mp.max) * 100
                    if pct >= 75 then return false, nil end
                end
            end

            return true, target
        end
    end

    -- Default: never cast
    return function() return false end
end

-- ============================================================================
-- Bristle / Whistle / Tingle "consumer ready" predicates.
-- Used to decide whether to PREEMPTIVELY cast the buff.
-- ============================================================================

function Logic.AnyBristleConsumerReady()
    local priority = self.Settings.ActionPriority
    for i = 1, #priority do
        local id = priority[i]
        local act = Runtime.Action[id]
        if act and act.registry and act.registry.prepend == "bristle"
                and self.Settings.Actions[id]
                and act.usable and CD(id) <= 1500 then
            return true
        end
    end
    return false
end

function Logic.AnyWhistleConsumerReady()
    local priority = self.Settings.ActionPriority
    for i = 1, #priority do
        local id = priority[i]
        local act = Runtime.Action[id]
        if act and act.registry then
            local p = act.registry.prepend
            if (p == "whistle" or p == "whistle_tingle")
                    and self.Settings.Actions[id]
                    and act.usable and CD(id) <= 1500 then
                return true
            end
        end
    end
    return false
end

function Logic.AnyTingleConsumerReady()
    local priority = self.Settings.ActionPriority
    for i = 1, #priority do
        local id = priority[i]
        local act = Runtime.Action[id]
        if act and act.registry and act.registry.prepend == "whistle_tingle"
                and self.Settings.Actions[id]
                and act.usable and CD(id) <= 1500 then
            return true
        end
    end
    return false
end

-- ============================================================================
-- Battle state probe
-- ============================================================================

function Logic.UpdateBattleState()
    local player = Player
    local delay = self.Settings.ActionDelay
    local precast = self.Settings.PrecastTime

    -- Use Water Cannon (first BLU spell, almost always learned) as GCD probe;
    -- fallback to any spell we know about with cooldowngroup==58 if not.
    local probe = Runtime.ActionByName["Water Cannon"] or Runtime.ActionByName["Sonic Boom"]
    if not probe then
        -- Pick any GCD spell we know
        for id, a in pairs(Runtime.Action) do
            if a.cooldowngroup == 58 then probe = a; break end
        end
    end

    local target = MGetTarget()
    if gStartCombat or player.incombat then
        if probe and CD(probe.id) < precast then
            Runtime.BattleState = 2     -- GCD ready
        else
            local cd = probe and probe.cd or 0
            if cd < delay/1000 then Runtime.BattleState = 3
            elseif cd < (delay*2)/1000 then Runtime.BattleState = 4
            else Runtime.BattleState = 5 end
        end
    else
        if valid(target) and target.incombat then Runtime.BattleState = 1
        else Runtime.BattleState = 0 end
    end
end

-- ============================================================================
-- Cast a single action with correct target type
-- Returns true if a cast was issued.
-- ============================================================================

function Logic.IssueCast(id, target, pos)
    local act = Runtime.Action[id] or ActionList:Get(1, id)
    if not act then return false end

    local data = self.Settings.ActionData[id]
    local Self     = data and data.CanTargetSelf     or false
    local Party    = data and data.CanTargetParty    or false
    local Friendly = data and data.CanTargetFriendly or false
    local Hostile  = data and data.CanTargetHostile  or false
    local Area     = data and data.TargetArea        or false

    if valid(pos) and pos.x and Area then
        act:Cast(pos.x, pos.y, pos.z)
        Runtime.LastAttempt[id] = Now()
        return true
    end

    if valid(target) then
        local tid = target.id
        local ttype = target.chartype
        if ttype == 5 or (target.attackable and Hostile) then
            if Hostile and tid then
                act:Cast(tid)
                Runtime.LastAttempt[id] = Now()
                return true
            end
            if Area and target.pos then
                act:Cast(target.pos.x, target.pos.y, target.pos.z)
                Runtime.LastAttempt[id] = Now()
                return true
            end
        end
        if (ttype == 2 or ttype == 4) then
            if Self and tid == Player.id then
                act:Cast(tid)
                Runtime.LastAttempt[id] = Now()
                return true
            end
            if Party and tid then
                act:Cast(tid)
                Runtime.LastAttempt[id] = Now()
                return true
            end
            if Friendly and tid then
                act:Cast(tid)
                Runtime.LastAttempt[id] = Now()
                return true
            end
        end
    elseif Self then
        act:Cast(Player.id)
        Runtime.LastAttempt[id] = Now()
        return true
    end

    return false
end

-- ============================================================================
-- Main per-tick cast loop
-- ============================================================================

local lastFrame = 0

function Logic.Cast()
    Logic.UpdateBattleState()
    Logic.UpdateBurstWindow()

    local player = Player
    local now    = Now()
    local moving = player:IsMoving()
    if Runtime.Moving ~= moving then
        Runtime.Moving = moving
        if moving then Runtime.LastMove = now else Runtime.LastStop = now end
    end
    if player.incombat then Runtime.LastCombat = now end

    -- During Diamondback - we are locked. Don't even iterate.
    if HasBuff(player, Data.Buffs.Diamondback) then return end

    -- During Moon Flute Waning - locked from actions. Skip the loop.
    if Logic.InWaningWindow() then return end

    local cinfo   = player.castinginfo
    local castingNow = cinfo.castingid
    local channeling = cinfo.channelingid
    local timeLeft = cinfo.casttime - cinfo.channeltime
    local delay    = self.Settings.ActionDelay
    local precast  = self.Settings.PrecastTime

    local frame = GUI:GetFrameCount()
    if frame == lastFrame then return end
    lastFrame = frame

    -- Bail if a cast is in progress and time-left exceeds our delay tolerance
    if MIsCasting() and timeLeft >= (delay / 1000) then return end

    -- Out-of-combat: still allow stance/utility (handled in Modes)
    if Runtime.BattleState == 0 then return end

    -- ------------------------------------------------------------
    -- Smart buff prepend: walk priority looking for the first ENABLED
    -- ACTION whose logic returns true. If that action needs Bristle/
    -- Whistle/Tingle/Swiftcast first, we cast THAT instead.
    -- ------------------------------------------------------------
    local priority = self.Settings.ActionPriority
    for i = 1, #priority do
        local id = priority[i]
        local act = Runtime.Action[id]
        if not act or not self.Settings.Actions[id] then goto continue end
        if Runtime.HotbarDisabled[id] then goto continue end

        -- Per-action delay cap
        local lastAttempt = TimeSince(Runtime.LastAttempt[id] or 0)
        local actionDelay = self.Settings.ActionDelays[id] or 0
        if lastAttempt < actionDelay then goto continue end

        -- CD gate (allow casting slightly before CD ends within precast window)
        local cdMs = CD(id)
        if cdMs > (precast * 2 + delay) then goto continue end

        -- Castable while moving? Only if instant or has Swiftcast
        local castTime = act.casttime or 0
        local hasSwift = HasBuff(player, Data.Buffs.Swiftcast)
        if castTime ~= 0 and MIsMoving() and not hasSwift then goto continue end

        -- Usable?
        if not act.usable then goto continue end

        local logic = Runtime.ActionLogic[id]
        if not logic then goto continue end

        local ok, target, pos = logic()
        if not ok then goto continue end

        -- Defensive damage-down checks (don't waste casts on resistant targets)
        local data = self.Settings.ActionData[id]
        if data and target then
            if data.AttackTypeTargetID == 5 then
                if HasBuff(target, Data.Buffs.MagicDamageDown) then goto continue end
            else
                if HasBuff(target, Data.Buffs.PhysDamageDown) then goto continue end
            end
        end

        -- Buff prepend check - if this action needs a buff, fire the buff first
        if Logic.NeedsSwiftcastBefore(id) then
            local sc = Runtime.ActionByName["Swiftcast"]
            if sc and CD(sc.id) <= precast then
                sc:Cast(player.id)
                Runtime.lastSwiftCast = now
                Runtime.LastAttempt[sc.id] = now
                return
            end
            -- Swiftcast not ready - skip this action unless it's instant or we stopped moving
            if castTime > 0 and MIsMoving() then goto continue end
        end

        if Logic.NeedsBristleBefore(id) then
            local br = Runtime.ActionByName["Bristle"]
            if br and CD(br.id) <= precast and Runtime.lastcast ~= 18323 then    -- not after Surpanakha
                br:Cast(player.id)
                Runtime.lastBristle = now
                Runtime.LastAttempt[br.id] = now
                return
            end
            goto continue
        end

        if Logic.NeedsWhistleBefore(id) then
            local wh = Runtime.ActionByName["Whistle"]
            if wh and CD(wh.id) <= precast then
                wh:Cast(player.id)
                Runtime.lastWhistle = now
                Runtime.LastAttempt[wh.id] = now
                return
            end
            goto continue
        end

        if Logic.NeedsTingleBefore(id) then
            local tg = Runtime.ActionByName["Tingle"]
            if tg and CD(tg.id) <= precast then
                tg:Cast(player.id)
                Runtime.lastTingle = now
                Runtime.LastAttempt[tg.id] = now
                return
            end
            -- Tingle is optional - proceed without it if not ready
        end

        -- Issue the cast
        if Logic.IssueCast(id, target, pos) then return end

        ::continue::
    end
end

-- ============================================================================
-- Cast-landed hook from Grims Blue Mage.lua's CastCheck
-- ============================================================================

function Logic.OnCastLanded(id)
    local act = Runtime.Action[id]
    if not act or not act.registry then return end
    local name = act.name
    if name == "Bristle"       then Runtime.lastBristle      = Now() end
    if name == "Whistle"       then Runtime.lastWhistle      = Now() end
    if name == "Tingle"        then Runtime.lastTingle       = Now() end
    if name == "Moon Flute"    then Runtime.lastMoonFlute    = Now() end
    if name == "Diamondback"   then Runtime.lastDiamondback  = Now() end
    if name == "Aetherial Mimicry" then Runtime.lastMimicry  = Now() end
    if name == "Mighty Guard"  then Runtime.lastMightyGuard  = Now() end
end

return Logic
