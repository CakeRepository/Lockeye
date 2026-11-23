-- Scenario tests for the DoT tracker: your DoTs on your target and the other
-- enemies you fight, remembered per enemy, read when the game allows and
-- matched to your casts when combat makes them secret.
local H, ROOT = ...

local CORRUPTION, CORRUPTION_R1, CORRUPTION_UNLISTED = 25311, 172, 1223963
local IMMOLATE, SIPHON, AGONY, DOOM = 25309, 18881, 11713, 603
local WEAKNESS, FEAR, SHADOW_VULNERABILITY = 702, 5782, 17794

local tests = {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function Setup(options)
	local W = H.NewWorld(options)
	H.LoadAddon(W, ROOT)
	local dots = W.ns.modules.Dots
	return W, dots, dots.frame
end

-- Lets the tracker scan (it does every 0.2s, nameplates every 0.5s).
local function Settle(W)
	W.Advance(0.25)
end

local function Rows(frame)
	local list = {}
	for _, row in ipairs(frame.rows) do
		if row:IsShown() then
			list[#list + 1] = row
		end
	end
	return list
end

local function Find(frame, name)
	for _, row in ipairs(Rows(frame)) do
		if row.name.text == name then
			return row
		end
	end
end

-- "Corruption=17, Bane=Missing, ..." for the target's rows.
local function Summary(frame)
	local parts = {}
	for _, row in ipairs(Rows(frame)) do
		parts[#parts + 1] = row.name.text .. "=" .. row.time.text
	end
	return table.concat(parts, ", ")
end

-- Every DoT Lockeye remembers, on any enemy.
local function Entries(dots)
	local list = {}
	for _, enemy in pairs(dots.known) do
		for _, entry in pairs(enemy.slots) do
			list[#list + 1] = entry
		end
	end
	return list
end

local function TargetEntry(dots, slot)
	local enemy = dots.onUnit.target
	return enemy and enemy.slots[slot]
end

local function Pull(W, name)
	local enemy = W.Enemy(name or "Defias Thug")
	W.Target(enemy)
	return enemy
end

-- The enemy list's shown lines: { name, status mark, cells }
local function Lines(dots)
	local list = {}
	for _, line in ipairs(dots.enemies.lines) do
		if line:IsShown() then
			local name = line.name.text
			if type(name) == "table" then
				name = name[1] -- the mock's secret keeps its value at [1]
			end
			local cells = {}
			for i = #line.cells, 1, -1 do
				local cell = line.cells[i]
				if cell:IsShown() then
					cells[#cells + 1] = cell.icon.desaturated and "missing" or cell.time.text
				end
			end
			list[#list + 1] = { name = name, full = line.mark:IsShown(), cells = table.concat(cells, " ") }
		end
	end
	return list
end

test("loads for a warlock, hidden without a target", function()
	local W, dots, frame = Setup()
	H.True(dots.enabled, "module enabled")
	Settle(W)
	H.False(frame:IsVisible(), "frame visible")
	H.Equal(W.env.LockeyeDB.modules.Dots.threshold, 3, "default threshold")
end)

test("out of combat a DoT is read in full", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	H.True(frame:IsVisible(), "frame visible")
	H.Equal(Summary(frame), "Corruption=17", "only what's on: missing ones aren't flagged before a fight")
	H.True(TargetEntry(dots, "corruption").exact, "the end time came from the game")
end)

test("in combat a secret debuff is matched to the cast that made it", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION, enemy, 18, 0.1)
	Settle(W)
	local row = Find(frame, "Corruption")
	H.Equal(row.time.text, "17", "time left from the cast and the rank's duration")
	H.Near(row.bar.value, 17.65 / 18, 0.02, "bar")
	local entry = TargetEntry(dots, "corruption")
	H.False(entry.exact, "estimated")
	H.Equal(entry.id, enemy.debuffs[1].id, "matched to its debuff")
	H.Equal(entry.spellID, CORRUPTION, "rank")
end)

test("in combat the missing ones are flagged, in row order", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(AGONY, enemy, 24)
	Settle(W)
	H.Equal(Summary(frame), "Corruption=Missing, Bane of Agony=23, Immolate=Missing, Siphon Life=Missing",
		"rows (curses aren't flagged)")
	local rows = Rows(frame)
	H.SameColor(rows[1].time.textColor, dots.db.colors.missing, "missing color")
	H.True(rows[1].icon.desaturated, "gray icon")
end)

test("a spell you don't know isn't flagged", function()
	local W, dots, frame = Setup({ known = { ["Corruption"] = 0, ["Shoot"] = 0 } })
	Pull(W)
	W.EnterCombat()
	Settle(W)
	H.Equal(Summary(frame), "Corruption=Missing", "only Corruption")
end)

test("a DoT about to run out changes color, then shows missing when it ends", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(SIPHON, enemy, 30)
	Settle(W)
	W.Advance(27.05)
	local row = Find(frame, "Siphon Life")
	H.Equal(row.time.text, "2.7", "time left")
	H.SameColor(row.time.textColor, dots.db.colors.expiring, "running out")
	H.SameColor(row.bar.barColor, dots.db.colors.expiring, "bar color")
	W.Advance(3.0)
	H.Equal(Find(frame, "Siphon Life").time.text, "Missing", "gone")
	W.Advance(2.5)
	H.Equal(#Entries(dots), 0, "forgotten")
end)

test("casting it again starts the timer over (the debuff keeps its ID)", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	local aura = W.Cast(IMMOLATE, enemy, 15)
	Settle(W)
	W.Advance(10.05)
	H.Equal(Find(frame, "Immolate").time.text, "4.7", "before the recast")
	W.Cast(IMMOLATE)
	W.RefreshAura(aura, 15)
	Settle(W)
	H.Equal(Find(frame, "Immolate").time.text, "14", "after the recast")
end)

test("a recast that gives the debuff a new ID keeps the row", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	local old = W.Cast(IMMOLATE, enemy, 15)
	Settle(W)
	W.Advance(5)
	W.RemoveAura(enemy, old)
	W.Cast(IMMOLATE, enemy, 15)
	Settle(W)
	W.Advance(2)
	H.Equal(Find(frame, "Immolate").time.text, "12", "the new one")
end)

test("a rank missing from the list is matched by name", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION_UNLISTED, enemy, 18)
	Settle(W)
	H.Equal(Find(frame, "Corruption").time.text, "17", "tracked with the longest listed duration")
end)

test("each rank lasts as long as the spell tables say", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION_R1, enemy, 12)
	Settle(W)
	H.Equal(Find(frame, "Corruption").time.text, "11", "rank 1 lasts 12s")
end)

test("debuffs of yours that aren't DoTs are left out", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(FEAR, enemy, 10)
	Settle(W)
	W.Advance(2.5)
	H.Equal(#Entries(dots), 0, "nothing tracked")
	for _, row in ipairs(Rows(frame)) do
		H.Equal(row.time.text, "Missing", row.name.text .. " flagged")
	end
end)

test("a resisted cast shows missing once the list shows your other debuffs", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(AGONY, enemy, 24)
	Settle(W)
	W.Cast(CORRUPTION) -- resisted: no debuff
	Settle(W)
	H.Equal(Find(frame, "Corruption").time.text, "17", "timed from the cast at first")
	W.Advance(2)
	H.Equal(Find(frame, "Corruption").time.text, "Missing", "it never showed up")
	H.Equal(Find(frame, "Bane of Agony").time.text, "21", "the bane carries on")
end)

test("a debuff that shows up long after a cast isn't taken for it", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION) -- resisted: no debuff
	W.Advance(3)
	W.AddAura(enemy, SHADOW_VULNERABILITY, 12)
	Settle(W)
	W.Advance(2.5)
	H.Equal(Find(frame, "Corruption").time.text, "Missing", "still missing")
	H.Equal(#Entries(dots), 0, "nothing tracked")
end)

test("a debuff that showed up before a cast isn't taken for it", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.StartCast(FEAR, 1.5)
	W.Advance(1.5)
	W.FinishCast()
	W.AddAura(enemy, FEAR, 10)
	Settle(W)
	W.Advance(0.8)
	W.Cast(CORRUPTION) -- resisted: no debuff
	Settle(W)
	W.Advance(2)
	H.Equal(#Entries(dots), 0, "Fear isn't taken for Corruption")
end)

test("works on a client without C_Secrets: secret fields are never read", function()
	local W, dots, frame = Setup({ missingGlobals = { C_Secrets = true } })
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	H.Equal(Find(frame, "Corruption").time.text, "17", "matched to the cast")
	H.False(TargetEntry(dots, "corruption").exact, "estimated")
end)

test("debuffs the game lets addons read stay exact in combat", function()
	local W, dots, frame = Setup()
	W.readableSpells[CORRUPTION] = true
	local enemy = Pull(W)
	W.EnterCombat()
	W.AddAura(enemy, CORRUPTION, 21) -- no cast seen, and a talent made it longer
	Settle(W)
	H.Equal(Find(frame, "Corruption").time.text, "20", "read from the debuff")
	H.True(TargetEntry(dots, "corruption").exact, "exact")
	H.Equal(W.env.LockeyeDB.modules.Dots.learned[CORRUPTION], 21, "duration learned")
end)

test("a duration the game shows is used for later casts", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.Cast(AGONY, enemy, 26) -- out of combat: readable, and longer than the tables' 24s
	Settle(W)
	W.Advance(26)
	W.EnterCombat()
	W.Cast(AGONY, enemy, 26)
	Settle(W)
	H.Equal(Find(frame, "Bane of Agony").time.text, "25", "the learned 26s")
end)

test("a duration object without secrets gives the exact time", function()
	local W, dots, frame = Setup()
	W.durationsSecret = false
	local enemy = Pull(W)
	W.EnterCombat()
	local aura = W.Cast(SIPHON, enemy, 30)
	Settle(W)
	aura.expires = aura.expires - 5 -- the server's clock says it ends sooner
	Settle(W)
	H.Equal(Find(frame, "Siphon Life").time.text, "24", "from the duration object")
end)

test("a new bane replaces the old one on the bane row", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	local agony = W.Cast(AGONY, enemy, 24)
	Settle(W)
	W.Advance(2)
	W.Cast(DOOM)
	Settle(W) -- the old bane is still listed for a moment
	H.Equal(TargetEntry(dots, "bane").id, nil, "Doom isn't taken for the old bane's debuff")
	W.RemoveAura(enemy, agony) -- one bane per enemy: Doom replaces Agony
	W.AddAura(enemy, DOOM, 60)
	Settle(W)
	W.Advance(2)
	H.Equal(Rows(frame)[2].name.text, "Bane of Doom", "bane row")
	H.Equal(Rows(frame)[2].time.text, "57", "its time")
	H.Equal(TargetEntry(dots, "bane").id, enemy.debuffs[1].id, "matched to the new debuff, not the old one")
end)

test("a curse shows while it's on but isn't flagged when missing", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	H.Equal(Find(frame, "Curse"), nil, "no curse row")
	local curse = W.Cast(WEAKNESS, enemy, 120)
	Settle(W)
	H.Equal(Find(frame, "Curse of Weakness").time.text, "1:59", "curse row")
	dots.db.slots.curse = "remind"
	W.RemoveAura(enemy, curse) -- dispelled
	Settle(W)
	H.Equal(Find(frame, "Curse").time.text, "Missing", "flagged once asked to")
end)

test("when the list comes back empty in combat, timers carry on", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	W.auraIDsHidden = true -- the game stops listing them
	W.Advance(1)
	H.Equal(Find(frame, "Corruption").time.text, "16", "still timed")
end)

test("a row can be turned off", function()
	local W, dots, frame = Setup()
	dots.db.slots.siphon = "off"
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(SIPHON, enemy, 30)
	Settle(W)
	H.Equal(Find(frame, "Siphon Life"), nil, "no Siphon Life row")
end)

---------------------------------------------------------------------------
-- Switching targets
---------------------------------------------------------------------------
-- Dots on A, tab to B, tab back to A.
local function TabAwayAndBack(W, frame)
	local a, b = W.Enemy("A"), W.Enemy("B")
	W.Target(a)
	W.EnterCombat()
	W.Cast(CORRUPTION, a, 18)
	W.Cast(AGONY, a, 24)
	Settle(W)
	W.Target(b)
	Settle(W)
	local onB = Summary(frame)
	W.Advance(2)
	W.Target(a)
	Settle(W)
	return a, b, onB
end

test("tabbing away and back keeps your target's DoTs", function()
	local W, dots, frame = Setup()
	local _, _, onB = TabAwayAndBack(W, frame)
	H.Equal(onB, "Corruption=Missing, Bane=Missing, Immolate=Missing, Siphon Life=Missing", "the other target")
	H.Equal(Summary(frame), "Corruption=15, Bane of Agony=21, Immolate=Missing, Siphon Life=Missing", "back")
end)

test("tabbing back when the game gives the debuffs new IDs keeps them, matched again", function()
	local W, dots, frame = Setup()
	W.newIDsOnRetarget = true
	local a = TabAwayAndBack(W, frame)
	H.Equal(Summary(frame), "Corruption=15, Bane of Agony=21, Immolate=Missing, Siphon Life=Missing", "back")
	for _, aura in ipairs(a.debuffs) do
		local slot = aura.name == "Corruption" and "corruption" or "bane"
		H.Equal(TargetEntry(dots, slot).id, aura.id, aura.name .. " matched to its new ID")
	end
	-- Matched right: removing Corruption's debuff removes Corruption.
	W.RemoveAura(a, a.debuffs[1])
	Settle(W)
	H.Equal(Summary(frame), "Corruption=Missing, Bane of Agony=21, Immolate=Missing, Siphon Life=Missing", "dispelled")
end)

test("new IDs are matched by the game's order even with other debuffs of yours mixed in", function()
	local W, dots, frame = Setup()
	W.newIDsOnRetarget = true
	local a, b = W.Enemy("A"), W.Enemy("B")
	W.Target(a)
	W.EnterCombat()
	W.Cast(SIPHON, a, 30)
	Settle(W)
	W.Advance(1.6) -- the global cooldown
	W.Cast(CORRUPTION, a, 18)
	Settle(W)
	W.Advance(1.6)
	W.AddAura(a, SHADOW_VULNERABILITY, 12) -- a talent's debuff, not tracked
	W.Advance(2.2)
	W.Cast(IMMOLATE, a, 15)
	Settle(W)
	W.Advance(2)
	W.Target(b)
	Settle(W)
	W.Target(a)
	Settle(W)
	H.Equal(Summary(frame), "Corruption=11, Bane=Missing, Immolate=12, Siphon Life=21", "back")
	for _, aura in ipairs(a.debuffs) do
		local slot = ({ Corruption = "corruption", Immolate = "immolate", ["Siphon Life"] = "siphon" })[aura.name]
		if slot then
			H.Equal(TargetEntry(dots, slot).id, aura.id, aura.name .. " matched to its new ID")
		end
	end
end)

test("a DoT that ran out while you were away doesn't confuse the rest", function()
	local W, dots, frame = Setup()
	W.newIDsOnRetarget = true
	local a, b = W.Enemy("A"), W.Enemy("B")
	W.Target(a)
	W.EnterCombat()
	W.Cast(CORRUPTION_R1, a, 12)
	Settle(W)
	W.Advance(1.6)
	W.Cast(AGONY, a, 24)
	Settle(W)
	W.Target(b)
	W.Advance(12)
	W.Target(a)
	Settle(W)
	H.Equal(Summary(frame), "Corruption=Missing, Bane of Agony=11, Immolate=Missing, Siphon Life=Missing", "back")
	H.Equal(TargetEntry(dots, "bane").id, a.debuffs[1].id, "the bane matched to its new ID")
end)

test("with the debuff list hidden in combat, casts are remembered per enemy", function()
	local W, dots, frame = Setup()
	W.auraIDsHidden = true
	local _, _, onB = TabAwayAndBack(W, frame)
	H.Equal(onB, "Corruption=Missing, Bane=Missing, Immolate=Missing, Siphon Life=Missing", "the other target")
	H.Equal(Summary(frame), "Corruption=15, Bane of Agony=21, Immolate=Missing, Siphon Life=Missing", "back")
end)

test("with enemy GUIDs hidden, debuffs that keep their IDs still find their enemy", function()
	local W, dots, frame = Setup()
	W.guidsSecret = true
	TabAwayAndBack(W, frame)
	H.Equal(Summary(frame), "Corruption=15, Bane of Agony=21, Immolate=Missing, Siphon Life=Missing", "back")
end)

test("with enemy GUIDs hidden and new IDs, your target's nameplate keeps its DoTs", function()
	local W, dots, frame = Setup()
	W.guidsSecret, W.newIDsOnRetarget = true, true
	local a, b = W.Enemy("A"), W.Enemy("B")
	W.ShowPlates({ a, b })
	W.Target(a)
	W.EnterCombat()
	W.Cast(CORRUPTION, a, 18)
	W.Cast(AGONY, a, 24)
	Settle(W)
	W.Advance(0.6) -- the nameplates get looked at
	H.Equal(#Lines(dots), 0, "your target isn't listed again")
	W.Target(b)
	Settle(W)
	W.Advance(0.6)
	H.Equal(Summary(frame), "Corruption=Missing, Bane=Missing, Immolate=Missing, Siphon Life=Missing", "the other target")
	H.Equal(Lines(dots)[1].name, "A", "A is listed")
	H.Equal(Lines(dots)[1].cells, "16 22 missing missing", "with its DoTs")
	W.Target(a)
	Settle(W)
	H.Equal(Summary(frame), "Corruption=16, Bane of Agony=22, Immolate=Missing, Siphon Life=Missing", "back")
	H.Equal(#Lines(dots), 0, "B isn't fighting you and has no DoTs")
end)

test("the log keeps what the tracker saw and showed", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	local log = table.concat(W.env.LockeyeDB.logLines, "\n")
	H.True(log:find("Lockeye 0.4.0 logged in: WARLOCK", 1, true) ~= nil, "session line")
	H.True(log:find("DoTs: cast Corruption 25311 at enemy", 1, true) ~= nil, "the cast")
	H.True(log:find("target: enemy %x+, list %d+=new, threat 1, in combat") ~= nil, "what the game showed")
	H.True(log:find("Corruption is aura %d+ %(matched to the cast%)") ~= nil, "what Lockeye made of it")
	H.True(log:find("DoTs show: target Corruption=on Bane=missing", 1, true) ~= nil, "what the tracker showed")
	W.Slash("log off")
	local count = #W.env.LockeyeDB.logLines
	W.Cast(AGONY, enemy, 24)
	Settle(W)
	H.Equal(#W.env.LockeyeDB.logLines, count, "nothing more once it's off")
end)

test("an error in the tracker goes to the log instead of breaking it", function()
	local W = H.NewWorld()
	W.keepErrors = true
	H.LoadAddon(W, ROOT)
	local dots = W.ns.modules.Dots
	local enemy = Pull(W)
	local model = dots.Model
	dots.Model = function()
		error("boom")
	end
	W.Advance(0.3)
	H.True(#W.ns.errors > 0, "error kept")
	local log = table.concat(W.env.LockeyeDB.logLines, "\n")
	H.True(log:find("ERROR in DoT tracker:", 1, true) ~= nil, "in the log")
	local said = 0
	for _, line in ipairs(W.printed) do
		if line:find("Lockeye hit an error", 1, true) then
			said = said + 1
		end
	end
	H.Equal(said, 1, "said once in chat")
	dots.Model = model
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	H.Equal(Summary(dots.frame), "Corruption=17", "works again")
end)

---------------------------------------------------------------------------
-- Other enemies
---------------------------------------------------------------------------
test("the list shows the other enemies you fight, fully dotted ones checked", function()
	local W, dots, frame = Setup({ known = { ["Corruption"] = 0, ["Bane of Agony"] = 0, ["Shoot"] = 0 } })
	local a, b, c = W.Enemy("A"), W.Enemy("B"), W.Enemy("C")
	W.ShowPlates({ a, b, c })
	W.EnterCombat()
	W.Target(a)
	W.Cast(CORRUPTION, a, 18)
	W.Cast(AGONY, a, 24)
	Settle(W)
	W.Target(b)
	W.Cast(CORRUPTION, b, 18)
	Settle(W)
	c.fighting = true -- it's hitting you, no DoTs yet
	W.Target(W.Enemy("D"))
	W.Advance(0.6)
	local lines = Lines(dots)
	H.Equal(#lines, 3, "three other enemies")
	H.Equal(lines[1].name, "C", "missing everything: first")
	H.Equal(lines[1].cells, "missing missing", "both flagged")
	H.Equal(lines[2].name, "B", "missing the bane: next")
	H.Equal(lines[2].cells, "17 missing", "Corruption on, bane missing")
	H.False(lines[2].full, "no check")
	H.Equal(lines[3].name, "A", "fully dotted: last")
	H.True(lines[3].full, "check mark")
	H.Equal(lines[3].cells, "16 22", "both on")
	H.Equal(dots.enemies.header.text, "Other enemies: 1 of 3 fully dotted", "header")
	W.Advance(14) -- A's Corruption runs low
	lines = Lines(dots)
	H.Equal(lines[3].name, "A", "still after the ones missing DoTs")
	H.False(lines[3].full, "no check while one runs low")
	H.Equal(dots.enemies.header.text, "Other enemies: 0 of 3 fully dotted", "header")
end)

test("an enemy you fought stays listed even when its threat answer blinks", function()
	local W, dots, frame = Setup()
	local a, b = W.Enemy("A"), W.Enemy("B")
	W.ShowPlates({ a, b })
	W.EnterCombat()
	W.Target(a)
	W.Cast(CORRUPTION, a, 18)
	b.fighting = true
	W.Advance(0.6)
	H.Equal(#Lines(dots), 1, "B listed")
	b.fighting = false -- the game says it isn't on its threat list for a moment
	W.Advance(0.6)
	H.Equal(#Lines(dots), 1, "still listed")
	W.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
	W.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2") -- its nameplate comes back
	W.Advance(0.06)
	H.Equal(#Lines(dots), 1, "still listed right away")
	W.LeaveCombat()
	W.EnterCombat() -- a new fight
	W.Advance(0.6)
	H.Equal(#Lines(dots), 0, "not fighting you in this one")
end)

test("your target isn't listed again, even when its nameplate shows", function()
	local W, dots, frame = Setup()
	local a, b = W.Enemy("A"), W.Enemy("B")
	W.ShowPlates({ a, b })
	W.EnterCombat()
	W.Target(a)
	W.Cast(CORRUPTION, a, 18)
	W.Advance(0.6)
	H.Equal(#Lines(dots), 0, "nobody else")
	H.False(dots.enemies:IsShown(), "list hidden")
	W.Target(b)
	W.Advance(0.6)
	local lines = Lines(dots)
	H.Equal(#lines, 1, "A is listed now")
	H.Equal(lines[1].name, "A", "A")
end)

test("enemies you aren't fighting and haven't dotted stay off the list", function()
	local W, dots, frame = Setup()
	local a, b = W.Enemy("A"), W.Enemy("Bystander")
	W.ShowPlates({ a, b })
	W.EnterCombat()
	W.Target(a)
	W.Cast(CORRUPTION, a, 18)
	W.Advance(0.6)
	H.Equal(#Lines(dots), 0, "the bystander isn't listed")
	dots.db.othersUndotted = false
	b.fighting = true
	W.Advance(0.6)
	H.Equal(#Lines(dots), 0, "undotted enemies left out when asked")
end)

test("the list shows the newest times after a target switch", function()
	local W, dots, frame = Setup()
	W.newIDsOnRetarget = true
	local a, b = W.Enemy("A"), W.Enemy("B")
	W.ShowPlates({ a, b })
	W.EnterCombat()
	W.Target(a)
	W.Cast(SIPHON, a, 30)
	Settle(W)
	W.Target(b)
	W.Advance(5)
	local lines = Lines(dots)
	H.Equal(lines[1].name, "A", "A listed")
	H.True(lines[1].cells:find("24", 1, true) ~= nil, "Siphon Life's time")
end)

test("an enemy dying clears its DoTs", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	enemy.dead, enemy.debuffs = true, {}
	Settle(W)
	H.Equal(#Entries(dots), 0, "forgotten")
	H.False(frame:IsVisible(), "nothing to show for a corpse")
end)

---------------------------------------------------------------------------
-- The rest
---------------------------------------------------------------------------
test("a sound plays once as a DoT on your target runs out", function()
	local W, dots, frame = Setup()
	dots.db.sound = "PING"
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	H.Equal(#W.sounds, 0, "no sound yet")
	W.Advance(15.2)
	H.Equal(#W.sounds, 1, "one sound")
	W.Advance(1)
	H.Equal(#W.sounds, 1, "still one")
end)

test("a loading screen forgets every debuff", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	H.Equal(#Entries(dots), 1, "tracked")
	W.units.target = nil -- off to another zone
	W.Fire("PLAYER_ENTERING_WORLD", false, false)
	H.Equal(#Entries(dots), 0, "forgotten")
end)

test("test mode shows sample rows and enemies", function()
	local W, dots, frame = Setup()
	W.Slash("test")
	W.Advance(0.1)
	H.True(frame:IsVisible(), "frame visible")
	H.Equal(#Rows(frame), 4, "sample rows")
	H.Equal(Rows(frame)[3].time.text, "Missing", "a missing one")
	H.Equal(#Lines(dots), 3, "sample enemies")
	H.True(Lines(dots)[3].full, "one fully dotted")
	W.Slash("test")
	W.Advance(0.1)
	H.False(frame:IsVisible(), "hidden again")
end)

test("turning the tracker off hides it", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.Slash("dots off")
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	H.False(frame:IsVisible(), "hidden")
	H.Equal(#Entries(dots), 0, "nothing tracked")
	W.Slash("dots on")
	Settle(W)
	H.True(frame:IsVisible(), "shown again")
end)

test("/lockeye check says what it can see", function()
	local W, dots, frame = Setup()
	local enemy = Pull(W)
	W.EnterCombat()
	W.Cast(CORRUPTION, enemy, 18)
	Settle(W)
	W.Slash("check")
	H.True(W.Printed("the game shows it"), "GUID readable")
	H.True(W.Printed("the game lists 1"), "list")
	H.True(W.Printed("Corruption: 17."), "the DoT")
	H.True(W.Printed("matched to its debuff"), "how it's known")
end)

return tests
