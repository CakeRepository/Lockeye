-- Tests for the Nightfall alert: Shadow Trance makes the next Shadow Bolt
-- instant, and a purple bar shows until it's cast or runs out.
local H, ROOT = ...

local SHADOW_BOLT, SHADOW_TRANCE = 686, 17941

local tests = {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function Setup(options)
	local W = H.NewWorld(options)
	H.LoadAddon(W, ROOT)
	local nightfall = W.ns.modules.Nightfall
	return W, nightfall, nightfall.frame
end

-- The trance starts: Shadow Bolt is listed as instant, and the buff is on.
local function Trance(W, seconds)
	W.known["Shadow Bolt"] = 0
	W.playerBuffs[SHADOW_TRANCE] = { duration = seconds or 10, expires = W.now + (seconds or 10) }
	W.Fire("UNIT_AURA", "player", {})
end

local function EndTrance(W)
	W.known["Shadow Bolt"] = 3000
	W.playerBuffs[SHADOW_TRANCE] = nil
	W.Fire("UNIT_AURA", "player", {})
end

test("loads for a warlock, hidden until a trance", function()
	local W, nightfall, frame = Setup()
	H.True(nightfall.enabled, "module enabled")
	W.Advance(0.3)
	H.False(frame:IsVisible(), "hidden")
	H.Equal(#W.printed, 0, "nothing said at login")
end)

test("in combat, Shadow Bolt turning instant shows the alert", function()
	local W, nightfall, frame = Setup()
	W.EnterCombat()
	Trance(W) -- the buff's details are secret in combat
	W.Advance(0.15)
	H.True(frame:IsVisible(), "shown")
	H.Equal(frame.text.text, "Instant Shadow Bolt  9.9", "text with the time left")
	H.Near(frame.bar.value, 0.99, 0.02, "bar full")
	W.Advance(4)
	H.Near(frame.bar.value, 0.59, 0.02, "drains")
	local log = table.concat(W.env.LockeyeDB.logLines, "\n")
	H.True(log:find("Nightfall: Shadow Trance, instant Shadow Bolt (seen by Shadow Bolt's cast time)", 1, true) ~= nil, "logged")
end)

test("casting the instant Shadow Bolt ends it", function()
	local W, nightfall, frame = Setup()
	W.EnterCombat()
	Trance(W)
	W.Advance(1)
	W.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-9", SHADOW_BOLT) -- the cast time comes back a moment later
	W.Advance(0.15)
	H.False(frame:IsVisible(), "hidden at once")
	EndTrance(W)
	W.Advance(0.5)
	H.False(frame:IsVisible(), "stays hidden")
end)

test("it ends when Shadow Bolt has its cast time again (the trance ran out)", function()
	local W, nightfall, frame = Setup()
	W.EnterCombat()
	Trance(W)
	W.Advance(10)
	EndTrance(W)
	W.Advance(0.15)
	H.False(frame:IsVisible(), "hidden")
end)

test("a readable buff gives the exact time", function()
	local W, nightfall, frame = Setup()
	Trance(W, 6) -- out of combat: readable
	W.Advance(0.15)
	H.Equal(frame.text.text, "Instant Shadow Bolt  5.9", "the buff's end")
	H.Equal(W.env.LockeyeDB.modules.Nightfall.learned, 6, "its length remembered")
end)

test("the proc glow alone shows it, and its end hides it", function()
	local W, nightfall, frame = Setup()
	W.EnterCombat()
	W.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", SHADOW_BOLT)
	W.Advance(0.15)
	H.True(frame:IsVisible(), "shown")
	W.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", SHADOW_BOLT)
	W.Advance(0.15)
	H.False(frame:IsVisible(), "hidden")
end)

test("another spell's glow doesn't", function()
	local W, nightfall, frame = Setup()
	W.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", 348)
	W.Advance(0.15)
	H.False(frame:IsVisible(), "hidden")
end)

test("it pulses, unless that's turned off", function()
	local W, nightfall, frame = Setup()
	W.EnterCombat()
	Trance(W)
	local seen = {}
	for _ = 1, 10 do
		W.Advance(0.05)
		seen[string.format("%.2f", frame.alpha)] = true
	end
	local count = 0
	for _ in pairs(seen) do
		count = count + 1
	end
	H.True(count > 3, "its brightness changes")
	W.Slash("nightfall pulse off")
	W.Advance(0.1)
	H.Equal(frame.alpha, 1, "steady")
end)

test("a sound plays once when a trance starts, if one is picked", function()
	local W, nightfall, frame = Setup()
	nightfall.db.sound = "PING"
	W.EnterCombat()
	Trance(W)
	W.Advance(2)
	H.Equal(#W.sounds, 1, "one sound")
end)

test("turned off, nothing shows", function()
	local W, nightfall, frame = Setup()
	W.Slash("nightfall off")
	Trance(W)
	W.Advance(0.3)
	H.False(frame:IsVisible(), "hidden")
end)

test("it sits above the character, and test mode shows it", function()
	local W, nightfall, frame = Setup()
	local point = frame.points[1]
	H.Equal(point[1], "CENTER", "anchored by its center")
	H.True(point[5] > 0, "above the middle of the screen")
	W.Slash("test")
	W.Advance(0.15)
	H.True(frame:IsVisible(), "shown in test mode")
	W.Slash("test")
	W.Advance(0.15)
	H.False(frame:IsVisible(), "hidden again")
end)

test("stays off for other classes", function()
	local W = H.NewWorld({ class = "PRIEST" })
	H.LoadAddon(W, ROOT)
	H.False(W.ns.modules.Nightfall.enabled, "off")
end)

return tests
