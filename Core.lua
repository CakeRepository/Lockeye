-- Lockeye: a warlock toolkit for World of Warcraft: Forever.
-- Core: saved variables, the module registry, slash commands and shared helpers.
-- Features live in Modules\*.lua and register themselves with ns:NewModule().
local addonName, ns = ...

ns.name = addonName
ns.title = "|cff9482c9Lockeye|r"
ns.version = C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------
-- Every text the player sees goes through L, so translations can be added
-- later as Locales\<locale>.lua. Without one, L["text"] is the text itself.
ns.locale = GetLocale()
ns.L = setmetatable({}, {
	__index = function(_, text)
		return text
	end,
})
local L = ns.L

---------------------------------------------------------------------------
-- Secret values
---------------------------------------------------------------------------
-- Forever runs the Midnight (12.x) addon rules: in combat, many APIs (enemy
-- auras, your stats) return "secret" values that addon code may hand to
-- widgets but must not compare, branch on or do math with (doing so raises a
-- Lua error). Always check a value from such an API before using it.
local issecretvalue = issecretvalue

function ns.IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value) or false
end

-- Returns value if it is a plain, non-nil value, otherwise fallback.
-- The secrecy check must come first: even comparing a secret to nil is unsafe.
function ns.Readable(value, fallback)
	if ns.IsSecret(value) then
		return fallback
	end
	if value == nil then
		return fallback
	end
	return value
