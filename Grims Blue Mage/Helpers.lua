--[[
================================================================================
    Grim's Blue Mage ACR - Helpers Module
    Geometry, validators, distance / cone / line math.
    Most of these are ported (and tightened) from Kali's Blue Mage ACR.
================================================================================
]]

local self = GBLU
self.Helpers = self.Helpers or {}
local H = self.Helpers

-- ----------------------------------------------------------------------------
-- Generic nil / table validity
-- ----------------------------------------------------------------------------

function H.IsNil(...)
    local tbl = { ... }
    if #tbl == 0 then return true end
    for i = 1, #tbl do
        local x = tbl[i]
        if x == nil or x == "" then return true end
    end
    return false
end

local tblvalid = table.valid
function H.valid(...)
    local args = { ... }
    local size = #args
    if size == 0 then return false end

    -- 1st arg may be a count for "all of N must be valid"
    local first = args[1]
    if type(first) == "number" and size == (first + 1) then
        for i = 2, size do
            if not tblvalid(args[i]) then return false end
        end
        return true
    end

    for i = 1, size do
        if not tblvalid(args[i]) then return false end
    end
    return true
end

local valid = H.valid

function H.Not(check, ...)
    local args = { ... }
    if #args == 0 then return false end
    for i = 1, #args do
        if check == args[i] then return false end
    end
    return true
end

function H.Is(check, ...)
    local args = { ... }
    if #args == 0 then return false end
    for i = 1, #args do
        if check == args[i] then return true end
    end
    return false
end

function H.IsAll(check, ...)
    local args = { ... }
    if #args == 0 then return false end
    for i = 1, #args do
        if check ~= args[i] then return false end
    end
    return true
end

function H.TypeIs(x, t)
    return type(x) == t
end

-- ----------------------------------------------------------------------------
-- Distance helpers - return 0 on invalid input rather than nil to simplify callers
-- ----------------------------------------------------------------------------

function H.Distance2D(a, b, ignoreRadius)
    if not (valid(a) and valid(b)) then return 0 end
    local pa, pb = a.pos or a, b.pos or b
    local d = math.sqrt((pb.x - pa.x)^2 + (pb.z - pa.z)^2)
    if ignoreRadius then return d end
    local ra = (a.hitradius or 0.5)
    local rb = (b.hitradius or 0.5)
    return d - (ra + rb)
end

function H.Distance3D(a, b, ignoreRadius)
    if not (valid(a) and valid(b)) then return 0 end
    local pa = a.pos or a
    local pb = b.pos or b
    local d = math.sqrt((pb.x - pa.x)^2 + (pb.y - pa.y)^2 + (pb.z - pa.z)^2)
    if ignoreRadius then return d end
    local ra = (a.hitradius or 0.5)
    local rb = (b.hitradius or 0.5)
    return d - (ra + rb)
end

local Distance3D = H.Distance3D

function H.Sign(v) return (v >= 0 and 1) or -1 end

function H.Round(v, bracket)
    bracket = bracket or 1
    return math.floor(v / bracket + H.Sign(v) * 0.5) * bracket
end

function H.HeadingToPos(pos1, pos2)
    return RadiansToHeading(math.rad(AngleFromPos(pos1, pos2)))
end

