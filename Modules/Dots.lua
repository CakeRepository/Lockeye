-- The DoT tracker: which of your DoTs, banes and curses are on your target and
-- on the other enemies you fight, how long each has left, and which are
-- missing or about to run out.
--
-- What the game lets an addon see (Forever, Midnight addon rules):
--  * Out of combat, your debuffs on an enemy can be read in full: the spell,
--    its duration and when it ends.
--  * In combat, the details of an enemy's debuffs are secret. The list of
--    aura instance IDs of the debuffs you put on it (GetUnitAuraInstanceIDs
--    with "HARMFUL|PLAYER") is a plain list, but in game it has come back
--    empty in combat while your DoTs were on, and a debuff may get a new ID
--    when you target its enemy again.
--  * Your own casts stay readable (UNIT_SPELLCAST_SUCCEEDED gives the spell),
--    and so, for creatures, does the enemy's GUID.
-- So Lockeye remembers your DoTs per enemy (by GUID): a cast at your target
-- starts that DoT's timer on it, with how long that rank lasts (from the
-- spell tables, or what the game showed for it before). The debuff list
-- then refines that whenever it shows something: a new ID right after a
-- cast is that DoT, an ID that leaves the list means it ended (run out,
-- dispelled), a cast whose debuff never shows up was resisted, and DoTs that
-- come back under new IDs are matched again by the game's own sort order.
-- Debuffs the game lets addons read (out of combat, or never secret) give
-- exact times.
local _, ns = ...
local L = ns.L
local Spells = ns.Spells

local Dots = ns:NewModule("Dots", {
	enabled = true,
	position = { x = 0, y = -120 }, -- center relative to the screen center, in UI units
	scale = 1,
	width = 170,
	rowHeight = 16,
	spacing = 2,
	show = "target", -- "target" (a living enemy targeted), "combat" or "always"
	threshold = 3, -- seconds left that count as running out
	slots = { corruption = "remind", bane = "remind", immolate = "remind", siphon = "remind", curse = "show" },
	remindOutOfCombat = false, -- flag missing ones before the fight starts too
	texture = "Blizzard",
	font = "Default",
	fontSize = 10,
	fontOutline = "OUTLINE",
	showNames = true,
	spellColors = true, -- each spell's own color, else barColor
	barColor = { 0.58, 0.51, 0.79 },
	colors = {
		expiring = { 1, 0.55, 0.10 },
		missing = { 0.90, 0.20, 0.20 },
		background = { 0, 0, 0, 0.5 },
		text = { 1, 1, 1 },
		full = { 0.35, 0.90, 0.35 },
	},
	sound = "NONE", -- when a DoT on your target starts running out
	others = true, -- the other enemies you fight, from enemy nameplates
	othersUndotted = true, -- ...including the ones with none of your DoTs yet
	othersMax = 6,
	othersIconSize = 18,
	learned = {}, -- [spell ID] = seconds its debuff lasted when the game showed it
})
Dots.title = L["DoT tracker"]
Dots.slashPrefix = "dots"

local FILTER = "HARMFUL|PLAYER" -- debuffs you (or your demon) put on a unit
local SORT_RULES = Enum and Enum.UnitAuraSortRule or {}
local SORT_BY_NAME = SORT_RULES.NameOnly or 6
local SORT_BY_END = SORT_RULES.ExpirationOnly or 4
local SCAN_SECONDS = 0.2 -- target, focus and mouseover
local EVENT_SCAN_SECONDS = 0.05 -- at most this often after aura events, which come in floods in groups
local RENDER_SECONDS = 0.05
local PLATE_SECONDS = 0.5 -- enemy nameplates
local NAMEPLATE_UNITS = 40
local CLAIM_BEFORE = 0.5 -- a debuff may show up this long before its cast's event...
local CLAIM_AFTER = 1.5 -- ...or this long after
local FORGET_AFTER = 2 -- seconds past its end a debuff nobody sees is dropped
local FORGET_ENEMY = 60 -- seconds an enemy with nothing of yours on it is remembered
local LISTED_GRACE = 0.6 -- still listed after its timer ran out, this recently: it's on (the timer was short)
local CHECK_TEXTURE = "Interface\\RaidFrame\\ReadyCheck-Ready"
local MODES = { remind = true, show = true, off = true }

local CHOICES = {
	show = {
		{ value = "target", text = L["While I target an enemy"] },
		{ value = "combat", text = L["In combat"] },
		{ value = "always", text = L["Always"] },
	},
	mode = {
		{ value = "remind", text = L["Show, and flag it when missing"] },
		{ value = "show", text = L["Show while it's on"] },
		{ value = "off", text = L["Don't show"] },
	},
	outline = {
		{ value = "", text = L["None"] },
		{ value = "OUTLINE", text = L["Outline"] },
		{ value = "THICKOUTLINE", text = L["Thick outline"] },
	},
}