end

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------
local function Stringify(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		if ns.IsSecret(value) then
			parts[#parts + 1] = "<secret>"
		elseif type(value) == "number" and value ~= math.floor(value) then
			parts[#parts + 1] = string.format("%.3f", value)
		else
			parts[#parts + 1] = tostring(value)
		end
	end
	return table.concat(parts, " ")
end

function ns.Print(...)
	print(ns.title .. ": " .. Stringify(...))
end

---------------------------------------------------------------------------
-- The log
---------------------------------------------------------------------------
-- Lockeye keeps its last LOG_LINES debug lines in LockeyeDB.log, written to
-- disk with its settings at /reload or logout, so a problem seen in game can
-- be looked into afterwards. /lockeye log off stops it; /lockeye debug also
-- prints them to chat.
local LOG_LINES = 1500

local function Record(text)
	local db = ns.db
	if not db or db.log == false then
		return
	end
	if type(db.logLines) ~= "table" then
		db.logLines = {}
	end
	local lines = db.logLines
	lines[#lines + 1] = string.format("%.2f %s", GetTime(), text)
	if #lines > LOG_LINES * 1.2 then
		-- Keep the newest LOG_LINES.
		local keep = {}
		for i = #lines - LOG_LINES + 1, #lines do
			keep[#keep + 1] = lines[i]
		end
		db.logLines = keep
	end
end

function ns.Debug(...)
	local text = Stringify(...)
	Record(text)
	if ns.db and ns.db.debug then
		print(string.format("|cff888888[LE %.2f]|r %s", GetTime(), text))
	end
end

-- Runs fn(...) and keeps any Lua error in the log instead of breaking the
-- frame it runs in. Each different error is also said once in chat.
ns.errors = {}
local said = {}
local function Report(where, message)
	message = tostring(message)
	local stack = debugstack and debugstack(3, 4, 0) or ""
	ns.errors[#ns.errors + 1] = where .. ": " .. message
	Record("ERROR in " .. where .. ": " .. message .. " | " .. stack:gsub("\n", " | "))
	if not said[message] then
		said[message] = true
		ns.Print(L["Lockeye hit an error (it's in its log, saved at /reload): %s"]:format(message))
	end
end

function ns.Guard(where, fn, ...)
	if ns.strictErrors then
		return fn(...) -- the tests want errors to stop them
	end
	local ok, message = pcall(fn, ...)
	if not ok then
		Report(where, message)
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
-- Creates a frame that calls handler:EVENT_NAME(...) for each registered event.
function ns.CreateEventFrame(handler)
	local frame = CreateFrame("Frame")
	frame:SetScript("OnEvent", function(_, event, ...)
		local method = handler[event]
		if method then
			ns.Guard(event, method, handler, ...)
		end
	end)
	return frame
end

---------------------------------------------------------------------------
-- Modules and saved variables
---------------------------------------------------------------------------
-- A module is a plain table with optional hooks:
--   module:OnInitialize()     saved variables are ready (module.db)
--   module:ShouldEnable()     return false to stay off (e.g. wrong class)
--   module:OnEnable()         the player is logged in; create frames, register events
--   module:OnSettingsReset()  module.db was just reset to its defaults
--   module:GetOptionSections() pages for the options window (see Options\Window.lua)
--   module:SetPreview(on)     the options window opened or closed
-- module.db is the module's own table inside LockeyeDB.modules.
ns.modules = {}
local moduleOrder = {}

function ns:NewModule(name, defaults)
	local module = { name = name, defaults = defaults or {} }
	self.modules[name] = module
	moduleOrder[#moduleOrder + 1] = module
	return module
end

local function CopyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then
				target[key] = {}
			end
			CopyDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
	return target
end

function ns.CopyTable(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in pairs(value) do
		copy[key] = ns.CopyTable(inner)
	end
	return copy
end

-- Settings are addressed with dotted paths such as "colors.reload".
function ns.GetPath(tbl, path)
	for key in path:gmatch("[^%.]+") do
		if type(tbl) ~= "table" then
			return nil
		end
		tbl = tbl[key]
	end
	return tbl
end

function ns.SetPath(tbl, path, value)
	local last
	for key in path:gmatch("[^%.]+") do
		if last then
			if type(tbl[last]) ~= "table" then
				tbl[last] = {}
			end
			tbl = tbl[last]
		end
		last = key
	end
	tbl[last] = value
end

-- Replaced by the options window; modules call it after changing settings
-- outside the window (e.g. dragging a frame) so open controls stay in sync.
function ns.OptionsChanged() end

local function InitializeDB()
	if type(LockeyeDB) ~= "table" then
		LockeyeDB = {}
	end
	local db = LockeyeDB
	db.version = db.version or 1
	if db.locked == nil then
		db.locked = true -- one lock for every Lockeye frame (see Frames.lua)
	end
	if type(db.modules) ~= "table" then
		db.modules = {}
	end
	for _, module in ipairs(moduleOrder) do
		local saved = db.modules[module.name]
		module.freshSettings = type(saved) ~= "table"
		if module.freshSettings then
			saved = {}
			db.modules[module.name] = saved
		end
		module.db = CopyDefaults(saved, module.defaults)
	end
	ns.db = db
end

function ns:ResetSettings()
	LockeyeDB.modules = {}
	InitializeDB()
	for _, module in ipairs(moduleOrder) do
		if module.enabled and module.OnSettingsReset then
			module:OnSettingsReset()
		end
	end
	ns.OptionsChanged()
end

function ns.IsWarlock()
	local _, class = UnitClass("player")
	return class == "WARLOCK"
end

---------------------------------------------------------------------------
-- Slash commands: /lockeye <command> [args]
---------------------------------------------------------------------------
local commands, commandOrder = {}, {}

-- usage is what /lockeye help prints (e.g. "scale <0.5-3>"); commands without a
-- description still work but are left out of the help list.
function ns:RegisterCommand(name, usage, description, handler)
	if not commands[name] then
		commandOrder[#commandOrder + 1] = name
	end
	commands[name] = { usage = usage, description = description, handler = handler }
end

local function PrintHelp()
	ns.Print("v" .. ns.version .. " - " .. L["/lockeye (or /leye) opens the options. Commands:"])
	for _, name in ipairs(commandOrder) do
		local command = commands[name]
		if command.description then
			print(string.format("  |cffffd100/lockeye %s|r  %s", command.usage, command.description))
		end
	end
	print(string.format("  %s |cffffd100/lockeye <setting> <value>|r  %s", L["Any setting:"],
		L["for example /lockeye width 250 or /lockeye dots threshold 4"]))
end

function ns:RunCommand(input)
	local name, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	name = name:lower()
	if name == "" and ns.OptionsWindow then
		ns.OptionsWindow:Toggle()
		return
	end
	if name == "" or name == "help" then
		PrintHelp()
		return
	end
	local command = commands[name]
	if command then
		command.handler(rest)
	elseif not ns.Slash.Handle(ns.Slash.MainModule(), name, rest) then
		ns.Print(L["Unknown command or setting '%s'. Type /lockeye help or /lockeye settings."]:format(name))
	end
end

SLASH_LOCKEYE1 = "/lockeye"
SLASH_LOCKEYE2 = "/leye"
SlashCmdList.LOCKEYE = function(input)
	ns:RunCommand(input)
end

local function RegisterCoreCommands()
	local function OpenOptions()
		ns.OptionsWindow:Open()
	end
	ns:RegisterCommand("move", "move", L["Unlock every Lockeye frame to drag it; run again to lock."], function()
		ns:SetLocked(not ns.db.locked)
	end)
	ns:RegisterCommand("lock", "lock", nil, function()
		ns:SetLocked(true)
	end)
	ns:RegisterCommand("unlock", "unlock", nil, function()
		ns:SetLocked(false)
	end)
	ns:RegisterCommand("options", "options", L["Open the options window (or just type /lockeye)."], OpenOptions)
	ns:RegisterCommand("config", "config", nil, OpenOptions)
	ns:RegisterCommand("debug", "debug", L["Log wand shots and DoT tracking to chat (useful for bug reports)."], function()
		ns.db.debug = not ns.db.debug
		ns.Print(ns.db.debug and L["Debug logging on."] or L["Debug logging off."])
	end)
	ns:RegisterCommand("log", "log on|off|clear", L["Keep a log of what Lockeye sees, saved at /reload (on unless you turn it off)."], function(arg)
		arg = (arg or ""):lower()
		if arg == "clear" then
			ns.db.logLines = {}
			ns.Print(L["Log cleared."])
			return
		end
		local on = arg == "on" or (arg ~= "off" and ns.db.log == false)
		ns.db.log = on
		ns.Print(on and L["Log on: it's saved with Lockeye's settings at /reload or logout."] or L["Log off."])
	end)
	ns:RegisterCommand("reset", "reset", L["Reset all settings and frame positions."], function()
		ns:ResetSettings()
		ns.Print(L["Settings reset to defaults."])
	end)
end

---------------------------------------------------------------------------
-- Addon compartment (the addon button on the minimap)
---------------------------------------------------------------------------
function Lockeye_OnAddonCompartmentClick(_, buttonName)
	if buttonName == "RightButton" then
		ns:RunCommand("move")
	else
		ns.OptionsWindow:Toggle()
	end
end

function Lockeye_OnAddonCompartmentEnter(_, button)
	if not button then
		return
	end
	GameTooltip:SetOwner(button, "ANCHOR_LEFT")
	GameTooltip:SetText(ns.title)
	GameTooltip:AddLine(L["Left-click: options"], 1, 1, 1)
	GameTooltip:AddLine(L["Right-click: unlock or lock the frames"], 1, 1, 1)
	GameTooltip:AddLine(L["/lockeye help lists every command"], 0.7, 0.7, 0.7)
	GameTooltip:Show()
end

function Lockeye_OnAddonCompartmentLeave()
	GameTooltip:Hide()
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, loadedAddon)
	if event == "ADDON_LOADED" then
		if loadedAddon ~= addonName then
			return
		end
		self:UnregisterEvent("ADDON_LOADED")
		InitializeDB()
		for _, module in ipairs(moduleOrder) do
			if module.OnInitialize then
				module:OnInitialize()
			end
		end
		ns.Slash.RegisterCommands()
		RegisterCoreCommands()
	elseif event == "PLAYER_LOGIN" then
		self:UnregisterEvent("PLAYER_LOGIN")
		local _, class = UnitClass("player")
		ns.Debug("--- Lockeye", ns.version, "logged in:", class)
		for _, module in ipairs(moduleOrder) do
			if not module.ShouldEnable or module:ShouldEnable() then
				module.enabled = true
				if module.OnEnable then
					module:OnEnable()
				end
			end
		end
		ns.OptionsWindow:RegisterSettingsCategory()
	end
end)

function ns:GetModules()
	return moduleOrder
end
