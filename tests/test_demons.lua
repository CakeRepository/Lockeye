-- Tests for demon abilities: what each demon knows is noted when it's
-- summoned, and the demon trainer's grimoires are marked against it.
local H, ROOT = ...

local tests = {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function Setup(options)
	local W = H.NewWorld(options)
	H.LoadAddon(W, ROOT)
	local demons = W.ns.modules.Demons
	return W, demons
end

local IMP = {
	{ "Firebolt", "Rank 3" }, { "Blood Pact", "Rank 2" }, { "Phase Shift", "" },
	{ "Attack", "" }, { "Follow", "" }, -- commands, not grimoire abilities
}
local VOIDWALKER = { { "Torment", "Rank 2" }, { "Sacrifice", "Rank 1" } }

-- The demon trainer's wares: grimoires for the Imp, Voidwalker and Felhunter, and a reagent.
local TRAINER = {
	{ id = 16302, name = "Grimoire of Firebolt (Rank 2)" },
	{ id = 16316, name = "Grimoire of Firebolt (Rank 4)" },
	{ id = 16321, name = "Grimoire of Fire Shield (Rank 1)" },
	{ id = 16346, name = "Grimoire of Torment (Rank 2)" },
	{ id = 16352, name = "Grimoire of Consume Shadows (Rank 1)" },
	{ id = 16379, name = "Grimoire of Devour Magic (Rank 2)" },
	{ id = 6265, name = "Soul Shard" },
}

local function Badge(W, i)
	local badge = W.env["MerchantItem" .. i .. "ItemButton"].lockeyeBadge
	if not (badge and badge:IsShown()) then
		return nil
	end
	return badge.text
end

local function Marks(W)
	local list = {}
	for i = 1, #W.merchantItems do
		list[#list + 1] = Badge(W, i) or "-"
	end
	return table.concat(list, " ")
end

test("summoning a demon notes its abilities and ranks for this character", function()
	local W, demons = Setup()
	H.True(demons.enabled, "module enabled")
	W.SummonDemon("Imp", IMP)
	local imp = W.env.LockeyeCharDB.demons.Imp
	H.True(imp ~= nil, "the Imp is noted")
	H.Equal(imp.abilities.Firebolt, 3, "Firebolt rank")
	H.Equal(imp.abilities["Blood Pact"], 2, "Blood Pact rank")
	H.Equal(imp.abilities["Phase Shift"], 1, "an ability without ranks")
	H.Equal(imp.abilities.Attack, nil, "commands are left out")
	H.Equal(W.env.LockeyeDB.modules.Demons.marks, true, "settings stay in the account-wide table")
end)

test("the demon trainer marks each grimoire against what your demons know", function()
	local W = Setup()
	W.SummonDemon("Imp", IMP)
	W.SummonDemon("Voidwalker", VOIDWALKER)
	W.OpenVendor(TRAINER)
	-- Firebolt 2: the Imp has 3. Firebolt 4: an upgrade. Fire Shield: new.
	-- Torment 2: known. Consume Shadows: new. Devour Magic: the Felhunter was never summoned.
	H.Equal(Marks(W), "Known Upgrade New Known New ? -", "marks")
	local color = W.env.MerchantItem2ItemButton.lockeyeBadge.textColor
	H.SameColor(color, { 1, 0.82, 0 }, "upgrades in gold")
end)

test("a demon learning a new rank updates the marks", function()
	local W = Setup()
	W.SummonDemon("Imp", IMP)
	W.OpenVendor(TRAINER)
	H.Equal(Badge(W, 2), "Upgrade", "before")
	W.units.pet.spells[1] = { "Firebolt", "Rank 4" } -- the grimoire was used
	W.Fire("SPELLS_CHANGED")
	H.Equal(W.env.LockeyeCharDB.demons.Imp.abilities.Firebolt, 4, "noted")
	H.Equal(Badge(W, 2), "Known", "after")
end)

test("a spellbook the game fills in late is read again a moment later", function()
	local W = Setup()
	W.SummonDemon("Voidwalker", VOIDWALKER)
	W.OpenVendor({ { id = 16388, name = "Grimoire of Sacrifice (Rank 2)" } })
	H.Equal(Badge(W, 1), "Upgrade", "it has Sacrifice 1")
	-- The grimoire is used: the game says the spells changed while the
	-- spellbook still shows Rank 1, and it catches up a moment later.
	W.Fire("SPELLS_CHANGED")
	W.units.pet.spells[2] = { "Sacrifice", "Rank 2" }
	H.Equal(Badge(W, 1), "Upgrade", "the first look saw the old rank")
	W.Advance(1.2)
	H.Equal(Badge(W, 1), "Known", "looked again")
	local voidwalker = W.env.LockeyeCharDB.demons.Voidwalker
	H.Equal(voidwalker.abilities.Sacrifice, 2, "Sacrifice 2")
	-- What changed is kept, newest first, to check a wrong rank later.
	H.True(voidwalker.changes[1]:find("SPELLS_CHANGED +1s: Sacrifice 1>2", 1, true) ~= nil, voidwalker.changes[1])
	H.True(voidwalker.changes[2]:find("UNIT_PET: Sacrifice ->1", 1, true) ~= nil, voidwalker.changes[2])
end)

test("a demon whose spells show up after it's summoned still gets noted", function()
	local W = Setup()
	W.SummonDemon("Imp", {}) -- the spellbook is still empty when the game says the demon is out
	H.Equal(W.env.LockeyeCharDB.demons.Imp, nil, "nothing to note yet")
	for i, spell in ipairs(IMP) do
		W.units.pet.spells[i] = spell
	end
	W.Advance(3.2)
	H.Equal(W.env.LockeyeCharDB.demons.Imp.abilities.Firebolt, 3, "noted")
	-- A burst of events: one look each, and one more look after the last.
	local reads = W.petSpellbookReads
	for i = 1, 20 do
		W.Fire("PET_BAR_UPDATE")
	end
	W.Advance(5)
	H.Equal(W.petSpellbookReads - reads, 20 + 2, "spellbook reads")
	H.Equal(#W.env.LockeyeCharDB.demons.Imp.changes, 1, "one change: the first look")
	for i = 1, 12 do
		W.units.pet.spells[1] = { "Firebolt", "Rank " .. (3 + i % 2) }
		W.Fire("SPELLS_CHANGED")
	end
	H.Equal(#W.env.LockeyeCharDB.demons.Imp.changes, 10, "only the last ten changes are kept")
end)

test("the marks follow the vendor's pages and hide on the Buyback tab", function()
	local W = Setup()
	W.SummonDemon("Imp", IMP)
	local items = {}
	for i = 1, 10 do
		items[i] = { id = 100 + i, name = "Soul Shard" }
	end
	items[11] = { id = 16316, name = "Grimoire of Firebolt (Rank 4)" }
	W.OpenVendor(items)
	H.Equal(Badge(W, 1), nil, "page 1: no grimoires")
	W.env.MerchantFrame.page = 2
	W.env.MerchantFrame_UpdateMerchantInfo()
	H.Equal(Badge(W, 1), "Upgrade", "page 2, first item")
	W.env.MerchantFrame.selectedTab = 2
	W.env.MerchantFrame_UpdateBuybackInfo()
	H.Equal(Badge(W, 1), nil, "buyback")
end)

test("the list of your demons opens beside the trainer's window", function()
	local W, demons = Setup()
	W.SummonDemon("Imp", IMP)
	W.OpenVendor(TRAINER)
	local panel = demons.panel
	H.True(panel:IsShown(), "shown")
	H.Equal(panel.points[1][2], W.env.MerchantFrame, "beside the vendor window")
	local lines = demons:PanelLines()
	H.Equal(lines[1].demon, "Imp", "the Imp first")
	H.Equal(lines[1].text, "Firebolt 3, Blood Pact 2, |cff999999Fire Shield no|r, Phase Shift 1", "its abilities")
	H.Equal(lines[2].demon, "Voidwalker", "then the Voidwalker")
	H.True(lines[2].text:find("not summoned yet", 1, true) ~= nil, "not summoned yet")
	W.CloseVendor()
	H.False(panel:IsShown(), "hidden with the vendor")
end)

test("a vendor without grimoires gets no list, and closing it keeps it closed for that visit", function()
	local W, demons = Setup()
	W.OpenVendor({ { id = 6265, name = "Soul Shard" } })
	H.False(demons.panel:IsShown(), "no list at a reagent vendor")
	W.CloseVendor()
	W.OpenVendor(TRAINER)
	H.True(demons.panel:IsShown(), "shown at the trainer")
	W.Click(select(1, (function()
		for _, frame in ipairs(W.frames) do
			if frame.parent == demons.panel and frame.frameType == "Button" then
				return frame
			end
		end
	end)()))
	H.False(demons.panel:IsShown(), "closed")
	W.env.MerchantFrame_UpdateMerchantInfo()
	H.False(demons.panel:IsShown(), "stays closed on the next page")
	W.CloseVendor()
	W.OpenVendor(TRAINER)
	H.True(demons.panel:IsShown(), "back on the next visit")
end)

test("names that arrive after the window opens still get marked", function()
	local W, demons = Setup()
	W.SummonDemon("Imp", IMP)
	W.OpenVendor({ { id = 16316, name = nil } }) -- not in the item cache yet
	H.Equal(Badge(W, 1), nil, "nothing to mark yet")
	H.False(demons.panel:IsShown(), "no list yet")
	W.merchantItems[1].name = "Grimoire of Firebolt (Rank 4)"
	W.env.MerchantFrame_UpdateMerchantInfo() -- the window redraws when the item loads
	H.Equal(Badge(W, 1), "Upgrade", "marked")
	H.True(demons.panel:IsShown(), "list shown")
end)

test("grimoire tooltips say what your demon has", function()
	local W = Setup()
	W.SummonDemon("Imp", IMP)
	W.itemNames[16316] = "Grimoire of Firebolt (Rank 4)"
	W.itemNames[16379] = "Grimoire of Devour Magic (Rank 2)"
	W.itemNames[6265] = "Soul Shard"
	local lines = W.ItemTooltip(16316)
	H.Equal(#lines, 1, "one line")
	H.True(lines[1].text:find("Upgrade: your Imp has Firebolt (Rank 3).", 1, true) ~= nil, lines[1].text)
	lines = W.ItemTooltip(16379)
	H.True(lines[1].text:find("Summon your Felhunter once", 1, true) ~= nil, "never summoned")
	H.Equal(#W.ItemTooltip(6265), 0, "nothing on other items")
	W.Slash("demons tooltips off")
	H.Equal(#W.ItemTooltip(16316), 0, "nothing when turned off")
end)

test("a grimoire goes with the longest ability name in it", function()
	local W, demons = Setup()
	-- Another demon whose abilities are words inside the Imp's Fire Shield.
	W.SummonDemon("Felguard", { { "Fire", "Rank 1" }, { "Shield", "Rank 1" } })
	W.SummonDemon("Imp", IMP)
	local grimoire = demons:Grimoire("Grimoire of Fire Shield (Rank 2)")
	H.Equal(grimoire.ability, "Fire Shield", "ability")
	H.Equal(grimoire.demon, "Imp", "demon")
	H.Equal(grimoire.rank, 2, "rank")
	H.Equal(demons:Grimoire("Soul Shard"), nil, "not a grimoire")
end)

test("the list can stay away from the trainer", function()
	local W, demons = Setup()
	W.Slash("demons panel off")
	W.OpenVendor(TRAINER)
	H.False(demons.panel:IsShown(), "not shown")
	H.Equal(Badge(W, 1), "?", "the marks still show")
end)

test("what a demon knows is kept between sessions", function()
	local W = Setup()
	W.SummonDemon("Voidwalker", VOIDWALKER)
	local saved = W.env.LockeyeCharDB
	local W2 = H.NewWorld({ charVariables = saved })
	H.LoadAddon(W2, ROOT)
	W2.OpenVendor(TRAINER)
	H.Equal(Badge(W2, 4), "Known", "Torment, with no demon out")
end)

test("/lockeye demons shows the list anywhere", function()
	local W, demons = Setup()
	W.SummonDemon("Imp", IMP)
	W.Slash("demons")
	H.True(demons.panel:IsShown(), "shown")
	W.Slash("demons")
	H.False(demons.panel:IsShown(), "hidden")
	W.Slash("demons settings")
	H.True(W.Printed("marks"), "settings listed")
	W.Slash("demons marks off")
	W.OpenVendor(TRAINER)
	H.Equal(Badge(W, 1), nil, "no marks when turned off")
end)

test("stays off for other classes", function()
	local W = H.NewWorld({ class = "PRIEST" })
	H.LoadAddon(W, ROOT)
	H.False(W.ns.modules.Demons.enabled, "off")
	W.OpenVendor(TRAINER)
end)

return tests
