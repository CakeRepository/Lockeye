-- Your damage-over-time spells, banes and curses: every rank's spell ID and
-- how long its debuff lasts, read from Forever's spell tables (SpellName,
-- SkillLineAbility and SpellMisc's duration index, client 1.60.1).
--
-- Forever renamed Curse of Agony and Curse of Doom to Bane of Agony and Bane
-- of Doom, and added Bane of Havoc. Each spell sits on a row ("slot") of the
-- tracker: Corruption, Immolate and Siphon Life have one each, your banes
-- share one and your curses share another, as you keep one of each on an
-- enemy. Spells are also matched by name, so a rank this list lacks still
-- counts.
local _, ns = ...
local L = ns.L

local Spells = {}
ns.Spells = Spells

-- ranks: [spell ID] = seconds the debuff lasts.
Spells.list = {
	{ key = "corruption", slot = "corruption", color = { 0.62, 0.36, 0.85 },
		ranks = { [172] = 12, [6222] = 15, [6223] = 18, [7648] = 18, [11671] = 18, [11672] = 18, [25311] = 18 } },
	{ key = "immolate", slot = "immolate", color = { 0.95, 0.45, 0.15 },
		ranks = { [348] = 15, [707] = 15, [1094] = 15, [2941] = 15, [11665] = 15, [11667] = 15, [11668] = 15, [25309] = 15 } },
	{ key = "siphon", slot = "siphon", color = { 0.35, 0.80, 0.40 },
		ranks = { [18265] = 30, [18879] = 30, [18880] = 30, [18881] = 30 } },
	{ key = "agony", slot = "bane", color = { 0.85, 0.30, 0.45 },
		ranks = { [980] = 24, [1014] = 24, [6217] = 24, [11711] = 24, [11712] = 24, [11713] = 24 } },
	{ key = "doom", slot = "bane", color = { 0.55, 0.20, 0.70 }, ranks = { [603] = 60 } },
	{ key = "havoc", slot = "bane", color = { 0.70, 0.25, 0.25 }, ranks = { [1225228] = 300 } },
	{ key = "elements", slot = "curse", color = { 0.30, 0.55, 0.95 },
		ranks = { [440892] = 300, [1311676] = 300, [1311677] = 300, [1311680] = 300 } },
	{ key = "weakness", slot = "curse", color = { 0.60, 0.60, 0.60 },
		ranks = { [702] = 120, [1108] = 120, [6205] = 120, [7646] = 120, [11707] = 120, [11708] = 120 } },
	{ key = "recklessness", slot = "curse", color = { 0.90, 0.30, 0.20 },
		ranks = { [704] = 120, [7658] = 120, [7659] = 120, [11717] = 120 } },
	{ key = "tongues", slot = "curse", color = { 0.70, 0.55, 0.90 }, ranks = { [1714] = 30, [11719] = 30 } },
	{ key = "exhaustion", slot = "curse", color = { 0.40, 0.70, 0.80 }, ranks = { [18223] = 12 } },
	{ key = "idiocy", slot = "curse", color = { 0.80, 0.75, 0.40 }, ranks = { [1010] = 120 } },
}

-- The rows of the tracker, top to bottom. remind: flag it while it's missing
-- from an enemy you fight (the default; the options can change it per row).
Spells.slots = {
	{ key = "corruption", remind = true },
	{ key = "bane", label = L["Bane"], remind = true },
	{ key = "immolate", remind = true },
	{ key = "siphon", remind = true },
	{ key = "curse", label = L["Curse"], remind = false },
}

local byKey, byID, bySlot = {}, {}, {}
for _, spell in ipairs(Spells.list) do
	byKey[spell.key] = spell
	bySlot[spell.slot] = bySlot[spell.slot] or {}
	table.insert(bySlot[spell.slot], spell)
	local first, longest
	for id, seconds in pairs(spell.ranks) do
		byID[id] = spell
		if not first or id < first then
			first = id
		end
		longest = math.max(longest or 0, seconds)
	end
	spell.firstRank, spell.longest = first, longest
end
local slotByKey = {}
for _, slot in ipairs(Spells.slots) do
	slotByKey[slot.key] = slot
end

local learned = {} -- [spell ID] = seconds, from reading the debuff (see Spells.Learn)
local names = {} -- [localized name] = spell

function Spells.Get(key)
	return byKey[key]
end

function Spells.Slot(key)
	return slotByKey[key]
end

function Spells.InSlot(slotKey)
	return bySlot[slotKey] or {}
end

-- The game's name for a spell (any rank), in the client's language.
function Spells.Name(spell)
	if not spell.name then
		spell.name = C_Spell.GetSpellName and ns.Readable(C_Spell.GetSpellName(spell.firstRank)) or nil
		if spell.name then
			names[spell.name] = spell
		end
	end
	return spell.name or spell.key
end

function Spells.Icon(spell, spellID)
	if C_Spell.GetSpellTexture then
		local icon = ns.Readable(C_Spell.GetSpellTexture(spellID or spell.lastRank or spell.firstRank))
		if icon then
			return icon
		end
	end
	return "Interface\\Icons\\Spell_Shadow_AbominationExplosion" -- Corruption's icon
end

-- The tracked spell a cast or a debuff is, by spell ID, then by name.
function Spells.Find(spellID, name)
	if spellID and not ns.IsSecret(spellID) and byID[spellID] then
		return byID[spellID]
	end
	if name == nil and spellID and not ns.IsSecret(spellID) and C_Spell.GetSpellName then
		name = C_Spell.GetSpellName(spellID)
	end
	name = ns.Readable(name)
	if not name then
		return nil
	end
	if not next(names) then
		for _, spell in ipairs(Spells.list) do
			Spells.Name(spell)
		end
	end
	return names[name]
end

-- How long a cast of this spell (rank) lasts on the enemy: what the game
-- showed last time it could be read, else the spell tables' value.
function Spells.Duration(spell, spellID)
	if spellID and not ns.IsSecret(spellID) then
		if learned[spellID] then
			return learned[spellID]
		end
		if spell.ranks[spellID] then
			return spell.ranks[spellID]
		end
	end
	return spell.longest
end

-- The game showed a debuff's full duration: remember it for this rank.
-- Talents or later patches may change what the tables say.
function Spells.Learn(spellID, seconds, store)
	if spellID and seconds and seconds > 0 and not ns.IsSecret(spellID) then
		local rounded = math.floor(seconds * 10 + 0.5) / 10
		learned[spellID] = rounded
		if store then
			store[spellID] = rounded
		end
	end
end

function Spells.LoadLearned(store)
	for id, seconds in pairs(store or {}) do
		if type(id) == "number" and type(seconds) == "number" then
			learned[id] = seconds
		end
	end
end

-- Whether you know any rank of the spell. C_Spell.GetSpellInfo only finds a
-- spell by name when it's in your spellbook.
function Spells.Known(spell)
	local name = Spells.Name(spell)
	if name == spell.key or not C_Spell.GetSpellInfo then
		return false
	end
	local info = ns.Readable(C_Spell.GetSpellInfo(name))
	return type(info) == "table"
end
