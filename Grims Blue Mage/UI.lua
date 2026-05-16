--[[
================================================================================
    Grim's Blue Mage ACR - UI Module
    The user-facing config window and on-screen toggle row.

    Layout:
      Main window (tabbed):
        General      - timing, draw toggles, healing thresholds
        Modes        - Mimicry radio, on/off toggles, AoE threshold
        Rotation     - Moon Flute auto, DoT refresh window
        Actions      - per-spell enable, drag-reorder priority
        Defensive    - Diamondback whitelist, interrupt/stun/dispel/esuna lists
        Carnivale    - Vibe Check, Doom/Missile/Tail Screw

      Toggle row (floating, on-screen):
        Quick on/off for major mode flags. Click to toggle.

    The hotbar rendering from Kali's ACR is intentionally deferred to v1.1 -
    it's ~600 lines of pixel-pushing and not core to combat.
================================================================================
]]

local self = GBLU
self.UI = self.UI or {}
local UI = self.UI

local Data    = self.Data
local H       = self.Helpers
local Runtime = self.Runtime
local Logic   = self.Logic

-- ============================================================================
-- Style helpers
-- ============================================================================

local function pushTheme()
    local style = self.GUI.WindowStyle
    local count = 0
    for k, v in pairs(style) do
        if v[4] ~= 0 then
            count = count + 1
            local ok, err = pcall(function()
                GUI:PushStyleColor(GUI["Col_" .. k], v[1]/255, v[2]/255, v[3]/255, v[4])
            end)
        end
    end
    return count
end

local function popTheme(count)
    if count > 0 then GUI:PopStyleColor(count) end
end

local function space(x, y)
    GUI:SameLine(y or 0, x or 0)
end

-- A right-padded text label paired with an input
local function labeledInput(label, value, width, flags)
    GUI:Text(label)
    space(8)
    GUI:PushItemWidth(width or 60)
    local val, changed = GUI:InputText("##" .. label, tostring(value), flags or GUI.InputTextFlags_CharsDecimal)
    GUI:PopItemWidth()
    return val, changed
end

local function intInput(label, current, width, min, max)
    local val, changed = labeledInput(label, current, width or 60)
    if changed and val ~= "" then
        local n = tonumber(val)
        if n and (not min or n >= min) and (not max or n <= max) then
            return n, true
        end
    end
    return current, false
end

-- Convert a list of numeric IDs to comma-separated string and back
local function idsToString(tbl)
    if not tbl or #tbl == 0 then return "" end
    local out = {}
    for i = 1, #tbl do out[i] = tostring(tbl[i]) end
    return table.concat(out, ",")
end