-- ----------------------------------------------------------------------------
-- Cone / line geometry (ported from Kali's ACR; used for AoE aim checks)
-- ----------------------------------------------------------------------------

local function projectPointOnLine(linePoint1, linePoint2, point)
    local ap = { point[1] - linePoint1[1], point[2] - linePoint1[2] }
    local ab = { linePoint2[1] - linePoint1[1], linePoint2[2] - linePoint1[2] }
    local dot1 = (ap[1] * ab[1]) + (ap[2] * ab[2])
    local dot2 = (ab[1] * ab[1]) + (ab[2] * ab[2])
    if dot2 == 0 then return { linePoint1[1], linePoint1[2] } end
    local coef = dot1 / dot2
    return { linePoint1[1] + (coef * ab[1]), linePoint1[2] + (coef * ab[2]) }
end

local function isProjectedPointOnLine(p1, p2, point)
    if (p1[1] <= point[1] and point[1] <= p2[1]) or
       (p1[1] >= point[1] and point[1] >= p2[1]) or
       (p1[2] <= point[2] and point[2] <= p2[2]) or
       (p1[2] >= point[2] and point[2] >= p2[2]) then
        return true
    end
    return false
end

local function findNearestExitVector(projected, center, radius)
    local l1 = center[1] - projected[1]
    local l2 = center[2] - projected[2]
    local dist = math.sqrt((l1 * l1) + (l2 * l2))
    if dist == 0 then return false end
    local minDistance = (dist <= radius) and (radius - dist) or 0
    if minDistance == 0 then return false end
    local nx, ny = l1 / dist, l2 / dist
    return { nx * minDistance, ny * minDistance }
end

function H.IsEnemyOnLine(player, entity, radius, angle, forcedHeading)
    if not (valid(player) and valid(entity)) then return false end
    local ppos, epos = player.pos, entity.pos
    local pRadius, eRadius = player.hitradius or 0.5, entity.hitradius or 0.5
    local heading = ppos.h

    if valid(forcedHeading) then
        local fp = forcedHeading.pos
        if valid(fp) then
            heading = math.atan2(fp.x - ppos.x, fp.z - ppos.z)
        end
    end

    if type(heading) ~= "number" then return false end

    local left = GetPosFromDistanceHeading(ppos, radius, heading - (math.pi * angle))
    local right = GetPosFromDistanceHeading(ppos, radius, heading + (math.pi * angle))

    local lProj = projectPointOnLine({ ppos.x, ppos.z }, { left.x, left.z }, { epos.x, epos.z })
    local rProj = projectPointOnLine({ ppos.x, ppos.z }, { right.x, right.z }, { epos.x, epos.z })
    local lOn = isProjectedPointOnLine({ ppos.x, ppos.z }, { left.x, left.z }, lProj)
    local rOn = isProjectedPointOnLine({ ppos.x, ppos.z }, { right.x, right.z }, rProj)

    local leftpos = { x = lProj[1], y = ppos.y, z = lProj[2] }
    local rightpos = { x = rProj[1], y = ppos.y, z = rProj[2] }

    if lOn then
        if Distance3D(epos, leftpos) > eRadius then
            -- outside left edge - geometry would render this if needed
        else
            return true
        end
    elseif Distance3D(epos, left) <= eRadius then
        return true
    end

    if rOn then
        if Distance3D(epos, rightpos) <= eRadius then return true end
    elseif Distance3D(epos, right) <= eRadius then
        return true
    end

    if Distance3D(epos, ppos, true) <= eRadius then return true end
    return false
end

function H.IsEnemyInCone(player, entity, radius, angle, forcedHeading)
    if not valid(entity) or not valid(player) then return false end
    local ppos, epos = player.pos, entity.pos
    local dist = Distance3D(player, entity)
    if dist > radius then return false end

    local playerHeading = ppos.h
    if valid(forcedHeading) then
        local fp = forcedHeading.pos
        if valid(fp) then
            playerHeading = math.atan2(fp.x - ppos.x, fp.z - ppos.z)
        end
    end

    local playerAngle = math.atan2(epos.x - ppos.x, epos.z - ppos.z)
    local deviation = playerAngle - playerHeading
    local absDev = math.abs(deviation)
    local leftover = math.abs(absDev - math.pi)

    if leftover > (math.pi * (1 - angle)) and leftover < (math.pi * (1 + angle)) then
        return true
    end
    return H.IsEnemyOnLine(player, entity, radius, angle, forcedHeading)
end

-- ----------------------------------------------------------------------------
-- HP-advantage gate: only attack mobs where player can plausibly win
-- ----------------------------------------------------------------------------

function H.HpAdvantage(entity)
    if not self.Settings.Modes.HpAdvantage then return true end
    if not valid(entity) then return false end
    if entity.contentid == 541 then return true end       -- always attack quest mobs etc.

    local player = Player
    local pMax = player.hp.max
    local eMax = entity.hp.max
    local eCur = entity.hp.current
    if eMax == 0 then return true end

    local adv = pMax / eMax
    local eHPP = (eCur / eMax) * 100

    -- Curve: more advantage required as enemy HP is higher
    if adv > 3   and eHPP > 0  then return true end
    if adv > 1.5 and eHPP > 20 then return true end
    if adv > 0.5 and eHPP > 40 then return true end
    if adv > 0.25 and eHPP > 80 then return true end
    return false
end

-- ----------------------------------------------------------------------------
-- ValidEntity - is this entity in range, attackable, and in combat with us/our target?
-- ----------------------------------------------------------------------------

function H.ValidEntity(player, target, entity, range, check, ignoreHitRadius)
    entity = entity or target
    if not (valid(player) and valid(entity)) then return false end
    if Distance3D(player, entity, ignoreHitRadius) > range then return false end

    local eIncombat = entity.incombat
    local pIncombat = player.incombat
    local pass = false

    if valid(target) and target.attackable then
        local tIncombat = target.incombat
        if (pIncombat and eIncombat) or
           (gStartCombat and entity.id == target.id) or
           tIncombat then
            pass = true
        end
    elseif entity.attackable then
        if eIncombat then pass = true end
    end

    if not pass then return false end
    if type(check) == "function" then return check(entity) end
    return true
end

-- ----------------------------------------------------------------------------
-- Enemy list helpers - used for AoE threshold checks and Carnivale logic
-- ----------------------------------------------------------------------------

function H.EnemyList(range)
    range = range or 25
    return MEntityList("los,alive,attackable,targetable,maxdistance2d=" .. range)
end

function H.CountAttackableInRange(range)
    local el = H.EnemyList(range)
    if not valid(el) then return 0 end
    local c = 0
    for id, e in pairs(el) do
        if H.HpAdvantage(e) then c = c + 1 end
    end
    return c
end

function H.CountInCone(player, radius, angle)
    local el = H.EnemyList(radius + 5)
    if not valid(el) then return 0 end
    local c = 0
    for id, e in pairs(el) do
        if H.IsEnemyInCone(player, e, radius, angle) then c = c + 1 end
    end
    return c
end

function H.CountAroundTarget(target, range, radius)
    if not valid(target) then return 0 end
    local el = H.EnemyList(range + radius + 5)
    if not valid(el) then return 0 end
    local c = 0
    for id, e in pairs(el) do
        if Distance3D(target, e) <= radius then c = c + 1 end
    end
    return c
end

-- ----------------------------------------------------------------------------
-- Cooldown helper - returns ms until action is castable.
-- Accepts numeric action id or action object.
-- ----------------------------------------------------------------------------

function H.CD(action)
    if type(action) == "number" then
        local tbl = self.Runtime.Action[action]
        if tbl then action = tbl
        else action = ActionList:Get(1, action) end
    end
    if not valid(action) then return 99999 end
    return math.max(0, (action.cdmax - action.cd) * 1000)
end

-- ----------------------------------------------------------------------------
-- Party / role queries
-- ----------------------------------------------------------------------------

local function partyList()
    if EntityList and EntityList.myparty then
        return EntityList.myparty
    end
    -- Fallback: filter EntityList for party-flagged entities
    return MEntityList("myparty")
end

function H.GetPartyMembers()
    local out = {}
    local p = partyList()
    if not valid(p) then return out end
    for i, m in pairs(p) do
        if valid(m) and m.id and m.hp and m.hp.max > 0 then
            out[#out + 1] = m
        end
    end
    return out
end

function H.GetRoleFromJob(jobId)
    -- Tank jobs
    if jobId == 19 or jobId == 21 or jobId == 32 or jobId == 37 then return "Tank" end       -- PLD, WAR, DRK, GNB
    -- Healer jobs
    if jobId == 24 or jobId == 28 or jobId == 33 or jobId == 40 then return "Healer" end     -- WHM, SCH, AST, SGE
    -- DPS jobs
    if jobId == 20 or jobId == 22 or jobId == 23 or jobId == 30 or
       jobId == 31 or jobId == 34 or jobId == 35 or jobId == 38 or jobId == 39 or
       jobId == 25 or jobId == 27 then
        return "DPS"
    end
    return "DPS"
end

-- Find nearest party member matching a role; nil if none in range.
function H.NearestPartyMemberByRole(role, maxDistance)
    maxDistance = maxDistance or 25
    local player = Player
    local best, bestDist
    local members = H.GetPartyMembers()
    for i = 1, #members do
        local m = members[i]
        if m.id ~= player.id then
            if H.GetRoleFromJob(m.job) == role then
                local d = Distance3D(player, m, true)
                if d <= maxDistance then
                    if not best or d < bestDist then
                        best, bestDist = m, d
                    end
                end
            end
        end
    end
    return best
end

-- Is player solo (no party, or only self in party)?
function H.IsSolo()
    local members = H.GetPartyMembers()
    if #members == 0 then return true end
    if #members == 1 and members[1].id == Player.id then return true end
    return false
end

-- ----------------------------------------------------------------------------
-- Buff helpers - thin wrappers so other modules don't import HasBuffs directly
-- ----------------------------------------------------------------------------

function H.HasBuff(entity, buffId)
    if not valid(entity) or not buffId then return false end
    return HasBuffs(entity, tostring(buffId))
end

function H.MissingBuff(entity, buffId)
    if not valid(entity) or not buffId then return true end
    return MissingBuffs(entity, tostring(buffId))
end

-- Returns the buff object if present, with .duration / .stacks, else nil.
function H.GetBuff(entity, buffId)
    if not valid(entity) or not entity.buffs then return nil end
    local buffs = entity.buffs
    for i = 1, #buffs do
        local b = buffs[i]
        if b.id == buffId then return b end
    end
    return nil
end

function H.BuffRemainingMs(entity, buffId)
    local b = H.GetBuff(entity, buffId)
    if not b then return 0 end
    return (b.duration or 0) * 1000
end

return H
