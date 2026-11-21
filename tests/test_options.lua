-- Tests for the options window, chat settings and the frame lock.
local H, ROOT = ...

local tests = {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function Setup(options)
	local W = H.NewWorld(options)
	H.LoadAddon(W, ROOT)
	return W, W.ns.OptionsWindow
end

local function Open(W)
	W.Slash("")
	return W.ns.OptionsWindow
end

test("/lockeye opens and closes the options window", function()
	local W, window = Setup()
	H.False(window:IsOpen(), "closed at login")
	Open(W)
	H.True(window:IsOpen(), "open")
	W.Slash("")
	H.False(window:IsOpen(), "closed again")
end)

test("the window lists the DoT pages, then the wand pages", function()
	local W = Setup()
	local window = Open(W)
	local names = {}
	for _, section in ipairs(window.sections) do
		names[#names + 1] = section.name
	end
	H.Equal(table.concat(names, ", "),
		"DoTs: what to track, DoTs: position, DoTs: look, Wand: position, Wand: bar, Wand: text and timing, Nightfall alert", "pages")
	H.Equal(W.registeredCategory.name, "Lockeye", "Settings > AddOns entry")
end)

test("opening the window previews both frames", function()
	local W = Setup()
	Open(W)
	W.Advance(0.1)
	H.True(W.ns.modules.Wand.bar:IsVisible(), "wand bar previewed")
	H.True(W.ns.modules.Dots.frame:IsVisible(), "DoT tracker previewed")
	W.Slash("")
	W.Advance(0.1)
	H.False(W.ns.modules.Wand.bar:IsVisible(), "wand bar hidden after")
	H.False(W.ns.modules.Dots.frame:IsVisible(), "DoT tracker hidden after")
end)

test("controls change settings and the frames follow", function()
	local W = Setup()
	local window = Open(W)
	local width = window:GetControl("Wand: position", "Width")
	W.Drag(width.slider, 301.4)
	H.Equal(W.ns.modules.Wand.db.width, 301, "wand width")
	H.Equal(W.ns.modules.Wand.bar.width, 301, "bar resized")
	local threshold = window:GetControl("DoTs: what to track", "Running out below (seconds)")
	W.Type(threshold.box, "4.5")
	H.Equal(W.ns.modules.Dots.db.threshold, 4.5, "threshold")
	local immolate = window:GetControl("DoTs: what to track", "Immolate")
	immolate.dropdown:Pick("Don't show")
	H.Equal(W.ns.modules.Dots.db.slots.immolate, "off", "Immolate row off")
	local bane = window:GetControl("DoTs: what to track", "Bane (any of yours)")
	H.True(bane ~= nil, "bane row control")
end)

test("reset page puts a page's settings back", function()
	local W = Setup()
	local window = Open(W)
	local dots = W.ns.modules.Dots
	dots.db.slots.corruption = "off"
	dots.db.threshold = 7
	window:GetControl("DoTs: what to track", "Track my DoTs")
	window:ResetPage()
	H.Equal(dots.db.slots.corruption, "remind", "row mode")
	H.Equal(dots.db.threshold, 3, "threshold")
end)

test("every setting can be changed from chat", function()
	local W = Setup()
	W.Slash("width 250")
	H.Equal(W.ns.modules.Wand.db.width, 250, "wand width")
	W.Slash("dots threshold 5")
	H.Equal(W.ns.modules.Dots.db.threshold, 5, "threshold")
	W.Slash("dots curse remind")
	H.Equal(W.ns.modules.Dots.db.slots.curse, "remind", "curse row")
	W.Slash("still 0")
	H.Equal(W.ns.modules.Wand.db.stillTime, 0, "stand-still time")
	W.Slash("dots settings")
	H.True(W.Printed("threshold"), "settings listed")
	W.Slash("nonsense")
	H.True(W.Printed("Unknown command or setting 'nonsense'"), "unknown setting")
end)

test("move unlocks every frame and lock puts them back", function()
	local W = Setup()
	W.Slash("move")
	W.Advance(0.1)
	local wand, dots = W.ns.modules.Wand, W.ns.modules.Dots
	H.True(wand.bar.mover:IsShown(), "wand bar drag box")
	H.True(dots.frame.mover:IsShown(), "DoT tracker drag box")
	H.True(dots.frame:IsVisible(), "DoT tracker shown to drag")
	W.Slash("lock")
	H.False(wand.bar.mover:IsShown(), "locked")
end)

test("help lists the commands", function()
	local W = Setup()
	W.Slash("help")
	H.True(W.Printed("/lockeye test"), "test command")
	H.True(W.Printed("/lockeye dots"), "dots settings")
end)

test("saved settings survive a reload", function()
	local W = Setup()
	W.Slash("dots threshold 6")
	local saved = W.env.LockeyeDB
	local W2 = H.NewWorld({ savedVariables = saved })
	H.LoadAddon(W2, ROOT)
	H.Equal(W2.ns.modules.Dots.db.threshold, 6, "threshold kept")
end)

test("the addon compartment button opens the options or unlocks", function()
	local W = Setup()
	W.env.Lockeye_OnAddonCompartmentClick(nil, "LeftButton")
	H.True(W.ns.OptionsWindow:IsOpen(), "left click opens the options")
	W.env.Lockeye_OnAddonCompartmentClick(nil, "RightButton")
	H.False(W.ns.db.locked, "right click unlocks")
end)

return tests