local function parseIds(str)
    local out = {}
    for w in str:gmatch("[^,]+") do
        local n = tonumber(w)
        if n then out[#out + 1] = n end
    end
    return out
end

-- Count entries in a hash-keyed table (#tbl only works on array-style tables)
local function tableCount(tbl)
    local c = 0
    for _ in pairs(tbl) do c = c + 1 end
    return c
end

-- ============================================================================
-- Tabs
-- ============================================================================

function UI.OnLoad()
    self.GUI.main_tabs = GUI_CreateTabs(
        "General,Modes,Rotation,Actions,Defensive,Carnivale",
        true
    )
end

-- ----------------------------------------------------------------------------
-- TAB: General
-- ----------------------------------------------------------------------------

function UI.DrawGeneralTab()
    GUI:Text("Cadence")
    GUI:Separator()

    local v, c = intInput("Action Delay (ms)", self.Settings.ActionDelay, 60, 100, 2000)
    if c then self.Settings.ActionDelay = v end
    space(20)
    local v, c = intInput("Precast (ms)", self.Settings.PrecastTime, 60, 50, 800)
    if c then self.Settings.PrecastTime = v end
    space(20)
    local v, c = intInput("Slide-Cast (ms)", self.Settings.SlideCastTime, 60, 100, 800)
    if c then self.Settings.SlideCastTime = v end

    GUI:Text("")
    GUI:Text("Drawing")
    GUI:Separator()

    self.Settings.DrawToggles = GUI:Checkbox("Draw Mode Toggle Row", self.Settings.DrawToggles)
    space(20)
    self.Settings.DrawHotbar = GUI:Checkbox("Draw Hotbar (deferred to v1.1)", self.Settings.DrawHotbar)

    self.Settings.DrawNearbyEnemyCircles = GUI:Checkbox("Draw Enemy Range Circles", self.Settings.DrawNearbyEnemyCircles)
    space(20)
    self.Settings.DrawCone = GUI:Checkbox("Draw Cone Debug", self.Settings.DrawCone)

    GUI:Text("")
    GUI:Text("Healing thresholds (% of max HP)")
    GUI:Separator()

    local v, c = intInput("Self Cure %",   self.Settings.PlayerCurePercent,    50, 0, 100)
    if c then self.Settings.PlayerCurePercent = v end
    space(15)
    local v, c = intInput("Tank Cure %",   self.Settings.TankCurePercent,     50, 0, 100)
    if c then self.Settings.TankCurePercent = v end
    space(15)
    local v, c = intInput("Party Cure %",  self.Settings.PartyCurePercent,    50, 0, 100)
    if c then self.Settings.PartyCurePercent = v end
    space(15)
    local v, c = intInput("AoE Cure %",    self.Settings.PartyAoECurePercent, 50, 0, 100)
    if c then self.Settings.PartyAoECurePercent = v end

    self.Settings.CureOutsideParty = GUI:Checkbox("Cure Outside Party", self.Settings.CureOutsideParty)
    space(20)
    self.Settings.RaiseOutsideParty = GUI:Checkbox("Raise Outside Party", self.Settings.RaiseOutsideParty)
end

-- ----------------------------------------------------------------------------
-- TAB: Modes
-- ----------------------------------------------------------------------------

local mimicryOptions = "Off,DPS,Tank,Healer"
local mimicryIndex = { Off = 0, DPS = 1, Tank = 2, Healer = 3 }
local mimicryByIndex = { [0] = "Off", [1] = "DPS", [2] = "Tank", [3] = "Healer" }

function UI.DrawModesTab()
    GUI:Text("Aetherial Mimicry")
    GUI:Separator()

    local current = mimicryIndex[self.Settings.Mimicry.Mode] or 0
    GUI:PushItemWidth(120)
    local idx, changed = GUI:Combo("Mimicry Mode", current, mimicryOptions)
    GUI:PopItemWidth()
    if changed then self.Settings.Mimicry.Mode = mimicryByIndex[idx] or "Off" end

    GUI:Text("Auto-targets the nearest party member of the chosen role.")
    GUI:Text("Set to 'Off' to never apply Mimicry.")

    local v, c = intInput("Re-cast attempt interval (ms)", self.Settings.Mimicry.RecastInterval, 80, 1000, 10000)
    if c then self.Settings.Mimicry.RecastInterval = v end

    GUI:Text("")
    GUI:Text("Combat modes")
    GUI:Separator()

    self.Settings.Modes.DPS         = GUI:Checkbox("DPS",           self.Settings.Modes.DPS)
    space(20)
    self.Settings.Modes.AoE         = GUI:Checkbox("AoE",           self.Settings.Modes.AoE)
    space(20)
    self.Settings.Modes.Healing     = GUI:Checkbox("Healing",       self.Settings.Modes.Healing)
    space(20)
    self.Settings.Modes.Defensives  = GUI:Checkbox("Defensives",    self.Settings.Modes.Defensives)

    self.Settings.Modes.Carnivale   = GUI:Checkbox("Carnivale",     self.Settings.Modes.Carnivale)
    space(20)
    self.Settings.Modes.Interrupts  = GUI:Checkbox("Interrupts",    self.Settings.Modes.Interrupts)
    space(20)
    self.Settings.Modes.Stuns       = GUI:Checkbox("Stuns",         self.Settings.Modes.Stuns)
    space(20)
    self.Settings.Modes.HpAdvantage = GUI:Checkbox("HP Advantage",  self.Settings.Modes.HpAdvantage)

    self.Settings.Modes.Magical     = GUI:Checkbox("Magical",       self.Settings.Modes.Magical)
    space(20)
    self.Settings.Modes.Physical    = GUI:Checkbox("Physical",      self.Settings.Modes.Physical)
    space(20)
    self.Settings.Modes.LowChance   = GUI:Checkbox("Low Chance (Missile/Doom/etc)", self.Settings.Modes.LowChance)

    GUI:Text("")
    GUI:Text("Stance options")
    GUI:Separator()

    self.Settings.UseBasicInstinctSolo = GUI:Checkbox("Use Basic Instinct when solo", self.Settings.UseBasicInstinctSolo)
    space(20)
    self.Settings.UseMightyGuardTank   = GUI:Checkbox("Use Mighty Guard (Tank/Solo)", self.Settings.UseMightyGuardTank)

    GUI:Text("")
    GUI:Text("AoE")
    GUI:Separator()
    local v, c = intInput("AoE Threshold (enemies)", self.Settings.AoEThreshold, 60, 1, 20)
    if c then self.Settings.AoEThreshold = v end
end

-- ----------------------------------------------------------------------------
-- TAB: Rotation
-- ----------------------------------------------------------------------------

function UI.DrawRotationTab()
    GUI:Text("Burst window")
    GUI:Separator()

    self.Settings.MoonFluteAuto = GUI:Checkbox("Auto-fire Moon Flute window", self.Settings.MoonFluteAuto)
    GUI:Text("When on, Moon Flute opens automatically once Bristle and 2+ heavy")
    GUI:Text("cooldowns (Matra, Nightbloom, Trident, Sea Shanty, etc.) are ready.")

    GUI:Text("")
    GUI:Text("DoTs")
    GUI:Separator()
    local v, c = intInput("DoT Refresh Window (ms)", self.Settings.DotRefreshMs, 70, 500, 10000)
    if c then self.Settings.DotRefreshMs = v end
    GUI:Text("Refresh DoTs (Song of Torment, Nightbloom, Breath of Magic) when remaining < this.")

    GUI:Text("")
    GUI:Text("Final Sting")
    GUI:Separator()
    GUI:Text("Final Sting is MANUAL ONLY - the ACR will never auto-fire it.")
    GUI:Text("It remains in the Actions list as disabled for hotbar / manual use.")

    GUI:Text("")
    GUI:Text("Current state")
    GUI:Separator()
    local mfState = Runtime.MoonFluteState or "none"
    GUI:Text("Moon Flute window: " .. tostring(mfState))
    GUI:Text("Battle state: " .. tostring(Runtime.BattleState))
end

-- ----------------------------------------------------------------------------
-- TAB: Actions (drag to reorder priority, click to enable/disable)
-- ----------------------------------------------------------------------------

function UI.DrawActionsTab()
    local priority = self.Settings.ActionPriority or {}
    local size = #priority

    -- Header bar
    GUI:Text(string.format("Spells registered: %d   Priority entries: %d", tableCount(Runtime.Action), size))
    if GUI:Button("Reset priority to defaults") then
        self.Settings.ActionPriority = {}
        Logic.RebuildPriority()
    end
    space(15)
    if GUI:Button("Enable all") then
        for _, id in ipairs(priority) do self.Settings.Actions[id] = true end
    end
    space(8)
    if GUI:Button("Disable all") then
        for _, id in ipairs(priority) do self.Settings.Actions[id] = false end
    end

    GUI:Separator()

    -- Compute widest entry for sizing
    local maxLabelWidth = 0
    for i = 1, size do
        local id = priority[i]
        local act = Runtime.Action[id]
        if act then
            local label = string.format("%d: %s [%d]", i, act.name or "?", id)
            local x, _ = GUI:CalcTextSize(label)
            if x > maxLabelWidth then maxLabelWidth = x end
        end
    end

    local style = GUI:GetStyle()
    GUI:PushItemWidth(maxLabelWidth + style.itemspacing.x + style.framepadding.x + style.scrollbarsize)
    local _, y = GUI:GetContentRegionAvail()
    local rows = math.floor((y - 8) / GUI:GetTextLineHeightWithSpacing())
    if rows < 10 then rows = 10 end
    GUI:ListBoxHeader("##Actions", size, rows)

    local selectedIdx = Runtime.CurrentActionSelectedIndex or 0
    for i = 1, size do
        local id = priority[i]
        local act = Runtime.Action[id]
        if act then
            local enabled = self.Settings.Actions[id] ~= false
            if enabled then
                GUI:PushStyleColor(GUI.Col_Text, 217/255, 230/255, 235/255, 1)
            else
                GUI:PushStyleColor(GUI.Col_Text, 217/255, 230/255, 235/255, 0.55)
            end

            local sel = (selectedIdx == i)
            local label = string.format("%d: %s [%d]##%d", i, act.name or "?", id, id)
            if GUI:Selectable(label, sel) then
                Runtime.CurrentActionSelectedIndex = i
                Runtime.CurrentActionSelected = id
            end
            GUI:PopStyleColor()
        end
    end
    GUI:ListBoxFooter()
    GUI:PopItemWidth()

    -- Right-side controls for selected action
    if Runtime.CurrentActionSelected and Runtime.CurrentActionSelected ~= 0 then
        local id = Runtime.CurrentActionSelected
        local act = Runtime.Action[id]
        if act then
            GUI:Separator()
            GUI:Text("Selected: " .. (act.name or "?") .. " [" .. id .. "]")

            local enabled = self.Settings.Actions[id] ~= false
            local newEnabled = GUI:Checkbox("Enabled##" .. id, enabled)
            if newEnabled ~= enabled then self.Settings.Actions[id] = newEnabled end

            space(20)
            if GUI:Button("Move Up") and Runtime.CurrentActionSelectedIndex > 1 then
                local idx = Runtime.CurrentActionSelectedIndex
                self.Settings.ActionPriority[idx], self.Settings.ActionPriority[idx - 1] =
                    self.Settings.ActionPriority[idx - 1], self.Settings.ActionPriority[idx]
                Runtime.CurrentActionSelectedIndex = idx - 1
            end
            space(8)
            if GUI:Button("Move Down") and Runtime.CurrentActionSelectedIndex < #self.Settings.ActionPriority then
                local idx = Runtime.CurrentActionSelectedIndex
                self.Settings.ActionPriority[idx], self.Settings.ActionPriority[idx + 1] =
                    self.Settings.ActionPriority[idx + 1], self.Settings.ActionPriority[idx]
                Runtime.CurrentActionSelectedIndex = idx + 1
            end

            -- Per-action delay
            local d = self.Settings.ActionDelays[id] or 0
            local v, c = intInput("Per-action delay (ms)", d, 70, 0, 60000)
            if c then self.Settings.ActionDelays[id] = v end

            local reg = act.registry
            if reg then
                GUI:Text("Tier: " .. (reg.tier or "?") .. "  Category: " .. (reg.category or "?")
                       .. "  Aspect: " .. (reg.aspect or "?"))
                if reg.notes then GUI:Text(reg.notes) end
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- TAB: Defensive
-- ----------------------------------------------------------------------------

function UI.DrawDefensiveTab()
    GUI:Text("Diamondback")
    GUI:Separator()
    self.Settings.DiamondbackAuto = GUI:Checkbox("Auto-Diamondback", self.Settings.DiamondbackAuto)

    local v, c = intInput("Precast window (ms)",     self.Settings.DiamondbackPrecastMs,   70, 200, 5000)
    if c then self.Settings.DiamondbackPrecastMs = v end
    space(15)
    local v, c = intInput("HP threshold % (heuristic)", self.Settings.DiamondbackHpThreshold, 60, 0, 100)
    if c then self.Settings.DiamondbackHpThreshold = v end

    GUI:Text("Diamondback fires when an enemy targets you with a 2s+ cast and either")
    GUI:Text("your HP is below threshold, OR the action ID is on the whitelist below.")

    GUI:Text("")
    GUI:Text("Diamondback action-ID whitelist (always fires):")
    local str = idsToString(self.Settings.DiamondbackTriggerIDs)
    local val, changed = GUI:InputText("##DBWhitelist", str)
    if changed then self.Settings.DiamondbackTriggerIDs = parseIds(val) end

    GUI:Text("")
    GUI:Text("Interrupt / Stun / Dispel / Esuna lists")
    GUI:Separator()

    GUI:Text("Interrupt IDs (Eerie Soundwave):")
    local str = idsToString(self.Settings.InterruptIDs)
    local val, changed = GUI:InputText("##InterruptIDs", str)
    if changed then self.Settings.InterruptIDs = parseIds(val) end

    GUI:Text("Stun-target casting IDs (Perpetual Ray/Faze):")
    local str = idsToString(self.Settings.StunCastingIDs)
    local val, changed = GUI:InputText("##StunIDs", str)
    if changed then self.Settings.StunCastingIDs = parseIds(val) end

    GUI:Text("Dispel buff IDs:")
    local str = idsToString(self.Settings.DispelIDs)
    local val, changed = GUI:InputText("##DispelIDs", str)
    if changed then self.Settings.DispelIDs = parseIds(val) end

    GUI:Text("Esuna debuff IDs:")
    local str = idsToString(self.Settings.EsunaIDs)
    local val, changed = GUI:InputText("##EsunaIDs", str)
    if changed then self.Settings.EsunaIDs = parseIds(val) end
end

-- ----------------------------------------------------------------------------
-- TAB: Carnivale
-- ----------------------------------------------------------------------------

function UI.DrawCarnivaleTab()
    GUI:Text("Masked Carnivale primitives")
    GUI:Separator()

    self.Settings.Carnivale.VibeCheck = GUI:Checkbox("Vibe Check combo (Swiftcast + Ram's Voice + Ultravibration)",
                                                      self.Settings.Carnivale.VibeCheck)

    self.Settings.Carnivale.DoomCheese      = GUI:Checkbox("Doom (LowChance must also be on)",      self.Settings.Carnivale.DoomCheese)
    space(15)
    self.Settings.Carnivale.MissileCheese   = GUI:Checkbox("Missile",   self.Settings.Carnivale.MissileCheese)
    space(15)
    self.Settings.Carnivale.TailScrewCheese = GUI:Checkbox("Tail Screw", self.Settings.Carnivale.TailScrewCheese)

    GUI:Text("")
    GUI:Text("Final Sting: MANUAL ONLY (per your config). Add to hotbar to use.")
    GUI:Text("Self-destruct: also manual-only.")

    GUI:Text("")
    GUI:Text("Carnivale tips")
    GUI:Separator()
    GUI:Text("- Set Carnivale mode ON in the Modes tab to enable Vibe Check chain.")
    GUI:Text("- For tankbuster stages, add the boss-cast action ID to the Diamondback whitelist.")
    GUI:Text("- Stages that allow Doom: enable in Modes tab (LowChance) + here.")
end

-- ============================================================================
-- Floating toggle row
-- ============================================================================

local toggleDefs = {
    { key = "DPS",         label = "DPS"        },
    { key = "AoE",         label = "AoE"        },
    { key = "Healing",     label = "Heal"       },
    { key = "Defensives",  label = "Defensives" },
    { key = "Carnivale",   label = "Carnivale"  },
    { key = "Interrupts",  label = "Interrupt"  },
    { key = "Stuns",       label = "Stun"       },
    { key = "HpAdvantage", label = "HpAdv"      },
    { key = "Magical",     label = "Magical"    },
    { key = "Physical",    label = "Physical"   },
    { key = "LowChance",   label = "LowChance"  },
}

function UI.DrawToggleRow()
    if not self.Settings.DrawToggles then return end
    if not gACRSelectedProfiles or gACRSelectedProfiles[FFXIV.JOBS.BLUEMAGE] ~= self.NAME_LONG then return end

    local ts = self.Settings.ToggleSettings
    local cols = ts.Columns or 5
    local btnW = ts.ButtonWidth or 100
    local btnH = ts.ButtonHeight or 28

    GUI:SetNextWindowSize(cols * (btnW + 4) + 20, 0)
    GUI:PushStyleVar(GUI.StyleVar_WindowPadding, 6, 6)
    if GUI:Begin(self.NAME_LONG .. " Toggles",
                 GUI.WindowFlags_NoTitleBar + GUI.WindowFlags_NoResize + GUI.WindowFlags_AlwaysAutoResize) then

        for i, def in ipairs(toggleDefs) do
            local state = self.Settings.Modes[def.key]
            local color = state and ts.EnabledColor or ts.DisabledColor
            GUI:PushStyleColor(GUI.Col_Button, color.r/255, color.g/255, color.b/255, color.a/255)
            GUI:PushStyleColor(GUI.Col_ButtonHovered, color.r/255, color.g/255, color.b/255, math.min(1, color.a/255 + 0.15))
            GUI:PushStyleColor(GUI.Col_ButtonActive,  color.r/255, color.g/255, color.b/255, math.min(1, color.a/255 + 0.25))
            if GUI:Button(def.label .. "##tog_" .. def.key, btnW, btnH) then
                self.Settings.Modes[def.key] = not self.Settings.Modes[def.key]
            end
            GUI:PopStyleColor(3)
            if (i % cols) ~= 0 then space(ts.HorizontalSpacing or 3) end
        end

        -- Mimicry segmented button row
        GUI:Text("Mimicry:")
        space(4)
        for _, role in ipairs({ "Off", "DPS", "Tank", "Healer" }) do
            local active = (self.Settings.Mimicry.Mode == role)
            local color = active and ts.EnabledColor or ts.DisabledColor
            GUI:PushStyleColor(GUI.Col_Button, color.r/255, color.g/255, color.b/255, color.a/255)
            GUI:PushStyleColor(GUI.Col_ButtonHovered, color.r/255, color.g/255, color.b/255, math.min(1, color.a/255 + 0.15))
            GUI:PushStyleColor(GUI.Col_ButtonActive,  color.r/255, color.g/255, color.b/255, math.min(1, color.a/255 + 0.25))
            if GUI:Button(role .. "##mim_" .. role, 60, btnH - 4) then
                self.Settings.Mimicry.Mode = role
            end
            GUI:PopStyleColor(3)
            space(2)
        end
    end
    GUI:End()
    GUI:PopStyleVar(1)
end

-- ============================================================================
-- Enemy circle / cone overlay (carried forward from old ACR for diagnostics)
-- ============================================================================

function UI.DrawOverlay()
    if not self.Settings.DrawNearbyEnemyCircles then return end
    -- Light version: only draw if enabled. The full geometry is in Helpers.
    -- (Keeping the heavy DrawCircle / DrawCircularSector routines out of v1.0
    -- to keep the file small. Users who want them can copy from Kali's ACR.)
end

-- ============================================================================
-- Main entry called from GBLU.Draw (which is called by MMOMinion's Draw event)
-- ============================================================================

function UI.Draw()
    -- Always draw overlays / toggle row regardless of window state
    UI.DrawToggleRow()
    UI.DrawOverlay()

    if not self.GUI.open then return end

    GUI:PushStyleVar(GUI.StyleVar_WindowMinSize, 640, 360)
    local pushed = pushTheme()

    self.GUI.visible, self.GUI.open = GUI:Begin(self.GUI.name, self.GUI.open)
    self.Settings.open = self.GUI.open

    if self.GUI.visible then
        local tabIndex, tabName = GUI_DrawTabs(self.GUI.main_tabs)
        if     tabName == GetString("General")    then UI.DrawGeneralTab()
        elseif tabName == GetString("Modes")      then UI.DrawModesTab()
        elseif tabName == GetString("Rotation")   then UI.DrawRotationTab()
        elseif tabName == GetString("Actions")    then UI.DrawActionsTab()
        elseif tabName == GetString("Defensive")  then UI.DrawDefensiveTab()
        elseif tabName == GetString("Carnivale")  then UI.DrawCarnivaleTab()
        end
    end
    GUI:End()

    popTheme(pushed)
    GUI:PopStyleVar(1)
end

return UI
