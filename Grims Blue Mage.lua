--[[
================================================================================
    Grim's Blue Mage ACR
    A modern (L80) Combat Routine for FFXIVMinion / MMOMinion.

    Architecture:
      - This file is the entry point that MMOMinion's ACR loader picks up.
      - Submodules live in a sibling folder of the same name and are loaded
        via dofile() at OnLoad time.
      - All submodules attach themselves to the GBLU global table so any
        module can reach any other through GBLU.<Module>.

    Submodules:
      Data.lua      - Spell registry, buff IDs, CD groups, level gates.
      Helpers.lua   - Geometry, validators, distance, HP-advantage helpers.
      Logic.lua     - Rotation engine, priority list, ActionLogic[] functions.
      Modes.lua     - Mimicry, Defensive (Diamondback / Mighty Guard /
                      Basic Instinct), Healing, Carnivale primitives.
      UI.lua        - Main config window, on-screen toggle row, optional
                      in-game hotbar.

    Inspired by structure from Kali's Blue Mage ACR (KaliMinion/Blue-Mage-ACR)
    but rewritten from scratch against current MMOMinion API and the modern
    L80 Blue Mage spell list.
================================================================================
]]

GBLU = {
    isPVE      = true,
    isPVP      = false,
    ispve      = true,
    ispvp      = false,
    NAME_SHORT = "GBLU",
    NAME_LONG  = "Grims Blue Mage",
    VERSION    = "1.0.0",
}

local self     = GBLU
local selfs    = self.NAME_SHORT
local selflong = self.NAME_LONG

-- ----------------------------------------------------------------------------
-- Path resolution
-- ----------------------------------------------------------------------------

local MinionPath    = GetStartupPath()
local LuaPath       = GetLuaModsPath()
self.ModulePath     = LuaPath .. [[ACR\CombatRoutines\]] .. selflong .. [[\]]
self.ModuleSettings = self.ModulePath .. [[Settings.lua]]
self.ImageFolder    = self.ModulePath .. [[Images\]]

-- ----------------------------------------------------------------------------
-- Job binding
-- ----------------------------------------------------------------------------

self.classes = {
    [FFXIV.JOBS.BLUEMAGE] = true,   -- 36
}

-- ----------------------------------------------------------------------------
-- Runtime state - everything mutable, non-persisted, lives in Data
-- (NOT to be confused with the Data MODULE which is the static spell registry)
-- ----------------------------------------------------------------------------

self.Runtime = {
    InitTime          = 0,
    Loaded            = false,
    LastHotbarCheck   = 0,

    -- Action tables populated from ActionList at OnLoad
    Action            = {},     -- [id] = action object
    ActionByName      = {},     -- [name] = action object (case-sensitive)
    ActionLogic       = {},     -- [id] = function() -> shouldCast, target, pos
    AvailableSpells   = {},     -- [id] = true for spells the player has learned

    -- Cast bookkeeping
    LastCast          = {},     -- [id] = Now() of last successful cast
    LastAttempt       = {},     -- [id] = Now() of last attempted cast
    lastcast          = 0,      -- last successful oGCD id
    lastGCDcast       = 0,      -- last successful GCD id
    lastSwiftCast     = 0,
    lastBristle       = 0,
    lastWhistle       = 0,
    lastTingle        = 0,
    lastMoonFlute     = 0,
    lastDiamondback   = 0,
    lastMimicry       = 0,
    lastMightyGuard   = 0,
    lastInterruptTarget = 0,
    lastStunTarget    = 0,

    -- Battle state: 0=OOC, 1=OOC w/ target in combat, 2=GCD, 3=oGCD1, 4=oGCD2, 5=oGCD3
    BattleState       = 0,

    -- Moon Flute window: nil/false = not in window, "waxing" = burst, "waning" = locked
    MoonFluteState    = false,
    MoonFluteStart    = 0,

    -- Movement bookkeeping
    Moving            = false,
    LastMove          = 0,
    LastStop          = 0,
    LastCombat        = 0,

    -- Hotbar / on-screen toggles
    Hotbar            = {},
    HotbarDisabled    = {},
    HotbarQueued      = {},

    -- GUI scratch
    CurrentActionSelectedIndex = 0,
    CurrentActionSelected      = 0,
}

local Runtime = self.Runtime

-- ----------------------------------------------------------------------------
-- GUI shell state (the actual rendering happens in UI.lua)
-- ----------------------------------------------------------------------------