---------------------------------------------------------------------------
-- What is known
---------------------------------------------------------------------------
-- enemies[key] = { key =, guid =, seen =, slots = { [slot key] = entry },
--   ids = { [aura ID] = slot key, or false: a debuff of yours that isn't tracked },
--   order = { slot key or false, ... }: what each of your debuffs on it is, in
--   the game's name order, from the last time all of them were known }
-- entry = { spell =, spellID =, applied =, duration =, expires =, exact = (the
--   end time came from the game), id = (its aura ID, once seen), listedAt =,
--   unsure = (its new ID couldn't be told apart), warned = }
local enemies = {}
local byAura = {} -- [aura ID] = the enemy it's on: finds an enemy whose GUID is hidden
local onUnit = {} -- [unit token] = the enemy last scanned there, until the token changes
local lastIDs = {} -- [unit token] = { enemy =, ids = }: that token's list at its last scan
local unclaimed = {} -- [aura ID] = { at =, enemy = }: a new, secret debuff of yours not matched yet
local pending = {} -- casts waiting for their debuff: { spell =, spellID =, at =, enemy = }
local lastInSlot = {} -- [slot key] = the spell of that slot you cast last (for its icon)
local pseudoCount = 0
local fightNumber = 0 -- counts fights; an enemy that fought you in this one stays listed
local plateUnits = {}
for i = 1, NAMEPLATE_UNITS do
	plateUnits[i] = "nameplate" .. i
end

local state = {
	test = false, preview = false, dirty = true,
	lastScan = -math.huge, lastPlateScan = -math.huge, lastRender = -math.huge,
}

local function InCombat()
	return ns.Readable(UnitAffectingCombat("player"), false)
end

local function Exists(unit)
	return ns.Readable(UnitExists(unit), false)
end

local function Hostile(unit)
	return Exists(unit) and ns.Readable(UnitCanAttack("player", unit), false) and not ns.Readable(UnitIsDead(unit), false)
end

-- An enemy that has you on its threat list: one you're fighting.
local function Fighting(unit)
	if not (InCombat() and Hostile(unit)) then
		return false
	end
	return UnitThreatSituation ~= nil and ns.Readable(UnitThreatSituation("player", unit)) ~= nil
end

local function GUID(unit)
	local guid = UnitGUID and ns.Readable(UnitGUID(unit))
	if type(guid) == "string" and guid ~= "" then
		return guid
	end
end

-- Your debuffs on a unit as a set of aura instance IDs, or nil if the game won't say.
local function MyDebuffIDs(unit, sortRule)
	if not C_UnitAuras.GetUnitAuraInstanceIDs then
		return nil
	end
	local ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, FILTER, nil, sortRule)
	ids = ok and ns.Readable(ids)
	if type(ids) ~= "table" then
		return nil
	end
	local set = {}
	for index, id in ipairs(ids) do
		id = ns.Readable(id)
		if id then
			set[id] = index
		end
	end
	return set
end

-- The debuff's details, if the game lets addons read them right now.
local function ReadAura(unit, id)
	if C_Secrets and C_Secrets.ShouldUnitAuraInstanceBeSecret then
		local ok, secret = pcall(C_Secrets.ShouldUnitAuraInstanceBeSecret, unit, id)
		if not ok or ns.Readable(secret, true) ~= false then
			return nil
		end
	end
	if not C_UnitAuras.GetAuraDataByAuraInstanceID then
		return nil
	end
	local ok, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, id)
	if not ok or ns.IsSecret(aura) or type(aura) ~= "table" then
		return nil
	end
	local spellID = ns.Readable(aura.spellId)
	if not spellID then
		return nil
	end
	return {
		spellID = spellID,
		name = ns.Readable(aura.name),
		duration = ns.Readable(aura.duration),
		expires = ns.Readable(aura.expirationTime),
	}
end

-- The time left on a debuff from its duration object, when that holds no secrets.
local function ReadRemaining(unit, id)
	if not C_UnitAuras.GetAuraDuration then
		return nil
	end
	local ok, duration = pcall(C_UnitAuras.GetAuraDuration, unit, id)
	if not ok or duration == nil or ns.IsSecret(duration) then
		return nil
	end
	local okSecret, hasSecrets = pcall(duration.HasSecretValues, duration)
	if not okSecret or hasSecrets ~= false then
		return nil
	end
	local okLeft, left = pcall(duration.GetRemainingDuration, duration)
	local okTotal, total = pcall(duration.GetTotalDuration, duration)
	left, total = okLeft and ns.Readable(left), okTotal and ns.Readable(total)
	if type(left) == "number" and type(total) == "number" and total > 0 then
		return left, total
	end
end

local function TakeExactTimes(entry, data)
	if data and data.expires and data.expires > 0 and data.duration and data.duration > 0 then
		if data.expires > entry.expires + 0.5 then
			entry.warned = nil -- refreshed
		end
		entry.duration, entry.expires, entry.exact = data.duration, data.expires, true
		Spells.Learn(entry.spellID, data.duration, Dots.db.learned)
		return true
	end
end

-- The nameplate token showing your target, if the game says.
local function TargetPlate()
	if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then
		return nil
	end
	local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, "target")
	if not ok or ns.IsSecret(plate) or type(plate) ~= "table" then
		return nil
	end
	local okToken, token = pcall(function()
		return plate.unitToken or plate.namePlateUnitToken
	end)
	token = okToken and ns.Readable(token)
	if type(token) == "string" and token:match("^nameplate%d+$") then
		return token
	end
end

---------------------------------------------------------------------------
-- Enemies and their DoTs
---------------------------------------------------------------------------
local function NewEnemy(key, guid)
	local enemy = { key = key, guid = guid, slots = {}, ids = {}, seen = GetTime() }
	enemies[key] = enemy
	return enemy
end

-- The enemy on a unit token: by its GUID when the game shows it, else by a
-- debuff of yours it shares with an enemy seen before, else by your target's
-- nameplate (the same enemy as your target), else the one last seen on that
-- token since it changed, else a new one.
local function EnemyOn(unit, ids)
	local guid = GUID(unit)
	local enemy
	if guid then
		enemy = enemies[guid] or NewEnemy(guid, guid)
	else
		for id in pairs(ids or {}) do
			enemy = enemy or byAura[id]
		end
		if not enemy and unit == "target" then
			local plate = TargetPlate()
			enemy = plate and onUnit[plate]
		elseif not enemy and unit:match("^nameplate") and onUnit.target and TargetPlate() == unit then
			enemy = onUnit.target
		end
		enemy = enemy or onUnit[unit]
		if not enemy then
			pseudoCount = pseudoCount + 1
			enemy = NewEnemy("unit:" .. pseudoCount)
		end
	end
	onUnit[unit] = enemy
	return enemy
end

-- The entry lets go of its aura ID. The ID is retired, not forgotten: if it
-- is still listed (a bane you just replaced, say), it isn't a new debuff.
local function Unbind(enemy, entry)
	if entry.id then
		enemy.ids[entry.id] = false
		entry.id = nil
	end
end

local function Bind(enemy, entry, id)
	if entry.id ~= id then
		Unbind(enemy, entry)
	end
	entry.id, entry.unsure = id, nil
	enemy.ids[id] = entry.spell.slot
	byAura[id] = enemy
	unclaimed[id] = nil
end

-- A DoT goes on (or is found on) an enemy: it takes its row's place.
local function SetEntry(enemy, spell, spellID, applied, data)
	local old = enemy.slots[spell.slot]
	if old then
		Unbind(enemy, old)
	end
	local entry = { spell = spell, spellID = spellID, applied = applied }
	entry.duration = Spells.Duration(spell, spellID)
	entry.expires, entry.exact = applied + entry.duration, false
	TakeExactTimes(entry, data)
	enemy.slots[spell.slot] = entry
	if spellID then
		spell.lastRank = spellID
	end
	return entry
end

local function RemoveEntry(enemy, slotKey, why)
	local entry = enemy.slots[slotKey]
	if entry then
		ns.Debug("DoTs:", Spells.Name(entry.spell), why)
		Unbind(enemy, entry)
		enemy.slots[slotKey] = nil
	end
end

local function ClearEnemy(enemy)
	for slotKey in pairs(enemy.slots) do
		RemoveEntry(enemy, slotKey, "gone: the enemy died")
	end
end

local function Active(entry, now)
	if entry.expires > now then
		return true
	end
	local listed = entry.listedAt
	return listed ~= nil and listed >= entry.expires and now - listed <= LISTED_GRACE
end

local function HasPending(enemy, now)
	for _, cast in ipairs(pending) do
		if (cast.enemy == nil or cast.enemy == enemy) and now <= cast.at + CLAIM_AFTER then
			return true
		end
	end
	return false
end

-- Your debuffs on a unit as a list of IDs in the game's name order.
local function NameOrder(unit)
	local ok, list = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, FILTER, nil, SORT_BY_NAME)
	list = ok and ns.Readable(list)
	if type(list) ~= "table" then
		return nil
	end
	local order = {}
	for i, id in ipairs(list) do
		id = ns.Readable(id)
		if not id then
			return nil
		end
		order[i] = id
	end
	return order