self.GUI = {
    open    = false,
    visible = true,
    name    = selflong,
    WindowStyle = {
        ["WindowBg"]            = { 18, 14, 36, 0.92 },
        ["TitleBg"]             = { 28, 22, 56, 0.95 },
        ["TitleBgActive"]       = { 60, 44, 110, 1.00 },
        ["FrameBg"]             = { 42, 31, 80, 0.85 },
        ["FrameBgHovered"]      = { 68, 54, 120, 0.90 },
        ["FrameBgActive"]       = { 110, 86, 180, 0.95 },
        ["Button"]              = { 42, 31, 80, 0.85 },
        ["ButtonHovered"]       = { 68, 54, 120, 0.90 },
        ["ButtonActive"]        = { 110, 86, 180, 0.95 },
        ["CheckMark"]           = { 179, 154, 220, 1.00 },
        ["SliderGrab"]          = { 110, 86, 180, 0.90 },
        ["SliderGrabActive"]    = { 179, 154, 220, 1.00 },
        ["Header"]              = { 60, 44, 110, 0.85 },
        ["HeaderHovered"]       = { 80, 60, 140, 0.90 },
        ["HeaderActive"]        = { 110, 86, 180, 1.00 },
        ["ScrollbarBg"]         = { 28, 22, 56, 0.85 },
        ["ScrollbarGrab"]       = { 60, 44, 110, 0.90 },
        ["ScrollbarGrabHovered"]= { 80, 60, 140, 0.95 },
        ["ScrollbarGrabActive"] = { 110, 86, 180, 1.00 },
        ["ResizeGrip"]          = { 42, 31, 80, 0.75 },
        ["ResizeGripHovered"]   = { 68, 54, 120, 0.85 },
        ["ResizeGripActive"]    = { 110, 86, 180, 1.00 },
    },
}

-- ----------------------------------------------------------------------------
-- Default settings (per-user persisted via FileSave / FileLoad)
-- These are merged with any saved values at OnLoad.
-- ----------------------------------------------------------------------------

self.Settings = {
    open               = false,

    -- Global cadence
    ActionDelay        = 500,   -- ms between same-action attempts
    PrecastTime        = 250,   -- ms before cooldown expires that we may start a cast
    SlideCastTime      = 490,   -- ms of slide-cast tolerance

    -- ---------------- Mode toggles (the floating on-screen row) -----------
    Modes = {
        DPS            = true,
        AoE            = true,           -- engages AoE branch when AoEThreshold+ enemies
        Healing        = false,          -- party heals via BLU heals
        Defensives     = true,           -- Diamondback / Mighty Guard / Basic Instinct
        Carnivale      = false,
        Interrupts     = true,
        Stuns          = true,
        Magical        = true,
        Physical       = true,
        LowChance      = false,          -- gates Missile / Tail Screw / Doom
        HpAdvantage    = true,           -- gate damage on player>>target HP ratio
    },

    -- ---------------- Mimicry --------------------------------------------
    -- "Off" = never apply, "DPS"/"Tank"/"Healer" = apply matching role pre-combat,
    -- targeting the NEAREST party member with that role.
    Mimicry = {
        Mode            = "DPS",          -- "Off" | "DPS" | "Tank" | "Healer"
        RecastInterval  = 4000,           -- ms throttle on Mimicry re-cast attempts
    },

    -- ---------------- Combat conditions ----------------------------------
    AoEThreshold        = 3,              -- enemy count at which AoE branch fires
    MoonFluteAuto       = true,           -- auto-open burst window when CDs align
    DotRefreshMs        = 3000,           -- refresh DoT when remaining < this
    UseFinalStingAuto   = false,          -- per user: manual only
    UseBasicInstinctSolo= true,
    UseMightyGuardTank  = true,           -- when Mimicry==Tank or solo with Basic Instinct

    -- ---------------- Healing thresholds (% of max) ----------------------
    PlayerCurePercent      = 60,
    TankCurePercent        = 70,
    PartyCurePercent       = 50,
    PartyAoECurePercent    = 70,
    PlayerRestoreMpPercent = 15,
    CureOutsideParty       = false,
    RaiseOutsideParty      = false,

    -- ---------------- HP advantage gates ---------------------------------
    HpAdvSolo  = 1,
    HpAdvParty = 3,

    -- ---------------- Defensive auto-Diamondback -------------------------
    -- Smart trigger: fire Diamondback if any enemy in 25y is casting an action
    -- and (a) cast time remaining < DiamondbackPrecastMs and we're the target,
    -- or (b) it's an action ID in DiamondbackTriggerIDs (hand-curated big hits).
    DiamondbackAuto         = true,
    DiamondbackPrecastMs    = 1200,
    DiamondbackHpThreshold  = 70,   -- only fire if player HP < this (avoid wasting 2-min CD)
    DiamondbackTriggerIDs   = {},   -- user-editable enemy-action ID whitelist

    -- ---------------- Interrupt / stun / dispel / esuna ------------------
    InterruptIDs = { 14265, 14365, 14369, 14680, 14712, 14720, 14744, 14890,
                     15045, 15049, 15063, 15318, 15321 },
    StunCastingIDs = { 14753 },
    DispelIDs    = { 63, 1797 },
    EsunaIDs     = { 14, 271, 564, 700 },

    -- ---------------- Carnivale (Vibe Check etc.) ------------------------
    Carnivale = {
        VibeCheck         = true,         -- Swiftcast -> Ram's Voice -> Ultravibration on frozenable mob
        DoomCheese        = false,        -- Try Doom on bosses that don't resist
        MissileCheese     = false,        -- Try Missile (10% hit) on % HP gates
        TailScrewCheese   = false,
    },

    -- ---------------- Drawing -------------------------------------------
    DrawToggles            = true,
    DrawHotbar             = true,
    DrawCone               = false,
    DrawNearbyEnemyCircles = true,

    HotbarSettings = {
        Columns               = 12,
        HorizontalSpacing     = 6,
        VerticalSpacing       = 6,
        BackgroundTransparency= 115,
        ButtonWidth           = 42,
        ButtonHeight          = 45,
        WindowPadding         = 14,
        CheckUpdateInterval   = 5000,
    },

    ToggleSettings = {
        Columns               = 5,
        HorizontalSpacing     = 3,
        VerticalSpacing       = 5,
        BackgroundTransparency= 115,
        ButtonWidth           = 110,
        ButtonHeight          = 30,
        EnabledColor          = { r = 0,  g = 110, b = 0,  a = 200 },
        DisabledColor         = { r = 90, g = 0,   b = 0,  a = 200 },
    },

    -- ---------------- Per-action enable + priority ----------------------
    -- These are populated by Logic.lua at OnLoad from the spell registry.
    -- Saved/loaded so the user can re-order in the Actions tab.
    Actions          = {},        -- [id] = bool enabled
    ActionPriority   = {},        -- ordered list of action IDs
    ActionDelays     = {},        -- [id] = per-action ms delay override
    ActionData       = {},        -- [id] = { CanTargetSelf=..., CanTargetParty=..., CanTargetHostile=..., TargetArea=..., AttackTypeTargetID=... }
    ActionLogicSrc   = {},        -- [id] = string source of user-edited logic (loadstring'd at OnLoad)
}

-- ----------------------------------------------------------------------------
-- Logger - prefixed wrapper around d() and ml_error()
-- ----------------------------------------------------------------------------

function self.Log(msg)
    d("[" .. selflong .. "] " .. tostring(msg))
end

function self.Err(msg)
    ml_error("[" .. selflong .. "] " .. tostring(msg))
end

local Log = self.Log
local Err = self.Err

-- ----------------------------------------------------------------------------
-- Module loader
-- ----------------------------------------------------------------------------

function self.LoadModules()
    if not FolderExists(self.ModulePath) then
        FolderCreate(self.ModulePath)
    end

    local function safeDofile(name)
        local path = self.ModulePath .. name .. [[.lua]]
        if FileExists(path) then
            local ok, err = pcall(dofile, path)
            if not ok then
                Err("Failed to load " .. name .. ": " .. tostring(err))
                return false
            end
            return true
        else
            Err("Missing module file: " .. path)
            return false
        end
    end

    -- Order matters: Data is the foundation, everything else depends on it.
    safeDofile("Data")
    safeDofile("Helpers")
    safeDofile("Logic")
    safeDofile("Modes")
    safeDofile("UI")
end

-- ----------------------------------------------------------------------------
-- Settings persistence
-- ----------------------------------------------------------------------------

local PreviousSave, lastSaveCheck = {}, 0

function self.SaveSettings(force)
    if force or TimeSince(lastSaveCheck) > 5000 then
        lastSaveCheck = Now()
        if not table.deepcompare(self.Settings, PreviousSave) then
            FileSave(self.ModuleSettings, self.Settings)
            PreviousSave = table.deepcopy(self.Settings)
        end
    end
end

function self.LoadSettings()
    if not FileExists(self.ModuleSettings) then return end
    local saved = FileLoad(self.ModuleSettings)
    if not saved or type(saved) ~= "table" then return end

    local function deepMerge(target, source)
        for k, v in pairs(source) do
            if type(v) == "table" and type(target[k]) == "table" then
                deepMerge(target[k], v)
            else
                target[k] = v
            end
        end
    end

    deepMerge(self.Settings, saved)
end

-- ----------------------------------------------------------------------------
-- ACR loader hooks - called by MMOMinion's framework
-- ----------------------------------------------------------------------------

function self.OnLoad()
    -- Module bootstrap
    self.LoadModules()
    self.LoadSettings()

    -- Populate the runtime action tables from the live game action list.
    -- This is delegated to Logic so it can also build the priority list.
    if self.Logic and self.Logic.RefreshActions then
        self.Logic.RefreshActions()
    end

    -- Compile any user-edited per-action logic source back into functions.
    if self.Settings.ActionLogicSrc then
        for id, src in pairs(self.Settings.ActionLogicSrc) do
            if type(src) == "string" and src ~= "" then
                local fn, err = loadstring(src)
                if fn then Runtime.ActionLogic[id] = fn
                else Err("Bad logic source for [" .. id .. "]: " .. tostring(err)) end
            end
        end
    end

    self.GUI.open = self.Settings.open
    if self.UI and self.UI.OnLoad then self.UI.OnLoad() end

    Runtime.Loaded = true
    Log("Loaded v" .. self.VERSION)
end

function self.OnOpen()
    self.GUI.open = not self.GUI.open
    self.Settings.open = self.GUI.open
    if self.Logic and self.Logic.RefreshActions then
        self.Logic.RefreshActions()
    end
end

function self.OnUpdate(event, tickcount)
    if not Runtime.Loaded then return end
    local player = Player
    if not player or player.job ~= FFXIV.JOBS.BLUEMAGE then return end
    if gACRSelectedProfiles and gACRSelectedProfiles[player.job] ~= selflong then return end

    -- 1. Refresh action availability every few seconds (player may learn new spells).
    if TimeSince(Runtime.LastHotbarCheck) > (self.Settings.HotbarSettings.CheckUpdateInterval or 5000) then
        Runtime.LastHotbarCheck = Now()
        if self.Logic and self.Logic.RefreshActions then self.Logic.RefreshActions() end
    end

    -- 2. Mode-driven pre-combat / utility (Mimicry, Mighty Guard, Basic Instinct).
    if self.Modes then
        if self.Modes.UpdateMimicry        then self.Modes.UpdateMimicry()        end
        if self.Modes.UpdateStanceBuffs    then self.Modes.UpdateStanceBuffs()    end
    end

    -- 3. Time-sensitive defensive / interrupt / stun handlers.
    --    Returns true if a cast was issued, in which case we skip the main loop
    --    this tick to let the cast resolve.
    if self.Modes and self.Modes.Tick then
        if self.Modes.Tick() then return end
    end

    -- 4. Main combat cast loop.
    if self.Logic and self.Logic.Cast then self.Logic.Cast() end

    -- 5. Persist settings throttled.
    self.SaveSettings()
end

function self.Draw()
    if self.UI and self.UI.Draw then self.UI.Draw() end
end

-- ----------------------------------------------------------------------------
-- Cast-completion detection (slide-cast aware)
-- Updates LastCast[id] / lastGCDcast / lastcast when a real cast lands.
-- Registered globally so it runs regardless of selected ACR (cheap no-op when off-job).
-- ----------------------------------------------------------------------------

function self.CastCheck()
    if not Runtime.Loaded then return end
    local player = Player
    if not player or player.job ~= FFXIV.JOBS.BLUEMAGE then return end
    if gACRSelectedProfiles and gACRSelectedProfiles[player.job] ~= selflong then return end

    local cinfo = player.castinginfo
    local current = cinfo.castingid
    local channelling = cinfo.channelingid
    local id = (current ~= 0 and current) or (channelling ~= 0 and channelling) or 0
    if id == 0 then return end

    local SlideCastTime = self.Settings.SlideCastTime
    local timeLeft = cinfo.casttime - cinfo.channeltime
    local last = Runtime.LastCast[id] or 0

    if TimeSince(last) > SlideCastTime and timeLeft < (SlideCastTime / 1000) then
        local act = ActionList:Get(1, id)
        if act and act ~= 0 then
            if act.cooldowngroup == 58 then
                Runtime.lastGCDcast = id
            else
                Runtime.lastcast = id
            end
            Runtime.LastCast[id] = Now()

            -- Track specific buff-prepend casts for the rotation engine.
            if id == 7561  then Runtime.lastSwiftCast = Now() end          -- Swiftcast
            -- Bristle, Whistle, Tingle, Moon Flute, Diamondback, Mimicry IDs
            -- get tagged in Logic.lua via Data.SpellRegistry name lookup.
            if self.Logic and self.Logic.OnCastLanded then
                self.Logic.OnCastLanded(id)
            end

            -- Clear hotbar queued state if applicable
            Runtime.HotbarQueued[id] = false
            local Hotbar = Runtime.Hotbar
            for i = 1, #Hotbar do
                if Hotbar[i].id == id then Hotbar[i].clicked = false end
            end
        end
    end
end

RegisterEventHandler("Gameloop.Update", self.CastCheck, selfs .. " Cast Check")

-- ----------------------------------------------------------------------------
-- Return the module table - MMOMinion's loader uses this to identify the ACR
-- ----------------------------------------------------------------------------

return GBLU