end

-- The same debuffs keep the same name order whatever their IDs: if the list
-- has as many as last time and every ID still known sits where it did, each
-- new ID is whatever was in its place.
local function RematchByPlace(enemy, unit)
	local order, roles = NameOrder(unit), enemy.order
	if not (order and roles and #order == #roles) then
		return false
	end
	local plan = {}
	for i, id in ipairs(order) do
		local known = enemy.ids[id]
		if known == nil then
			plan[id] = roles[i]
		elseif known ~= roles[i] then
			return false
		end
	end
	for id, role in pairs(plan) do
		local entry = role and enemy.slots[role]
		if entry then
			ns.Debug("DoTs:", Spells.Name(entry.spell), "came back as aura", id)
			Bind(enemy, entry, id)
		else
			enemy.ids[id], unclaimed[id] = false, nil
		end
	end
	return true
end

-- Order-keeping ways to pair the lost DoTs with the new IDs: pairs keep the
-- game's name order on both sides. Calls found(map) for each.
local function Pairings(lost, ids, found)
	local map = {}
	local function Walk(i, j)
		if i > #lost or j > #ids then
			found(map)
			return
		end
		-- lost[i] gets ids[k] for some k >= j, or stays unpaired.
		for k = j, #ids do
			map[lost[i]] = ids[k]
			Walk(i + 1, k + 1)
			map[lost[i]] = nil
		end
		Walk(i + 1, j)
	end
	Walk(1, 1)
end

-- Your DoTs on this enemy came back under new IDs (it happens when you
-- target an enemy again). Pair them up by the game's own sort order of the
-- list, by spell name and by end time, which it can do while it hides both:
-- only pairings that agree with both, pairing as many as possible, count.
-- A DoT paired the same way by all of them gets that ID; the others carry on
-- by their timers.
local function Rematch(enemy, unit, ids, unknown, now)
	local lost = {}
	for _, entry in pairs(enemy.slots) do
		if entry.id and not ids[entry.id] and entry.expires > now then
			lost[#lost + 1] = entry
		end
	end
	if #lost == 0 or RematchByPlace(enemy, unit) then
		return
	end
	local byName, byEnd = MyDebuffIDs(unit, SORT_BY_NAME), MyDebuffIDs(unit, SORT_BY_END)
	if not (byName and byEnd) then
		return
	end
	table.sort(lost, function(a, b)
		return Spells.Name(a.spell) < Spells.Name(b.spell)
	end)
	local candidates = {}
	for _, id in ipairs(unknown) do
		if byName[id] and byEnd[id] then
			candidates[#candidates + 1] = id
		end
	end
	table.sort(candidates, function(a, b)
		return byName[a] < byName[b]
	end)
	local best, agreed = 0, nil
	Pairings(lost, candidates, function(map)
		local size = 0
		for a, idA in pairs(map) do
			size = size + 1
			for b, idB in pairs(map) do
				-- A DoT due to end clearly sooner must come first in the game's end order.
				if a.expires + 0.5 < b.expires and byEnd[idA] > byEnd[idB] then
					return
				end
			end
		end
		if size > best then
			best, agreed = size, {}
			for entry, id in pairs(map) do
				agreed[entry] = id
			end
		elseif size == best and agreed then
			for entry, id in pairs(agreed) do
				if map[entry] ~= id then
					agreed[entry] = false
				end
			end
		end
	end)
	for _, entry in ipairs(lost) do
		local id = agreed and agreed[entry]
		if id then
			ns.Debug("DoTs:", Spells.Name(entry.spell), "came back as aura", id, "(by end time)")
			Bind(enemy, entry, id)
		else
			ns.Debug("DoTs:", Spells.Name(entry.spell), "came back under a new ID that can't be told apart; going by its timer")
			Unbind(enemy, entry)
			entry.unsure = true
		end
	end
end

-- The log gets a line whenever what the game shows of your target (or
-- focus) changes: its GUID, your debuffs on it and what each is, its threat.
local traced = {}
local function Trace(unit, enemy, ids)
	local guid = GUID(unit)
	local parts = { guid and ("enemy " .. guid:sub(-8)) or ("GUID hidden, enemy " .. enemy.key) }
	if not ids then
		parts[#parts + 1] = "no list"
	else
		local list = {}
		for id in pairs(ids) do
			local role = enemy.ids[id]
			list[#list + 1] = id .. "=" .. (role == nil and "new" or role == false and "other" or role)
		end
		table.sort(list)
		parts[#parts + 1] = #list == 0 and "list empty" or ("list " .. table.concat(list, " "))
	end
	local threat = UnitThreatSituation and UnitThreatSituation("player", unit)
	parts[#parts + 1] = "threat " .. (ns.IsSecret(threat) and "hidden" or tostring(threat))
	parts[#parts + 1] = InCombat() and "in combat" or "out of combat"
	local text = unit .. ": " .. table.concat(parts, ", ")
	if traced[unit] ~= text then
		traced[unit] = text
		ns.Debug("DoTs:", text)
	end
end

-- findOnly: look for new debuffs only. The mouseover unit can change before
-- the event that says so, so what it no longer has proves nothing.
local function ScanUnit(unit, now, findOnly)
	if not Exists(unit) then
		if not findOnly then
			onUnit[unit], lastIDs[unit] = nil, nil
		end
		return
	end
	local ids = MyDebuffIDs(unit)
	if findOnly and not GUID(unit) then
		return
	end
	local enemy = EnemyOn(unit, ids)
	enemy.seen = now
	local main = unit == "target" or unit == "focus"
	if ns.Readable(UnitIsDead(unit), false) then
		ClearEnemy(enemy)
		return
	end
	if not ids then
		if main then
			Trace(unit, enemy, ids)
		end
		return
	end
	local unknown = {}
	for id in pairs(ids) do
		local known = enemy.ids[id]
		if known == nil then
			local data = ReadAura(unit, id)
			local spell = data and Spells.Find(data.spellID, data.name)
			if spell then
				local entry = enemy.slots[spell.slot]
				if entry and entry.spell == spell then
					entry.spellID = data.spellID
					TakeExactTimes(entry, data)
				else
					entry = SetEntry(enemy, spell, data.spellID, now, data)
				end
				Bind(enemy, entry, id)
				ns.Debug("DoTs:", Spells.Name(spell), "is aura", id, "(read)")
			elseif data then
				enemy.ids[id] = false
			else
				unknown[#unknown + 1] = id
				unclaimed[id] = unclaimed[id] or { at = now }
				unclaimed[id].enemy = enemy
			end
		elseif known then
			local entry = enemy.slots[known]
			if entry and entry.id == id then
				entry.listedAt = now
				if not TakeExactTimes(entry, ReadAura(unit, id)) then
					local left, total = ReadRemaining(unit, id)
					if left then
						entry.duration, entry.expires, entry.exact = total, now + left, true
					end
				end
			end
		end
	end
	if findOnly then
		return
	end
	if #unknown > 0 and main and not HasPending(enemy, now) then
		Rematch(enemy, unit, ids, unknown, now)
	elseif #unknown == 0 and main and next(ids) then
		-- All known: remember what each is, in the game's name order.
		local order = NameOrder(unit)
		if order then
			local roles = {}
			for i, id in ipairs(order) do
				roles[i] = enemy.ids[id]
			end
			enemy.order = roles
		end
	end
	-- What the list says is gone, when it tells the whole story: it shows
	-- something (in combat an empty list may only mean the game hides it),
	-- and no new debuff of yours on this enemy is still waiting to be matched.
	local trusted = next(ids) ~= nil or not InCombat()
	local waiting = false
	for id in pairs(ids) do
		if unclaimed[id] then
			waiting = true
		end
	end
	if main then
		Trace(unit, enemy, ids)
	end
	local before = lastIDs[unit]
	before = before and before.enemy == enemy and before.ids or nil
	lastIDs[unit] = { enemy = enemy, ids = ids }
	if not trusted or waiting then
		return
	end
	for slotKey, entry in pairs(enemy.slots) do
		if entry.id then
			if before and before[entry.id] and not ids[entry.id] then
				RemoveEntry(enemy, slotKey, "gone: it left the list")
			end
		elseif not entry.unsure and now > entry.applied + CLAIM_AFTER + CLAIM_BEFORE and not HasPending(enemy, now) then
			RemoveEntry(enemy, slotKey, "never showed up: resisted or missed")
		end
	end
end

-- Matches new debuffs of yours to the casts that made them, oldest first.
local function Claim(now)
	local i = 1
	while i <= #pending do
		local cast = pending[i]
		local pick, pickInfo
		for id, info in pairs(unclaimed) do
			local sameEnemy = cast.enemy == nil or info.enemy == cast.enemy or not (cast.enemy.guid and info.enemy.guid)
			if sameEnemy and info.at >= cast.at - CLAIM_BEFORE and info.at <= cast.at + CLAIM_AFTER
				and (not pickInfo or info.at < pickInfo.at) then
				pick, pickInfo = id, info
			end
		end
		if pick then
			local enemy = pickInfo.enemy
			local entry = enemy.slots[cast.spell.slot]
			if not (entry and entry.spell == cast.spell) then
				entry = SetEntry(enemy, cast.spell, cast.spellID, math.min(cast.at, pickInfo.at))
			end
			Bind(enemy, entry, pick)
			ns.Debug("DoTs:", Spells.Name(cast.spell), "is aura", pick, "(matched to the cast)")
			table.remove(pending, i)
		elseif now > cast.at + CLAIM_AFTER then
			table.remove(pending, i)
		else
			i = i + 1
		end
	end
	for id, info in pairs(unclaimed) do
		if now > info.at + CLAIM_AFTER + CLAIM_BEFORE then
			unclaimed[id] = nil
			if info.enemy.ids[id] == nil then
				info.enemy.ids[id] = false
			end
		end
	end
end

function Dots:Scan(now, plates)
	state.lastScan, state.dirty = now, false
	ScanUnit("target", now)
	ScanUnit("focus", now)
	ScanUnit("mouseover", now, true)
	if plates then
		state.lastPlateScan = now
		for _, unit in ipairs(plateUnits) do
			ScanUnit(unit, now)
		end
	end
	Claim(now)
	for key, enemy in pairs(enemies) do
		for slotKey, entry in pairs(enemy.slots) do
			if now > entry.expires + FORGET_AFTER and now > (entry.listedAt or 0) + FORGET_AFTER then
				RemoveEntry(enemy, slotKey, "ran out")
			end
		end
		if not next(enemy.slots) and now - enemy.seen > FORGET_ENEMY then
			for id in pairs(enemy.ids) do
				if byAura[id] == enemy then
					byAura[id] = nil
				end
			end
			enemies[key] = nil
		end
	end
end

---------------------------------------------------------------------------
-- Casts
---------------------------------------------------------------------------
function Dots:OnCast(spellID)
	local spell = Spells.Find(spellID)
	if not spell then
		return
	end
	local now = GetTime()
	spell.lastRank = spellID
	lastInSlot[spell.slot] = spell
	local enemy
	if Hostile("target") then
		enemy = EnemyOn("target", MyDebuffIDs("target"))
		local entry = enemy.slots[spell.slot]
		if entry and entry.spell == spell then
			-- Cast again: it starts over (in Classic a DoT keeps its debuff, and its ID).
			entry.applied, entry.spellID, entry.warned = now, spellID, nil
			entry.duration = Spells.Duration(spell, spellID)
			entry.expires, entry.exact = now + entry.duration, false
		else
			SetEntry(enemy, spell, spellID, now)
		end
	end
	pending[#pending + 1] = { spell = spell, spellID = spellID, at = now, enemy = enemy }
	state.dirty = true
	ns.Debug("DoTs: cast", Spells.Name(spell), spellID, enemy and ("at enemy " .. enemy.key:sub(-8)) or "with no enemy targeted")
end

---------------------------------------------------------------------------
-- What to show
---------------------------------------------------------------------------
local function Mode(slot)
	local mode = Dots.db.slots[slot.key]
	return MODES[mode] and mode or (slot.remind and "remind" or "show")
end

-- Whether you know a spell for this row (any bane counts for the bane row).
local knownCache, knownAt = {}, -math.huge
local function SlotKnown(slot, now)
	if now - knownAt > 5 then
		knownCache, knownAt = {}, now
	end
	if knownCache[slot.key] == nil then
		local known = false
		for _, spell in ipairs(Spells.InSlot(slot.key)) do
			if Spells.Known(spell) then
				known = true
				break
			end
		end
		knownCache[slot.key] = known
	end
	return knownCache[slot.key]
end

-- The spell whose icon a row shows when nothing of it is on: the one you cast
-- last, else the first one you know, else the first.
local function SlotSpell(slot)
	if lastInSlot[slot.key] then
		return lastInSlot[slot.key]
	end
	local list = Spells.InSlot(slot.key)
	for _, spell in ipairs(list) do
		if Spells.Known(spell) then
			return spell
		end
	end
	return list[1]
end

-- One row: { slot =, spell =, state = "on" | "expiring" | "missing", left =, duration = }
local function Row(slot, entry, now, threshold)
	local left = math.max(entry.expires - now, 0)
	return { slot = slot, spell = entry.spell, spellID = entry.spellID, left = left, duration = entry.duration,
		state = left <= threshold and "expiring" or "on", entry = entry }
end

-- The rows for an enemy (nil: nothing known about it). remind: flag missing spells.
function Dots:RowsFor(enemy, now, remind)
	local db, rows = self.db, {}
	for _, slot in ipairs(Spells.slots) do
		local mode = Mode(slot)
		if mode ~= "off" then
			local entry = enemy and enemy.slots[slot.key]
			if entry and Active(entry, now) then
				rows[#rows + 1] = Row(slot, entry, now, db.threshold)
			elseif remind and mode == "remind" and SlotKnown(slot, now) then
				rows[#rows + 1] = { slot = slot, spell = SlotSpell(slot), state = "missing" }
			end
		end
	end
	return rows
end

local function ShouldRemind(unit)
	return Hostile(unit) and (InCombat() or Dots.db.remindOutOfCombat)
end

local function HasActive(enemy, now)
	for _, entry in pairs(enemy.slots) do
		if Active(entry, now) then
			return true
		end
	end
	return false
end

-- "missing" (a flagged DoT isn't on, or nothing to show), "low" (one is
-- running out) or "full", and how many are missing.
local function Status(rows)
	local missing, low = 0, false
	for _, row in ipairs(rows) do
		if row.state == "missing" then
			missing = missing + 1
		elseif row.state == "expiring" then
			low = true
		end
	end
	if missing > 0 or #rows == 0 then
		return "missing", missing
	end
	return low and "low" or "full", 0
end

local STATUS_ORDER = { missing = 1, low = 2, full = 3 }

-- The other enemies you fight, from enemy nameplates: the ones with your DoTs
-- and (unless turned off) the ones you're fighting without them.
function Dots:EnemyRows(now)
	local list = {}
	if not self.db.others then
		return list
	end
	local target = Exists("target") and onUnit.target or nil
	local listed = {}
	for _, unit in ipairs(plateUnits) do
		local enemy = onUnit[unit]
		if not enemy and Hostile(unit) then
			enemy = EnemyOn(unit) -- its nameplate just came (back): no need to wait for the next scan
		end
		if enemy and enemy ~= target and not listed[enemy] and Hostile(unit) then
			if Fighting(unit) then
				enemy.fought = fightNumber -- the game's threat answer can blink: once is enough
			end
			local fighting = InCombat() and enemy.fought == fightNumber
			if HasActive(enemy, now) or (fighting and self.db.othersUndotted) then
				listed[enemy] = true
				local rows = self:RowsFor(enemy, now, true)
				local soonest = math.huge
				for _, row in ipairs(rows) do
					soonest = math.min(soonest, row.left or math.huge)
				end
				local status, missing = Status(rows)
				list[#list + 1] = { unit = unit, name = UnitName(unit), rows = rows, status = status, missing = missing,
					soonest = soonest }
			end
		end
	end
	-- The enemies that need you go on top: the most DoTs missing, then the
	-- soonest to run out. Fully dotted ones go last.
	table.sort(list, function(a, b)
		if a.status ~= b.status then
			return STATUS_ORDER[a.status] < STATUS_ORDER[b.status]
		elseif a.missing ~= b.missing then
			return a.missing > b.missing
		end
		return a.soonest < b.soonest
	end)
	return list
end

-- What the frames show: test mode and the options preview make it up.
function Dots:Model(now)
	if state.test or state.preview then
		return self:SampleModel()
	end
	local model = { target = {}, enemies = self:EnemyRows(now) }
	if Exists("target") then
		model.target = self:RowsFor(onUnit.target, now, ShouldRemind("target"))
	end
	return model
end

function Dots:SampleModel()
	local function Sample(key, left, duration)
		local spell = Spells.Get(key)
		local slot = Spells.Slot(spell.slot)
		if not left then
			return { slot = slot, spell = spell, state = "missing" }
		end
		return { slot = slot, spell = spell, left = left, duration = duration,
			state = left <= self.db.threshold and "expiring" or "on" }
	end
	local cycle = (GetTime() % 18)
	local function Enemy(name, rows)
		return { name = name, rows = rows, status = Status(rows) }
	end
	return {
		target = { Sample("corruption", 18 - cycle, 18), Sample("agony", 2.4, 24), Sample("immolate"), Sample("siphon", 21, 30) },
		enemies = {
			Enemy(L["Another enemy"], { Sample("corruption", 1.8, 18), Sample("agony", 9, 24), Sample("immolate") }),
			Enemy(L["A third enemy"], { Sample("corruption"), Sample("agony"), Sample("immolate") }),
			Enemy(L["A fourth enemy"], { Sample("corruption", 14, 18), Sample("agony", 20, 24), Sample("immolate", 11, 15) }),
		},
	}
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local function SpellColor(db, spell)
	return db.spellColors and spell and spell.color or db.barColor
end

local function FormatTime(seconds)
	if seconds >= 60 then
		return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
	elseif seconds >= 10 then
		return string.format("%d", math.floor(seconds))
	end
	return string.format("%.1f", seconds)
end

function Dots:CreateRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	row.background = row:CreateTexture(nil, "BACKGROUND")
	row.bar = CreateFrame("StatusBar", nil, row)
	row.bar:SetMinMaxValues(0, 1)
	row.name = row.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	row.time = row.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	row:Hide()
	return row
end

function Dots:CreateCell(parent)
	local cell = CreateFrame("Frame", nil, parent)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetAllPoints()
	cell.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	cell.edge = cell:CreateTexture(nil, "BACKGROUND")
	cell.edge:SetPoint("TOPLEFT", -1, 1)
	cell.edge:SetPoint("BOTTOMRIGHT", 1, -1)
	cell.time = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	cell.time:SetPoint("BOTTOM", 0, -1)
	cell:Hide()
	return cell
end

function Dots:CreateFrames()
	local frame = CreateFrame("Frame", "LockeyeDotsFrame", UIParent)
	frame:SetFrameStrata("MEDIUM")
	frame.rows = {}
	frame:SetScript("OnUpdate", function()
		ns.Guard("DoT tracker", self.OnUpdate, self, GetTime())
	end)
	ns.Frames.MakeMovable(self, frame, L["DoTs"])
	self.frame = frame

	-- The other enemies hang below the target's rows and move with them.
	local enemies = CreateFrame("Frame", "LockeyeEnemiesFrame", frame)
	enemies.lines = {}
	enemies.header = enemies:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	self.enemies = enemies

	-- Scanning runs even while the frames are hidden, so nothing is missed.
	self.ticker = CreateFrame("Frame")
	self.ticker:SetScript("OnUpdate", function()
		if not frame:IsShown() then
			ns.Guard("DoT tracker", function()
				local now = GetTime()
				self:Tick(now)
				if self:ShouldShow(now) then
					frame:Show()
				end
			end)
		end
	end)
end

function Dots:ApplyLayout()
	local db, frame = self.db, self.frame
	frame:SetScale(db.scale)
	frame:SetSize(db.width, db.rowHeight)
	for _, row in ipairs(frame.rows) do
		self:LayoutRow(row)
	end
	local header = self.enemies.header
	ns.Media.ApplyFont(header, db.font, db.fontSize, db.fontOutline)
	header:ClearAllPoints()
	header:SetPoint("TOPLEFT")
	header:SetJustifyH("LEFT")
	for _, line in ipairs(self.enemies.lines) do
		self:LayoutLine(line)
	end
	ns.Frames.UpdateMover(frame)
	ns.Frames.ApplyPosition(self, frame)
	self:Refresh()
end

function Dots:LayoutRow(row)
	local db = self.db
	local size = db.rowHeight
	row:SetSize(db.width, size)
	row.icon:ClearAllPoints()
	row.icon:SetPoint("LEFT")
	row.icon:SetSize(size, size)
	row.bar:ClearAllPoints()
	row.bar:SetPoint("TOPLEFT", size + 2, 0)
	row.bar:SetPoint("BOTTOMRIGHT")
	row.bar:SetStatusBarTexture(ns.Media.Texture(db.texture))
	row.background:ClearAllPoints()
	row.background:SetAllPoints(row.bar)
	for _, text in ipairs({ row.name, row.time }) do
		ns.Media.ApplyFont(text, db.font, db.fontSize, db.fontOutline)
		text:ClearAllPoints()
	end
	row.name:SetPoint("LEFT", row.bar, "LEFT", 3, 0)
	row.name:SetJustifyH("LEFT")
	row.time:SetPoint("RIGHT", row.bar, "RIGHT", -3, 0)
	row.time:SetJustifyH("RIGHT")
end

-- A line: [check mark] name ............ [icons]
function Dots:LayoutLine(line)
	local db = self.db
	local size = db.othersIconSize
	line:SetSize(db.width, size + 2)
	line.mark:ClearAllPoints()
	line.mark:SetPoint("LEFT")
	line.mark:SetSize(size - 4, size - 4)
	ns.Media.ApplyFont(line.name, db.font, db.fontSize, db.fontOutline)
	line.name:ClearAllPoints()
	line.name:SetPoint("LEFT", size - 2, 0)
	line.name:SetWidth(math.max(db.width - (size - 2) - 5 * (size + 3), 30))
	line.name:SetJustifyH("LEFT")
	for i, cell in ipairs(line.cells) do
		cell:SetSize(size, size)
		cell:ClearAllPoints()
		cell:SetPoint("RIGHT", line, "RIGHT", -(i - 1) * (size + 3), 0)
		ns.Media.ApplyFont(cell.time, db.font, math.max(db.fontSize - 1, 6), db.fontOutline)
	end
end

function Dots:GetRowFrame(index)
	local rows = self.frame.rows
	if not rows[index] then
		rows[index] = self:CreateRow(self.frame)
		self:LayoutRow(rows[index])
	end
	return rows[index]
end

function Dots:GetLine(index)
	local lines = self.enemies.lines
	if not lines[index] then
		local line = CreateFrame("Frame", nil, self.enemies)
		line.mark = line:CreateTexture(nil, "ARTWORK")
		line.mark:SetTexture(CHECK_TEXTURE)
		line.name = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
		line.cells = {}
		for i = 1, #Spells.slots do
			line.cells[i] = self:CreateCell(line)
		end
		lines[index] = line
		self:LayoutLine(line)
	end
	return lines[index]
end

function Dots:RenderRow(row, data)
	local db = self.db
	row.icon:SetTexture(Spells.Icon(data.spell, data.spellID))
	row.icon:SetDesaturated(data.state == "missing")
	local label = data.slot.label or Spells.Name(data.spell)
	if data.state == "missing" then
		local missing = db.colors.missing
		row.bar:SetValue(0)
		row.background:SetColorTexture(missing[1], missing[2], missing[3], 0.35)
		row.name:SetText(db.showNames and label or "")
		row.time:SetText(L["Missing"])
		row.time:SetTextColor(missing[1], missing[2], missing[3])
	else
		local background = db.colors.background
		row.background:SetColorTexture(background[1], background[2], background[3], background[4] or 1)
		local color = data.state == "expiring" and db.colors.expiring or SpellColor(db, data.spell)
		row.bar:SetStatusBarColor(color[1], color[2], color[3])
		row.bar:SetValue(data.duration and data.duration > 0 and math.min(data.left / data.duration, 1) or 0)
		row.name:SetText(db.showNames and Spells.Name(data.spell) or "")
		row.time:SetText(FormatTime(data.left))
		local text = data.state == "expiring" and db.colors.expiring or db.colors.text
		row.time:SetTextColor(text[1], text[2], text[3])
	end
	local text = db.colors.text
	row.name:SetTextColor(text[1], text[2], text[3])
	row:Show()
end

function Dots:RenderCell(cell, data)
	local db = self.db
	cell.icon:SetTexture(Spells.Icon(data.spell, data.spellID))
	local flagged = data.state == "missing"
	cell.icon:SetDesaturated(flagged)
	local edge = flagged and db.colors.missing or (data.state == "expiring" and db.colors.expiring) or { 0, 0, 0 }
	cell.edge:SetColorTexture(edge[1], edge[2], edge[3], 1)
	if data.left then
		cell.time:SetText(FormatTime(data.left))
		local color = data.state == "expiring" and db.colors.expiring or db.colors.text
		cell.time:SetTextColor(color[1], color[2], color[3])
	else
		cell.time:SetText("")
	end
	cell:Show()
end

function Dots:Render(model)
	local db, frame = self.db, self.frame
	local y = 0
	for i, data in ipairs(model.target) do
		local row = self:GetRowFrame(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -y)
		self:RenderRow(row, data)
		y = y + db.rowHeight + db.spacing
	end
	for i = #model.target + 1, #frame.rows do
		frame.rows[i]:Hide()
	end
	frame:SetHeight(math.max(y - db.spacing, db.rowHeight))

	local enemies = self.enemies
	enemies:ClearAllPoints()
	enemies:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(y + 4))
	enemies:SetSize(db.width, 1)
	local shown = math.min(#model.enemies, db.othersMax)
	local full = 0
	for _, enemy in ipairs(model.enemies) do
		if enemy.status == "full" then
			full = full + 1
		end
	end
	local text = db.colors.text
	enemies.header:SetText(L["Other enemies: %d of %d fully dotted"]:format(full, #model.enemies))
	enemies.header:SetTextColor(text[1], text[2], text[3])
	local lineY = db.fontSize + 4
	for i = 1, shown do
		local enemy = model.enemies[i]
		local line = self:GetLine(i)
		line:ClearAllPoints()
		line:SetPoint("TOPLEFT", enemies, "TOPLEFT", 0, -lineY)
		-- An enemy's name can be secret in combat: widgets show it, code can't test it.
		if ns.IsSecret(enemy.name) then
			line.name:SetText(enemy.name)
		else
			line.name:SetText(enemy.name or "")
		end
		local nameColor = enemy.status == "full" and db.colors.full or text
		line.name:SetTextColor(nameColor[1], nameColor[2], nameColor[3])
		line.mark:SetShown(enemy.status == "full")
		-- The first row is the leftmost icon, so they read left to right.
		local count = #enemy.rows
		for c, cell in ipairs(line.cells) do
			local data = enemy.rows[count - c + 1]
			if data then
				self:RenderCell(cell, data)
			else
				cell:Hide()
			end
		end
		line:Show()
		lineY = lineY + db.othersIconSize + 4
	end
	for i = shown + 1, #enemies.lines do
		enemies.lines[i]:Hide()
	end
	enemies:SetShown(#model.enemies > 0)
end

---------------------------------------------------------------------------
-- Updates
---------------------------------------------------------------------------
function Dots:ShouldShow(now)
	local db = self.db
	if not db.enabled then
		return state.preview or ns:IsUnlocked()
	end
	if state.test or state.preview or ns:IsUnlocked() or db.show == "always" then
		return true
	end
	if db.others and InCombat() and #self:EnemyRows(now) > 0 then
		return true
	end
	if db.show == "combat" then
		return InCombat()
	end
	return Hostile("target")
end

-- The "running out" sound: once per DoT on your target, as it crosses the threshold.
function Dots:PlayCue(model)
	local sound = ns.Media.Sound(self.db.sound)
	if not sound or state.test or state.preview then
		return
	end
	for _, row in ipairs(model.target) do
		local entry = row.entry
		if row.state == "expiring" and entry and not entry.warned then
			entry.warned = true
			PlaySound(sound, "Master")
		end
	end
end

function Dots:Tick(now)
	if not self.db.enabled then
		return
	end
	local plates = self.db.others and now - state.lastPlateScan >= PLATE_SECONDS
	local since = now - state.lastScan
	if plates or since >= SCAN_SECONDS or (state.dirty and since >= EVENT_SCAN_SECONDS) then
		self:Scan(now, plates)
		state.lastRender = -math.huge -- draw what was found right away
	end
end

function Dots:OnUpdate(now)
	self:Tick(now)
	if now - state.lastRender < RENDER_SECONDS then
		return
	end
	state.lastRender = now
	if not self:ShouldShow(now) then
		self.frame:Hide()
		return
	end
	local model = self:Model(now)
	self:Render(model)
	self:PlayCue(model)
	self:TraceShown(model)
end

-- The log gets a line whenever what the tracker shows changes (states, not times).
local shownTrace
function Dots:TraceShown(model)
	if state.test or state.preview then
		return
	end
	local parts = {}
	for _, row in ipairs(model.target) do
		parts[#parts + 1] = (row.slot.label or Spells.Name(row.spell)) .. "=" .. row.state
	end
	local text = "target " .. (#parts > 0 and table.concat(parts, " ") or "none")
	if #model.enemies > 0 then
		local list = {}
		for _, enemy in ipairs(model.enemies) do
			list[#list + 1] = enemy.status
		end
		text = text .. "; others " .. table.concat(list, " ")
	end
	if text ~= shownTrace then
		shownTrace = text
		ns.Debug("DoTs show:", text)
	end
end

function Dots:Refresh()
	if not self.frame then
		return
	end
	local now = GetTime()
	state.lastRender = -math.huge
	if self:ShouldShow(now) then
		self.frame:Show()
		self:OnUpdate(now)
	else
		self.frame:Hide()
	end
end

function Dots:SetTestMode(enabled)
	state.test = enabled
	self:Refresh()
end

function Dots:SetPreview(enabled)
	if state.preview == enabled then
		return
	end
	state.preview = enabled
	self:Refresh()
end

function Dots:OnUnlockChanged()
	self:ApplyLayout()
end

-- /lockeye check: what Lockeye can see of your target right now.
function Dots:Check()
	if not Exists("target") then
		ns.Print(L["Target an enemy first."])
		return
	end
	local now = GetTime()
	self:Scan(now, false)
	local enemy = onUnit.target
	ns.Print(GUID("target") and L["Your target's ID: the game shows it, so its DoTs are remembered when you switch back."]
		or L["Your target's ID: hidden, so its DoTs are only remembered while its debuffs keep their IDs."])
	local ids = MyDebuffIDs("target")
	if not ids then
		ns.Print(L["Your debuffs on it: the game won't list them right now."])
	else
		local count = 0
		for _ in pairs(ids) do
			count = count + 1
		end
		ns.Print(L["Your debuffs on it: the game lists %d."]:format(count))
	end
	local any = false
	for _, slot in ipairs(Spells.slots) do
		local entry = enemy and enemy.slots[slot.key]
		if entry then
			any = true
			local how = entry.exact and L["read from the game"] or (entry.id and L["matched to its debuff"])
				or (entry.unsure and L["from your cast; its debuff came back under a new ID"]) or L["from your cast"]
			print(string.format("  %s: %.1f (%s)", Spells.Name(entry.spell), math.max(entry.expires - now, 0), how))
		end
	end
	if not any then
		print("  " .. L["No DoTs of yours remembered on it."])
	end
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------
function Dots:OnOptionChanged()
	self:ApplyLayout()
end

function Dots:GetOptionSections()
	local rows = {
		{ type = "toggle", label = L["Track my DoTs"], key = "enabled", slash = "enabled" },
		{ type = "select", label = L["Show the tracker"], key = "show", values = CHOICES.show, slash = "show" },
		{ type = "range", label = L["Running out below (seconds)"], key = "threshold", min = 0, max = 10, step = 0.5, slash = "threshold" },
		{ type = "toggle", label = L["Flag missing ones before the fight too"], key = "remindOutOfCombat", slash = "beforefight" },
		{ type = "select", label = L["Sound when one on my target runs out"], key = "sound", values = ns.Media.Sounds(), slash = "sound" },
		{ type = "header", label = L["Rows"] },
	}
	for _, slot in ipairs(Spells.slots) do
		local spell = Spells.InSlot(slot.key)[1]
		local label = slot.label and L["%s (any of yours)"]:format(slot.label) or Spells.Name(spell)
		rows[#rows + 1] = { type = "select", label = label, key = "slots." .. slot.key, values = CHOICES.mode, slash = slot.key }
	end
	rows[#rows + 1] = { type = "header", label = L["Other enemies"] }
	rows[#rows + 1] = { type = "toggle", label = L["List the other enemies I'm fighting"], key = "others", slash = "others" }
	rows[#rows + 1] = { type = "toggle", label = L["Include ones without my DoTs yet"], key = "othersUndotted", slash = "undotted" }
	rows[#rows + 1] = { type = "range", label = L["How many"], key = "othersMax", min = 1, max = 10, step = 1, slash = "othersmax" }
	rows[#rows + 1] = { type = "note", text = L["The list comes from enemy nameplates, so turn those on (V by default). A check mark means every DoT you flag is on."] }

	local position = ns.Frames.PositionOptions(self)
	for _, spec in ipairs({
		{ type = "range", label = L["Width"], key = "width", min = 80, max = 400, step = 1, slash = "width" },
		{ type = "range", label = L["Row height"], key = "rowHeight", min = 8, max = 40, step = 1, slash = "rowheight" },
		{ type = "range", label = L["Icon size for other enemies"], key = "othersIconSize", min = 10, max = 40, step = 1, slash = "iconsize" },
	}) do
		position[#position + 1] = spec
	end
	return {
		{
			name = L["DoTs: what to track"],
			keys = { "enabled", "show", "threshold", "remindOutOfCombat", "sound", "slots", "others", "othersUndotted", "othersMax" },
			controls = rows,
		},
		{
			name = L["DoTs: position"],
			keys = { "position", "scale", "width", "rowHeight", "othersIconSize" },
			controls = position,
		},
		{
			name = L["DoTs: look"],
			keys = { "texture", "font", "fontSize", "fontOutline", "showNames", "spellColors", "barColor", "colors" },
			controls = {
				{ type = "select", label = L["Texture"], key = "texture", slash = "texture",
					values = function() return ns.Media.List("statusbar") end },
				{ type = "select", label = L["Font"], key = "font", slash = "font",
					values = function() return ns.Media.List("font") end },
				{ type = "range", label = L["Font size"], key = "fontSize", min = 6, max = 24, step = 1, slash = "fontsize" },
				{ type = "select", label = L["Outline"], key = "fontOutline", values = CHOICES.outline, slash = "outline" },
				{ type = "toggle", label = L["Spell names on the bars"], key = "showNames", slash = "names" },
				{ type = "toggle", label = L["A color for each spell"], key = "spellColors", slash = "spellcolors" },
				{ type = "color", label = L["Bar color"], key = "barColor", slash = "barcolor" },
				{ type = "color", label = L["Running out"], key = "colors.expiring", slash = "expiringcolor" },
				{ type = "color", label = L["Missing"], key = "colors.missing", slash = "missingcolor" },
				{ type = "color", label = L["Fully dotted"], key = "colors.full", slash = "fullcolor" },
				{ type = "color", label = L["Bar background"], key = "colors.background", alpha = true, slash = "backgroundcolor" },
				{ type = "color", label = L["Text"], key = "colors.text", slash = "textcolor" },
			},
		},
	}
end

---------------------------------------------------------------------------
-- Module hooks and events
---------------------------------------------------------------------------
function Dots:OnInitialize()
	ns:RegisterCommand("check", "check", L["Say what Lockeye can see of your target's DoTs (for bug reports)."], function()
		if not self.enabled then
			ns.Print(L["Lockeye only runs on warlocks."])
			return
		end
		self:Check()
	end)
end

function Dots:ShouldEnable()
	return ns.IsWarlock()
end

function Dots:OnEnable()
	Spells.LoadLearned(self.db.learned)
	self.db.idsWorkInCombat = nil -- 0.1.0's guess about the list, no longer used
	self:CreateFrames()
	local events = ns.CreateEventFrame(self)
	for _, event in ipairs({
		"PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED",
		"NAME_PLATE_UNIT_REMOVED", "UNIT_AURA", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
		"PLAYER_ENTERING_WORLD", "SPELLS_CHANGED",
	}) do
		events:RegisterEvent(event)
	end
	events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
	self.events = events
	self:ApplyLayout()
end

function Dots:OnSettingsReset()
	self:ApplyLayout()
end

function Dots:UNIT_SPELLCAST_SUCCEEDED(_, _, spellID)
	if self.db.enabled and spellID and not ns.IsSecret(spellID) then
		self:OnCast(spellID)
	end
end

-- A unit token now points at another enemy (or none).
local function TokenChanged(unit)
	onUnit[unit], lastIDs[unit] = nil, nil
	state.dirty = true
end

function Dots:PLAYER_TARGET_CHANGED()
	ns.Debug("DoTs: target changed")
	TokenChanged("target")
	state.lastScan = -math.huge -- look at the new target right away
	self:Refresh()
end

function Dots:PLAYER_FOCUS_CHANGED()
	TokenChanged("focus")
end

function Dots:UPDATE_MOUSEOVER_UNIT()
	state.dirty = true
end

function Dots:NAME_PLATE_UNIT_ADDED(unit)
	if unit and not ns.IsSecret(unit) then
		TokenChanged(unit)
	end
	state.dirty = true
end
Dots.NAME_PLATE_UNIT_REMOVED = Dots.NAME_PLATE_UNIT_ADDED

function Dots:UNIT_AURA()
	state.dirty = true
end

function Dots:PLAYER_REGEN_DISABLED()
	fightNumber = fightNumber + 1
	ns.Debug("DoTs: fight starts")
	self:Refresh()
end

function Dots:PLAYER_REGEN_ENABLED()
	ns.Debug("DoTs: fight over")
	self:Refresh()
end

function Dots:SPELLS_CHANGED()
	knownAt = -math.huge
end

-- After a loading screen every aura has a new ID.
function Dots:PLAYER_ENTERING_WORLD()
	for _, list in ipairs({ enemies, byAura, onUnit, lastIDs, unclaimed }) do
		for key in pairs(list) do
			list[key] = nil
		end
	end
	for i = #pending, 1, -1 do
		pending[i] = nil
	end
	state.dirty = true
	self:Refresh()
end

-- For the tests.
Dots.state = state
Dots.known = enemies
Dots.onUnit = onUnit
