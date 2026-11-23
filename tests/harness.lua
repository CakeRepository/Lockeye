-- A small stand-in for the WoW: Forever client, just enough to load Lockeye
-- outside the game and drive it with events, clicks and a fake clock.
--
-- Each test gets its own "world": a fresh global environment, clock, frames and
-- saved variables. The environment is strict: reading a global the mock does not
-- define, or writing a global the addon is not expected to create, raises an
-- error, which catches typos in API names. Secret values (Midnight/Forever
-- combat restrictions) are tables that raise errors on arithmetic, comparison,
-- concatenation and indexing, like the real thing.
--
-- The widget mocks (regions, frames, status bars, option controls) are shared
-- with Deadeye's tests; the game world below is Lockeye's.
local H = {}

local SECRET_MT = {}
SECRET_MT.__index = function()
	error("attempt to index a secret value", 2)
end
local function secretError()
	error("attempt to compute with a secret value", 2)
end
for _, event in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__pow", "__unm", "__concat", "__lt", "__le", "__len", "__call" }) do
	SECRET_MT[event] = secretError
end

function H.Secret(value)
	local secret = setmetatable({}, SECRET_MT)
	rawset(secret, 1, value)
	return secret
end

local POINTS = {
	TOPLEFT = { 0, 1 }, TOP = { 0.5, 1 }, TOPRIGHT = { 1, 1 },
	LEFT = { 0, 0.5 }, CENTER = { 0.5, 0.5 }, RIGHT = { 1, 0.5 },
	BOTTOMLEFT = { 0, 0 }, BOTTOM = { 0.5, 0 }, BOTTOMRIGHT = { 1, 0 },
}
local LAYERS = { BACKGROUND = true, BORDER = true, ARTWORK = true, OVERLAY = true, HIGHLIGHT = true }
local STRATA = {
	BACKGROUND = true, LOW = true, MEDIUM = true, HIGH = true, DIALOG = true,
	FULLSCREEN = true, FULLSCREEN_DIALOG = true, TOOLTIP = true,
}
local SCRIPTS = {
	OnEvent = true, OnUpdate = true, OnDragStart = true, OnDragStop = true, OnShow = true,
	OnHide = true, OnEnter = true, OnLeave = true, OnMouseDown = true, OnMouseUp = true,
	OnClick = true, OnValueChanged = true, OnEnterPressed = true, OnEscapePressed = true,
	OnEditFocusLost = true, OnEditFocusGained = true, OnTextChanged = true, OnMouseWheel = true,
	PreClick = true, PostClick = true, OnAttributeChanged = true,
}
-- Font objects confirmed in the Forever client's Blizzard_Fonts_Shared.
local FONTS = {
	GameFontHighlightSmall = true, GameFontHighlightSmallOutline = true, GameFontNormalSmall = true,
	GameFontHighlight = true, GameFontNormal = true, NumberFontNormal = true,
	NumberFontNormalSmall = true, GameFontWhiteSmall = true, GameFontDisableSmall = true,
	GameFontNormalLarge = true, GameFontHighlightLarge = true, GameFontHighlightMedium = true,
}
-- Templates confirmed in the Forever client's UI source, by frame type.
local TEMPLATES = {
	Frame = { SecureHandlerStateTemplate = true },
	CheckButton = { MinimalCheckboxTemplate = true, UICheckButtonTemplate = true },
	Slider = { UISliderTemplate = true },
	EditBox = { InputBoxTemplate = true },
	Button = { UIPanelButtonTemplate = true, UIPanelCloseButton = true, SecureActionButtonTemplate = true },
	DropdownButton = { WowStyle1DropdownTemplate = true },
}
local CLICKS = {}
for _, button in ipairs({ "Any", "LeftButton", "RightButton", "MiddleButton" }) do
	CLICKS[button .. "Up"], CLICKS[button .. "Down"] = true, true
end
local FRAME_TYPES = {
	Frame = true, StatusBar = true, Button = true, CheckButton = true,
	Slider = true, EditBox = true, DropdownButton = true,
}


-- Globals the addon is expected to create, or to read before they exist.
local ADDON_GLOBALS = {
	LockeyeDB = true,
	LockeyeCharDB = true,
	SLASH_LOCKEYE1 = true,
	SLASH_LOCKEYE2 = true,
	Lockeye_OnAddonCompartmentClick = true,
	Lockeye_OnAddonCompartmentEnter = true,
	Lockeye_OnAddonCompartmentLeave = true,
}
-- Optional globals that are simply absent unless another addon provides them.
local OPTIONAL_GLOBALS = { LibStub = true }
H.addonGlobals, H.optionalGlobals = ADDON_GLOBALS, OPTIONAL_GLOBALS

local function check(condition, message)
	if not condition then
		error(message, 3)
	end
end

local function isNumber(value)
	return type(value) == "number"
end

local function isColor(r, g, b)
	return isNumber(r) and isNumber(g) and isNumber(b)
end

local function isSecret(value)
	return type(value) == "table" and getmetatable(value) == SECRET_MT
end

-- Widgets such as status bars accept secret values; addon code may only pass them on.
local function isNumberOrSecret(value)
	return isNumber(value) or isSecret(value)
end

---------------------------------------------------------------------------
-- Regions
---------------------------------------------------------------------------
local Region = {}
Region.__index = Region

function Region:SetPoint(point, a, b, c, d)
	check(POINTS[point], "SetPoint: bad point " .. tostring(point))
	local relativeTo, relativePoint, x, y
	if a == nil or isNumber(a) then
		relativeTo, relativePoint, x, y = self.parent, point, a or 0, b or 0
	else
		check(type(a) == "table", "SetPoint: relativeTo must be a region")
		relativeTo = a
		if isNumber(b) then
			relativePoint, x, y = point, b, c or 0
		else
			relativePoint, x, y = b or point, c or 0, d or 0
		end
	end
	check(POINTS[relativePoint], "SetPoint: bad relative point " .. tostring(relativePoint))
	check(isNumber(x) and isNumber(y), "SetPoint: offsets must be numbers")
	check(relativeTo ~= self, "SetPoint: a region cannot anchor to itself")
	for i, existing in ipairs(self.points) do
		if existing[1] == point then
			table.remove(self.points, i)
			break
		end
	end
	table.insert(self.points, { point, relativeTo, relativePoint, x, y })
end

function Region:GetPoint(index)
	local p = self.points[index or 1]
	if p then
		return p[1], p[2], p[3], p[4], p[5]
	end
end

function Region:ClearAllPoints()
	self.points = {}
end

function Region:SetAllPoints(relativeTo)
	self.allPoints = relativeTo or self.parent
end

function Region:SetSize(width, height)
	check(isNumber(width) and isNumber(height), "SetSize: numbers expected")
	self.width, self.height = width, height
end

function Region:SetWidth(width)
	check(isNumber(width), "SetWidth: number expected")
	self.width = width
end

function Region:SetHeight(height)
	check(isNumber(height), "SetHeight: number expected")
	self.height = height
end

function Region:GetWidth()
	return self.width or 0
end

function Region:GetHeight()
	return self.height or 0
end

function Region:GetEffectiveScale()
	local scale, region = 1, self
	while region do
		scale = scale * (region.scale or 1)
		region = region.parent
	end
	return scale
end

-- Screen rectangle in the region's own units; only single-anchor layouts are
-- resolved, which covers the frames the addon positions.
function Region:GetRect()
	if self.isUIParent then
		return 0, 0, self.width, self.height
	end
	local p = self.points[1]
	if not p or #self.points ~= 1 then
		return nil
	end
	local rl, rb, rw, rh = p[2]:GetRect()
	if not rl then
		return nil
	end
	local ratio = p[2]:GetEffectiveScale() / self:GetEffectiveScale()
	local ax = (rl + rw * POINTS[p[3]][1]) * ratio
	local ay = (rb + rh * POINTS[p[3]][2]) * ratio
	local w, h = self.width or 0, self.height or 0
	return ax + p[4] - POINTS[p[1]][1] * w, ay + p[5] - POINTS[p[1]][2] * h, w, h
end

function Region:GetCenter()
	local left, bottom, width, height = self:GetRect()
	if left then
		return left + width / 2, bottom + height / 2
	end
end

function Region:Show()
	self.shown = true
end

function Region:Hide()
	self.shown = false
end

function Region:SetShown(shown)
	if shown then
		self:Show()
	else
		self:Hide()
	end
end

function Region:IsShown()
	return self.shown
end

function Region:IsVisible()
	local region = self
	while region do
		if not region.shown then
			return false
		end
		region = region.parent
	end
	return true
end

function Region:SetAlpha(alpha)
	check(isNumber(alpha), "SetAlpha: number expected")
	self.alpha = alpha
end

function Region:GetAlpha()
	return self.alpha
end

local Texture = setmetatable({}, { __index = Region })
Texture.__index = Texture

function Texture:SetColorTexture(r, g, b, a)
	check(isColor(r, g, b), "SetColorTexture: numbers expected")
	check(a == nil or isNumber(a), "SetColorTexture: alpha must be a number")
	self.color = { r, g, b, a or 1 }
end

function Texture:SetTexture(asset)
	check(asset == nil or type(asset) == "string" or isNumber(asset) or isSecret(asset), "SetTexture: path or file id expected")
	self.texture = asset
end

function Texture:SetTexCoord(...)
	self.texCoord = { ... }
end

function Texture:SetAtlas(atlas)
	check(type(atlas) == "string", "SetAtlas: atlas name expected")
	self.atlas = atlas
	return true
end

function Texture:SetBlendMode(mode)
	check(mode == "ADD" or mode == "BLEND" or mode == "MOD" or mode == "ALPHAKEY" or mode == "DISABLE", "SetBlendMode: bad mode")
	self.blendMode = mode
end

function Texture:SetVertexColor(r, g, b, a)
	self.vertexColor = { r, g, b, a or 1 }
end

function Texture:SetDesaturated(desaturated)
	self.desaturated = not not desaturated
end

local FontString = setmetatable({}, { __index = Region })
FontString.__index = FontString

-- Text widgets show secret values as they are (addon code can't read them back).
function FontString:SetText(text)
	check(text == nil or type(text) == "string" or isNumber(text) or isSecret(text), "SetText: string expected")
	self.text = isSecret(text) and text or (text and tostring(text) or "")
end

function FontString:SetFormattedText(fmt, ...)
	self.text = string.format(fmt, ...)
end

function FontString:GetText()
	return self.text
end

function FontString:SetTextColor(r, g, b, a)
	check(isColor(r, g, b), "SetTextColor: numbers expected")
	self.textColor = { r, g, b, a or 1 }
end

function FontString:SetJustifyH(justify)
	check(justify == "LEFT" or justify == "CENTER" or justify == "RIGHT", "SetJustifyH: bad value")
	self.justifyH = justify
end

function FontString:SetFontObject(font)
	check(FONTS[font], "SetFontObject: unknown font object " .. tostring(font))
	self.fontObject = font
end

function FontString:SetFont(path, size, flags)
	check(type(path) == "string", "SetFont: path expected")
	check(isNumber(size) and size > 0, "SetFont: size expected")
	check(flags == nil or flags == "" or flags == "OUTLINE" or flags == "THICKOUTLINE", "SetFont: bad flags " .. tostring(flags))
	self.font = { path, size, flags }
	return true
end

function FontString:SetWordWrap(wrap)
	self.wordWrap = wrap
end

-- Font object sizes, for the wrapped-height estimate below.
local FONT_SIZES = { GameFontDisableSmall = 10, GameFontHighlightSmall = 10, GameFontNormalSmall = 10 }

-- The height of the text wrapped to the string's width, estimated from average
-- glyph widths: about half the font size for Latin and Cyrillic letters, the
-- full size for Korean and Chinese characters (UTF-8 lead bytes from 0xE0).
function FontString:GetStringHeight()
	local size = self.font and self.font[2] or FONT_SIZES[self.fontObject] or 12
	local perLine = self.width and self.width > 0 and self.width / size or math.huge
	local lines = 0
	for paragraph in ((self.text or "") .. "\n"):gmatch("(.-)\n") do
		local ems = 0
		for char in paragraph:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			ems = ems + (char:byte() >= 0xE0 and 1 or 0.55)
		end
		lines = lines + math.max(1, math.ceil(ems / perLine))
	end
	return lines * size * 1.25
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local Frame = setmetatable({}, { __index = Region })
Frame.__index = Frame

-- A frame is protected if it comes from a secure template, or if a protected
-- frame is its child (at any depth) or is anchored to it. In combat the client
-- blocks the protected methods below on such frames (ADDON_ACTION_BLOCKED); the
-- mock records the call in world.blocked and leaves the frame as it was.
local function IsProtected(frame)
	if frame.protected then
		return true
	end
	for _, secure in ipairs(frame.world.protectedFrames) do
		local parent = secure.parent
		while parent do
			if parent == frame then
				return true
			end
			parent = parent.parent
		end
		for _, point in ipairs(secure.points) do
			if point[2] == frame then
				return true
			end
		end
	end
	return false
end

local function Blocked(frame, method)
	if frame.world.inCombat and IsProtected(frame) then
		local blocked = frame.world.blocked
		blocked[#blocked + 1] = method .. " on " .. (frame.name or "a protected frame")
		return true
	end
	return false
end

for _, method in ipairs({ "SetPoint", "ClearAllPoints", "SetAllPoints", "SetSize", "SetWidth", "SetHeight" }) do
	local base = Region[method]
	Frame[method] = function(self, ...)
		if not Blocked(self, method) then
			return base(self, ...)
		end
	end
end

function Frame:Show()
	if Blocked(self, "Show") then
		return
	end
	local was = self.shown
	self.shown = true
	if not was and self.scripts.OnShow then
		self.scripts.OnShow(self)
	end
end

function Frame:Hide()
	if Blocked(self, "Hide") then
		return
	end
	local was = self.shown
	self.shown = false
	if was and self.scripts.OnHide then
		self.scripts.OnHide(self)
	end
end

function Frame:GetName()
	return self.name
end

function Frame:SetScript(name, handler)
	check(SCRIPTS[name], "SetScript: unknown script " .. tostring(name))
	check(handler == nil or type(handler) == "function", "SetScript: function expected")
	check(not (self.protected and name == "OnClick"), "SetScript: OnClick would replace the secure click handler")
	self.scripts[name] = handler
end

function Frame:SetAttribute(name, value)
	check(type(name) == "string", "SetAttribute: name expected")
	if not Blocked(self, "SetAttribute") then
		self.world.SetAttributeSecurely(self, name, value)
	end
end

function Frame:GetAttribute(name)
	return self.attributes[name]
end

function Frame:GetScript(name)
	return self.scripts[name]
end

function Frame:EnableMouseWheel(enable)
	self.mouseWheel = enable and true or false
end

function Frame:RegisterEvent(event)
	check(type(event) == "string", "RegisterEvent: string expected")
	if self.world.unknownEvents[event] then
		error('Attempt to register unknown event "' .. event .. '"', 2)
	end
	self.events[event] = true
	return true
end

function Frame:RegisterUnitEvent(event, unit1, unit2)
	if self.world.unknownEvents[event] then
		error('Attempt to register unknown event "' .. event .. '"', 2)
	end
	check(type(unit1) == "string", "RegisterUnitEvent: unit expected")
	self.events[event] = { [unit1] = true }
	if unit2 then
		self.events[event][unit2] = true
	end
	return true
end

function Frame:UnregisterEvent(event)
	self.events[event] = nil
end

function Frame:IsEventRegistered(event)
	return self.events[event] ~= nil
end

function Frame:CreateTexture(name, layer)
	check(layer == nil or LAYERS[layer], "CreateTexture: bad layer " .. tostring(layer))
	return setmetatable({ parent = self, shown = true, alpha = 1, points = {} }, Texture)
end

function Frame:CreateFontString(name, layer, template)
	check(layer == nil or LAYERS[layer], "CreateFontString: bad layer " .. tostring(layer))
	check(template == nil or FONTS[template], "CreateFontString: unknown font object " .. tostring(template))
	return setmetatable({ parent = self, shown = true, alpha = 1, points = {}, text = "", fontObject = template }, FontString)
end

function Frame:SetFrameStrata(strata)
	check(STRATA[strata], "SetFrameStrata: bad strata " .. tostring(strata))
	if not Blocked(self, "SetFrameStrata") then
		self.strata = strata
	end
end

function Frame:SetFrameLevel(level)
	check(isNumber(level), "SetFrameLevel: number expected")
	self.level = level
end

function Frame:GetFrameLevel()
	if self.level then
		return self.level
	end
	return self.parent and self.parent.GetFrameLevel and self.parent:GetFrameLevel() + 1 or 0
end

function Frame:SetToplevel(toplevel)
	self.toplevel = toplevel
end

function Frame:SetClampedToScreen(clamped)
	self.clamped = clamped
end

function Frame:SetMovable(movable)
	self.movable = movable
end

function Frame:SetDontSavePosition(dontSave)
	self.dontSavePosition = dontSave
end

function Frame:SetUserPlaced(userPlaced)
	self.userPlaced = userPlaced
end

function Frame:RegisterForDrag(...)
	self.dragButtons = { ... }
end

function Frame:EnableMouse(enabled)
	if not Blocked(self, "EnableMouse") then
		self.mouseEnabled = not not enabled
	end
end

function Frame:StartMoving()
	check(self.movable, "StartMoving: frame is not movable")
	self.isMoving = true
end

-- Drops the frame where the test said the player released it (world.dropPoint).
function Frame:StopMovingOrSizing()
	self.isMoving = false
	local drop = self.world.dropPoint
	if drop then
		self.points = { { drop[1], self.world.env.UIParent, drop[2], drop[3], drop[4] } }
	end
end

function Frame:SetScale(scale)
	check(isNumber(scale) and scale > 0, "SetScale: positive number expected")
	if not Blocked(self, "SetScale") then
		self.scale = scale
	end
end

function Frame:GetScale()
	return self.scale
end

local StatusBar = setmetatable({}, { __index = Frame })
StatusBar.__index = StatusBar

function StatusBar:SetStatusBarTexture(asset)
	check(type(asset) == "string" or isNumber(asset), "SetStatusBarTexture: path or file id expected")
	self.barTexture = asset
end

function StatusBar:SetMinMaxValues(min, max)
	check(isNumberOrSecret(min) and isNumberOrSecret(max), "SetMinMaxValues: numbers expected")
	self.min, self.max = min, max
end

function StatusBar:SetValue(value)
	check(isNumberOrSecret(value), "SetValue: number expected")
	if isSecret(value) or isSecret(self.min) or isSecret(self.max) then
		self.value = value -- the client clamps secrets internally; tests only check it arrived
		return
	end
	self.value = math.max(self.min or 0, math.min(self.max or 1, value))
end

function StatusBar:GetValue()
	return self.value
end

function StatusBar:SetStatusBarColor(r, g, b, a)
	check(isColor(r, g, b), "SetStatusBarColor: numbers expected")
	self.barColor = { r, g, b, a or 1 }
end

function StatusBar:SetOrientation(orientation)
	check(orientation == "HORIZONTAL" or orientation == "VERTICAL", "SetOrientation: bad value")
	self.orientation = orientation
end

function StatusBar:SetReverseFill(reverse)
	self.reverseFill = not not reverse
end

local Button = setmetatable({}, { __index = Frame })
Button.__index = Button

function Button:SetText(text)
	self.text = text
end

function Button:GetText()
	return self.text
end

function Button:SetEnabled(enabled)
	self.enabled = not not enabled
end

function Button:Enable()
	self.enabled = true
end

function Button:Disable()
	self.enabled = false
end

function Button:IsEnabled()
	return self.enabled ~= false
end

-- Lets a disabled button still show its tooltip.
function Button:SetMotionScriptsWhileDisabled(enabled)
	self.motionScriptsWhileDisabled = enabled
end

-- A click from addon code, or from a macro's /click: neither a key press nor
-- a secure mouse click, whatever the button registered for.
function Button:Click(mouseButton, down)
	if self:IsEnabled() then
		self.world.FireClick(self, mouseButton or "LeftButton", down == true)
	end
end

function Button:RegisterForClicks(...)
	self.clicks = {}
	for i = 1, select("#", ...) do
		local click = select(i, ...)
		check(CLICKS[click], "RegisterForClicks: bad click type " .. tostring(click))
		self.clicks[click] = true
	end
end

local CheckButton = setmetatable({}, { __index = Button })
CheckButton.__index = CheckButton

function CheckButton:SetChecked(checked)
	self.checked = not not checked
end

function CheckButton:GetChecked()
	return self.checked == true
end

function CheckButton:Click(mouseButton)
	self.checked = not self.checked
	Button.Click(self, mouseButton)
end

local Slider = setmetatable({}, { __index = Frame })
Slider.__index = Slider

function Slider:SetMinMaxValues(min, max)
	check(isNumber(min) and isNumber(max) and min <= max, "Slider:SetMinMaxValues: bad range")
	self.min, self.max = min, max
end

function Slider:SetValueStep(step)
	check(isNumber(step) and step > 0, "Slider:SetValueStep: positive number expected")
	self.step = step
end

function Slider:SetObeyStepOnDrag(obey)
	self.obeyStep = obey
end

function Slider:SetValue(value)
	check(isNumber(value), "Slider:SetValue: number expected")
	value = math.max(self.min or 0, math.min(self.max or 1, value))
	if value ~= self.value then
		self.value = value
		if self.scripts.OnValueChanged then
			self.scripts.OnValueChanged(self, value, false)
		end
	end
end

function Slider:GetValue()
	return self.value
end

local EditBox = setmetatable({}, { __index = Frame })
EditBox.__index = EditBox

function EditBox:SetText(text)
	check(type(text) == "string" or isNumber(text), "EditBox:SetText: string expected")
	self.text = tostring(text)
end

function EditBox:GetText()
	return self.text or ""
end

function EditBox:SetAutoFocus(autoFocus)
	self.autoFocus = autoFocus
end

function EditBox:SetJustifyH(justify)
	self.justifyH = justify
end

function EditBox:SetFontObject(font)
	check(FONTS[font], "EditBox:SetFontObject: unknown font object " .. tostring(font))
	self.fontObject = font
end

function EditBox:SetMaxLetters(letters)
	self.maxLetters = letters
end

function EditBox:SetFocus()
	if not self.focused then
		self.focused = true
		if self.scripts.OnEditFocusGained then
			self.scripts.OnEditFocusGained(self)
		end
	end
end

function EditBox:ClearFocus()
	if self.focused then
		self.focused = false
		if self.scripts.OnEditFocusLost then
			self.scripts.OnEditFocusLost(self)
		end
	end
end

function EditBox:HasFocus()
	return self.focused == true
end

-- A minimal Blizzard_Menu: SetupMenu(generator) calls generator(owner, root)
-- and the dropdown shows the selected radio's text.
local Dropdown = setmetatable({}, { __index = Frame })
Dropdown.__index = Dropdown

local function NewMenuDescription()
	local root = { items = {} }
	function root:CreateRadio(text, isSelected, setSelected, data)
		check(type(text) == "string", "CreateRadio: text expected")
		check(type(isSelected) == "function" and type(setSelected) == "function", "CreateRadio: callbacks expected")
		local item = { kind = "radio", text = text, isSelected = isSelected, setSelected = setSelected, data = data }
		self.items[#self.items + 1] = item
		return item
	end
	function root:CreateButton(text, callback, data)
		local item = { kind = "button", text = text, callback = callback, data = data }
		self.items[#self.items + 1] = item
		return item
	end
	function root:SetScrollMode(extent)
		check(isNumber(extent), "SetScrollMode: number expected")
		self.scrollExtent = extent
	end
	return root
end

function Dropdown:SetupMenu(generator)
	check(type(generator) == "function", "SetupMenu: generator expected")
	self.generator = generator
	self:GenerateMenu()
end

function Dropdown:GenerateMenu()
	local root = NewMenuDescription()
	self.generator(self, root)
	self.menu = root
	self.text = ""
	for _, item in ipairs(root.items) do
		if item.kind == "radio" and item.isSelected(item.data) then
			self.text = item.text
		end
	end
end

-- Test helper: choose the radio option with this text.
function Dropdown:Pick(text)
	for _, item in ipairs(self.menu.items) do
		if item.text == text then
			item.setSelected(item.data)
			self:GenerateMenu()
			return
		end
	end
	error("Dropdown:Pick: no option '" .. tostring(text) .. "'", 2)
end

local CLASSES = {
	Frame = Frame, StatusBar = StatusBar, Button = Button, CheckButton = CheckButton,
	Slider = Slider, EditBox = EditBox, DropdownButton = Dropdown,
}


local STDLIB = {
	"assert", "error", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset",
	"select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "unpack", "xpcall",
	"math", "string", "table",
}

---------------------------------------------------------------------------
-- World
---------------------------------------------------------------------------
-- Spell names by ID: the warlock spells Lockeye tracks (several ranks each),
-- casts that fit between wand shots, Shoot, and other debuffs of yours.
local SPELL_NAMES = {
	[172] = "Corruption", [6222] = "Corruption", [6223] = "Corruption", [25311] = "Corruption",
	[1223963] = "Corruption", -- a rank Lockeye's list doesn't have: matched by name
	[348] = "Immolate", [707] = "Immolate", [25309] = "Immolate",
	[18265] = "Siphon Life", [18881] = "Siphon Life",
	[980] = "Bane of Agony", [11713] = "Bane of Agony", [603] = "Bane of Doom", [1225228] = "Bane of Havoc",
	[702] = "Curse of Weakness", [704] = "Curse of Recklessness", [1714] = "Curse of Tongues",
	[440892] = "Curse of the Elements", [18223] = "Curse of Exhaustion", [1010] = "Curse of Idiocy",
	[5019] = "Shoot", [686] = "Shadow Bolt", [5676] = "Searing Pain", [412758] = "Incinerate", [6353] = "Soul Fire",
	[5782] = "Fear", [17794] = "Shadow Vulnerability", [1454] = "Life Tap", [6201] = "Create Healthstone",
	[689] = "Drain Life", [17941] = "Shadow Trance", [3914] = "Bolt of Woolen Cloth",
	[3110] = "Firebolt", [6307] = "Blood Pact", [2947] = "Fire Shield", [4511] = "Phase Shift",
	[3716] = "Torment", [7812] = "Sacrifice", [17767] = "Consume Shadows", [17735] = "Suffering",
	[7814] = "Lash of Pain", [6358] = "Seduction", [6360] = "Soothing Kiss", [7870] = "Lesser Invisibility",
	[19505] = "Devour Magic", [19244] = "Spell Lock", [19478] = "Tainted Blood", [19480] = "Paranoia",
}
local HELPFUL = { [1454] = true, [6201] = true }
-- Spells the player knows, by name, and their cast times in ms.
local KNOWN = {
	["Corruption"] = 2000, ["Immolate"] = 2000, ["Siphon Life"] = 0, ["Bane of Agony"] = 0, ["Bane of Doom"] = 0,
	["Curse of Weakness"] = 0, ["Curse of Tongues"] = 0, ["Shoot"] = 0, ["Shadow Bolt"] = 3000,
	["Searing Pain"] = 1500, ["Fear"] = 1500, ["Life Tap"] = 0,
}
local GAME_ERRORS = {
	[1] = "ERR_BADATTACKFACING", [2] = "SPELL_FAILED_UNIT_NOT_INFRONT", [3] = "SPELL_FAILED_LINE_OF_SIGHT",
	[4] = "SPELL_FAILED_OUT_OF_RANGE", [5] = "ERR_SPELL_COOLDOWN",
}

-- options: class, wandSpeed (false = no wand), worldLatency, savedVariables,
-- missingGlobals (set of API names left undefined), known (spell name -> cast ms)
function H.NewWorld(options)
	options = options or {}
	local wandSpeed = options.wandSpeed
	if wandSpeed == nil then
		wandSpeed = 1.6
	elseif wandSpeed == false then
		wandSpeed = nil
	end
	local W = {
		now = 1000,
		frames = {},
		timers = {},
		printed = {},
		sounds = {},
		blocked = {},
		protectedFrames = {},
		unknownEvents = options.unknownEvents or {},
		class = options.class or "WARLOCK",
		locale = options.locale or "enUS",
		wandSpeed = wandSpeed,
		worldLatency = options.worldLatency or 0,
		statsSecret = false,
		inCombat = false,
		moving = false,
		falling = false,
		inRange = nil, -- Shoot's range to the target: true, false or nil (no target)
		casting = nil, -- { spellID =, name =, startMs =, endMs =, guid = } while casting
		channeling = nil,
		known = {},
		spellNames = {},
		nextAuraID = 500, -- aura instance IDs count up across every unit, like the client's
		nextCastID = 1,
		units = {}, -- [unit token] = enemy
		plates = {}, -- nameplateN is plates[N]
		-- In combat the details of enemy debuffs are secret (the aura's spell,
		-- name and times). readableSpells: spell IDs whose debuffs stay readable.
		readableSpells = {},
		durationsSecret = nil, -- nil: duration objects are secret when the aura is
		auraIDsHidden = false, -- true: the client keeps aura IDs from addons in combat
		namesSecret = nil, -- nil: enemy names are secret in combat
		guidsSecret = false, -- true: enemy GUIDs are secret in combat too
		newIDsOnRetarget = false, -- true: an enemy's debuffs get new IDs each time you target it
		enemyCount = 0,
		comparisonSecret = nil, -- nil: UnitIsUnit is secret in combat
		playerBuffs = {}, -- [spell ID] = { duration =, expires = }: your buffs (secret in combat unless readable)
		dropPoint = nil,
	}
	for name, ms in pairs(options.known or KNOWN) do
		W.known[name] = ms
	end
	for id, name in pairs(SPELL_NAMES) do
		W.spellNames[id] = name
	end
	local env = {}
	W.env = env
	for _, name in ipairs(STDLIB) do
		env[name] = _G[name]
	end

	local function NewFrame(frameType, name, parent)
		local frame = setmetatable({
			world = W, frameType = frameType, name = name, parent = parent, shown = true,
			alpha = 1, scale = 1, points = {}, scripts = {}, events = {}, attributes = {},
		}, CLASSES[frameType])
		W.frames[#W.frames + 1] = frame
		if name then
			rawset(env, name, frame)
		end
		return frame
	end

	env.CreateFrame = function(frameType, name, parent, template)
		check(FRAME_TYPES[frameType], "CreateFrame: unsupported type " .. tostring(frameType))
		check(name == nil or type(name) == "string", "CreateFrame: name must be a string")
		for each in tostring(template or ""):gmatch("[^,%s]+") do
			check((TEMPLATES[frameType] and TEMPLATES[frameType][each]) or TEMPLATES.Frame[each],
				"CreateFrame: unknown template " .. each .. " for " .. frameType)
		end
		return NewFrame(frameType, name, parent)
	end
	env.UIParent = NewFrame("Frame", nil, nil)
	env.UIParent.isUIParent = true
	env.UIParent:SetSize(1920, 1080)

	local tooltip = NewFrame("Frame", nil, env.UIParent)
	function tooltip:SetOwner(owner)
		check(type(owner) == "table", "GameTooltip:SetOwner: owner expected")
		self.owner = owner
		self.lines = {}
	end
	function tooltip:SetText(text)
		self.lines[1] = text
	end
	function tooltip:AddLine(text)
		self.lines[#self.lines + 1] = text
	end
	tooltip:Hide()
	env.GameTooltip = tooltip
	env.SettingsPanel = NewFrame("Frame", nil, env.UIParent)
	env.SettingsPanel:Hide()
	env.HideUIPanel = function(frame)
		frame:Hide()
	end
	env.UISpecialFrames = {}

	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring((select(i, ...)))
		end
		W.printed[#W.printed + 1] = table.concat(parts, " ")
	end
	env.GetTime = function()
		return W.now
	end
	env.issecretvalue = function(value)
		return isSecret(value)
	end
	env.InCombatLockdown = function()
		return W.inCombat
	end
	env.GetLocale = function()
		return W.locale
	end
	env.C_Timer = {
		After = function(delay, callback)
			check(isNumber(delay) and type(callback) == "function", "C_Timer.After: bad arguments")
			W.timers[#W.timers + 1] = { at = W.now + delay, callback = callback }
		end,
	}

	-- The player
	local function stat(value)
		if W.statsSecret then
			return H.Secret(value)
		end
		return value
	end
	env.UnitClass = function(unit)
		check(unit == "player", "UnitClass: only the player is mocked")
		return W.class:sub(1, 1) .. W.class:sub(2):lower(), W.class, 9
	end
	env.UnitAttackSpeed = function(unit)
		check(unit == "player", "UnitAttackSpeed: only the player is mocked")
		return stat(2.0), nil, W.wandSpeed and stat(W.wandSpeed)
	end
	env.UnitRangedDamage = function(unit)
		check(unit == "player", "UnitRangedDamage: only the player is mocked")
		return stat(W.wandSpeed or 0), stat(20), stat(35), 0, 0, 1
	end
	env.IsPlayerMoving = function()
		return W.moving
	end
	env.IsFalling = function()
		return W.falling
	end
	env.GetNetStats = function()
		return 0, 0, 40, W.worldLatency
	end
	local function CastInfo(cast)
		if not cast then
			return nil
		end
		return cast.name, cast.name, 136197, cast.startMs, cast.endMs, cast.tradeskill == true, cast.guid, false, cast.spellID
	end
	env.UnitCastingInfo = function(unit)
		check(unit == "player", "UnitCastingInfo: only the player is mocked")
		return CastInfo(W.casting)
	end
	env.UnitChannelInfo = function(unit)
		check(unit == "player", "UnitChannelInfo: only the player is mocked")
		return CastInfo(W.channeling)
	end

	-- Units. An enemy is { name =, hostile =, dead =, debuffs = { aura, ... } }
	-- and an aura { id =, spellID =, name =, duration =, expires =, mine = }.
	function W.Unit(unit)
		if type(unit) ~= "string" then
			return nil
		end
		local plate = tonumber(unit:match("^nameplate(%d+)$"))
		if plate then
			return W.plates[plate]
		end
		return W.units[unit]
	end
	local function InCombatSecret(setting)
		if setting == nil then
			return W.inCombat
		end
		return setting
	end
	env.UnitExists = function(unit)
		return unit == "player" or W.Unit(unit) ~= nil
	end
	env.UnitAffectingCombat = function(unit)
		if unit == "player" then
			return W.inCombat
		end
		local enemy = W.Unit(unit)
		return enemy ~= nil and enemy.fighting == true
	end
	env.UnitGUID = function(unit)
		if unit == "player" then
			return "Player-4170-00000001"
		end
		local enemy = W.Unit(unit)
		if not enemy then
			return nil
		end
		if W.guidsSecret and W.inCombat then
			return H.Secret(enemy.guid)
		end
		return enemy.guid
	end
	-- Whether the enemy has you on its threat list (nil: it doesn't).
	env.UnitThreatSituation = function(unit, mob)
		check(unit == "player", "UnitThreatSituation: the player's threat expected")
		local enemy = W.Unit(mob)
		return enemy ~= nil and enemy.fighting == true and 1 or nil
	end
	env.UnitCanAttack = function(unit, other)
		check(unit == "player", "UnitCanAttack: only the player attacks")
		local enemy = W.Unit(other)
		return enemy ~= nil and enemy.hostile ~= false
	end
	env.UnitIsDead = function(unit)
		local enemy = W.Unit(unit)
		return enemy ~= nil and enemy.dead == true
	end
	env.UnitName = function(unit)
		local enemy = W.Unit(unit)
		local name = enemy and enemy.name or "Unknown"
		if enemy and InCombatSecret(W.namesSecret) then
			return H.Secret(name), nil
		end
		return name, nil
	end
	env.UnitIsUnit = function(a, b)
		local same = W.Unit(a) ~= nil and W.Unit(a) == W.Unit(b)
		if InCombatSecret(W.comparisonSecret) then
			return H.Secret(same)
		end
		return same
	end

	-- Auras
	local function FindAura(unit, id)
		local enemy = W.Unit(unit)
		for _, aura in ipairs(enemy and enemy.debuffs or {}) do
			if aura.id == id then
				return aura
			end
		end
	end
	local function AuraSecret(aura)
		return W.inCombat and not W.readableSpells[aura.spellID]
	end
	-- An aura of yours on enemy that lasts duration seconds from now (0: no end).
	function W.AddAura(enemy, spellID, duration, mine)
		W.nextAuraID = W.nextAuraID + 1
		local aura = {
			id = W.nextAuraID, spellID = spellID, name = W.spellNames[spellID] or "Debuff",
			duration = duration or 0, expires = duration and duration > 0 and W.now + duration or 0, mine = mine ~= false,
		}
		table.insert(enemy.debuffs, aura)
		return aura
	end
	function W.RemoveAura(enemy, aura)
		for i, each in ipairs(enemy.debuffs) do
			if each == aura then
				table.remove(enemy.debuffs, i)
				return
			end
		end
	end
	function W.RefreshAura(aura, duration)
		aura.duration = duration or aura.duration
		aura.expires = W.now + aura.duration
	end
	-- Auras that ran out disappear, as the server removes them.
	local function ExpireOn(enemy)
		for i = #enemy.debuffs, 1, -1 do
			local aura = enemy.debuffs[i]
			if aura.expires > 0 and W.now >= aura.expires then
				table.remove(enemy.debuffs, i)
			end
		end
	end
	local function Expire()
		local done = {}
		for _, list in ipairs({ W.units, W.plates }) do
			for _, enemy in pairs(list) do
				if not done[enemy] then
					done[enemy] = true
					ExpireOn(enemy)
				end
			end
		end
	end
	env.C_UnitAuras = {
		-- Aura instance IDs are plain numbers even in combat (unless a test hides
		-- them). The game sorts them by name or end time when asked, secrets or not.
		GetUnitAuraInstanceIDs = function(unit, filter, maxCount, sortRule)
			check(filter == "HARMFUL|PLAYER", "GetUnitAuraInstanceIDs: unexpected filter " .. tostring(filter))
			check(maxCount == nil, "GetUnitAuraInstanceIDs: maxCount isn't mocked")
			local ids = {}
			if W.inCombat and W.auraIDsHidden then
				return ids
			end
			local enemy = W.Unit(unit)
			local mine = {}
			for _, aura in ipairs(enemy and enemy.debuffs or {}) do
				if aura.mine then
					mine[#mine + 1] = aura
				end
			end
			if sortRule == 6 then -- NameOnly
				table.sort(mine, function(a, b)
					return a.name < b.name
				end)
			elseif sortRule == 4 then -- ExpirationOnly: soonest first, those without an end last
				table.sort(mine, function(a, b)
					local x, y = a.expires > 0 and a.expires or math.huge, b.expires > 0 and b.expires or math.huge
					return x < y
				end)
			else
				check(sortRule == nil, "GetUnitAuraInstanceIDs: unexpected sort rule " .. tostring(sortRule))
			end
			for i, aura in ipairs(mine) do
				ids[i] = aura.id
			end
			return ids
		end,
		-- Secret in combat: a table whose fields are secret values.
		GetAuraDataByAuraInstanceID = function(unit, id)
			check(isNumber(id), "GetAuraDataByAuraInstanceID: aura instance ID expected")
			local aura = FindAura(unit, id)
			if not aura then
				return nil
			end
			local function field(value)
				if AuraSecret(aura) then
					return H.Secret(value)
				end
				return value
			end
			return {
				auraInstanceID = id, spellId = field(aura.spellID), name = field(aura.name), icon = field(136197),
				duration = field(aura.duration), expirationTime = field(aura.expires), isHarmful = true,
			}
		end,
		GetAuraDuration = function(unit, id)
			check(isNumber(id), "GetAuraDuration: aura instance ID expected")
			local aura = FindAura(unit, id)
			if not aura then
				return nil
			end
			local secret = W.durationsSecret
			if secret == nil then
				secret = AuraSecret(aura)
			end
			local function value(v)
				if secret then
					return H.Secret(v)
				end
				return v
			end
			return {
				HasSecretValues = function()
					return secret
				end,
				GetRemainingDuration = function()
					return value(math.max(aura.expires - W.now, 0))
				end,
				GetTotalDuration = function()
					return value(aura.duration)
				end,
			}
		end,
	}
	env.C_Secrets = {
		ShouldUnitAuraInstanceBeSecret = function(unit, id)
			local aura = FindAura(unit, id)
			return aura ~= nil and AuraSecret(aura)
		end,
		ShouldSpellAuraBeSecret = function(spellID)
			check(isNumber(spellID), "ShouldSpellAuraBeSecret: spell ID expected")
			return W.inCombat and not W.readableSpells[spellID]
		end,
	}
	-- Your own buff, as a table whose fields are secret in combat (unless readable).
	env.C_UnitAuras.GetPlayerAuraBySpellID = function(spellID)
		check(isNumber(spellID), "GetPlayerAuraBySpellID: spell ID expected")
		local buff = W.playerBuffs[spellID]
		if not buff or (buff.expires > 0 and W.now >= buff.expires) then
			return nil
		end
		local function field(value)
			if W.inCombat and not W.readableSpells[spellID] then
				return H.Secret(value)
			end
			return value
		end
		return { spellId = field(spellID), name = field(W.spellNames[spellID]), duration = field(buff.duration),
			expirationTime = field(buff.expires) }
	end

	-- Spells
	env.C_Spell = {
		GetSpellName = function(spell)
			check(isNumber(spell), "GetSpellName: spell ID expected")
			return W.spellNames[spell]
		end,
		GetSpellTexture = function(spell)
			return W.spellNames[spell] and 100000 + spell or nil
		end,
		-- Looked up by name, it only finds spells in your spellbook.
		GetSpellInfo = function(spell)
			local name = type(spell) == "number" and W.spellNames[spell] or spell
			if not (name and W.known[name]) then
				return nil
			end
			return { name = name, castTime = W.known[name], spellID = 0, iconID = 136197, minRange = 0, maxRange = 30 }
		end,
		IsSpellHarmful = function(spell)
			check(isNumber(spell), "IsSpellHarmful: spell ID expected")
			return W.spellNames[spell] ~= nil and not HELPFUL[spell]
		end,
		IsSpellInRange = function(spell, unit)
			check(spell == 5019 and unit == "target", "IsSpellInRange: only Shoot on the target is checked")
			return W.inRange
		end,
	}
	-- The nameplate frame of a unit, with the token it shows.
	env.C_NamePlate = {
		GetNamePlateForUnit = function(unit)
			local enemy = W.Unit(unit)
			for i, plate in ipairs(W.plates) do
				if enemy and plate == enemy then
					return { unitToken = "nameplate" .. i }
				end
			end
			return nil
		end,
	}
	env.debugstack = function()
		return debug.traceback("", 2)
	end
	env.C_SwingTimer = {
		IsTargetWithinSwingRange = function(swingType)
			check(swingType == 2, "IsTargetWithinSwingRange: unexpected swing type")
			return W.inRange
		end,
	}
	env.GetGameMessageInfo = function(index)
		check(isNumber(index), "GetGameMessageInfo: index expected")
		return GAME_ERRORS[index]
	end
	env.C_AddOns = {
		GetAddOnMetadata = function(addon, field)
			if addon == "Lockeye" and field == "Version" then
				return "0.4.0"
			end
		end,
	}
	env.Enum = {
		PlayerSwingType = { MainHand = 0, OffHand = 1, Ranged = 2 },
		UnitAuraSortRule = { Unsorted = 0, Default = 1, BigDefensive = 2, Expiration = 3, ExpirationOnly = 4, Name = 5, NameOnly = 6 },
		SpellBookSpellBank = { Player = 0, Pet = 1 },
		TooltipDataType = { Item = 0 },
	}
	env.SlashCmdList = {}
	env.GameFontHighlightSmall = {
		GetFont = function()
			return "Fonts\\FRIZQT__.TTF", 10, ""
		end,
	}
	env.SOUNDKIT = {
		IG_MAINMENU_OPTION_CHECKBOX_ON = 856,
		MAP_PING = 3175,
		UI_COUNTDOWN_TIMER = 158565,
		RAID_WARNING = 8959,
		ALARM_CLOCK_WARNING_3 = 12889,
	}
	env.PlaySound = function(id, channel)
		check(isNumber(id), "PlaySound: sound kit id expected")
		W.sounds[#W.sounds + 1] = { id = id, channel = channel }
	end
	env.ColorPickerFrame = {
		SetupColorPickerAndShow = function(_, info)
			check(isColor(info.r, info.g, info.b), "SetupColorPickerAndShow: r, g, b expected")
			check(type(info.swatchFunc) == "function", "SetupColorPickerAndShow: swatchFunc expected")
			W.colorPicker = info
			W.pickerColor = { info.r, info.g, info.b, info.opacity }
		end,
		GetColorRGB = function()
			return W.pickerColor[1], W.pickerColor[2], W.pickerColor[3]
		end,
		GetColorAlpha = function()
			return W.pickerColor[4] or 1
		end,
	}
	local callbacks = {}
	env.EventRegistry = {
		RegisterCallback = function(_, event, func, owner)
			check(type(event) == "string" and type(func) == "function", "RegisterCallback: bad arguments")
			callbacks[event] = callbacks[event] or {}
			table.insert(callbacks[event], { func, owner })
		end,
		TriggerEvent = function(_, event, ...)
			for _, callback in ipairs(callbacks[event] or {}) do
				callback[1](callback[2], ...)
			end
		end,
	}
	env.Settings = {
		RegisterCanvasLayoutCategory = function(frame, name)
			check(type(frame) == "table" and type(name) == "string", "RegisterCanvasLayoutCategory: bad arguments")
			local category = { frame = frame, name = name }
			W.settingsCategory = category
			return category
		end,
		RegisterAddOnCategory = function(category)
			W.registeredCategory = category
		end,
	}
	if options.savedVariables then
		env.LockeyeDB = options.savedVariables
	end
	if options.charVariables then
		env.LockeyeCharDB = options.charVariables
	end
	env.time = function()
		return 1800000000 + math.floor(W.now)
	end
	env.date = function(format)
		return os.date(format, env.time())
	end
	env.hooksecurefunc = function(name, hook)
		local original = rawget(env, name)
		check(type(original) == "function" and type(hook) == "function", "hooksecurefunc: no function " .. tostring(name))
		rawset(env, name, function(...)
			local results = { original(...) }
			hook(...)
			return unpack(results)
		end)
	end

	-- Your demon: W.SummonDemon(family, { { name, subtext }, ... }) fills its spellbook
	-- (with a copy, so a test can change W.units.pet.spells without touching its list).
	function W.SummonDemon(family, spells)
		local book = {}
		for i, spell in ipairs(spells) do
			book[i] = { spell[1], spell[2] }
		end
		W.units.pet = { name = family, family = family, hostile = false, dead = false, debuffs = {}, spells = book }
		W.Fire("UNIT_PET", "player")
	end
	env.UnitCreatureFamily = function(unit)
		local pet = W.Unit(unit)
		return pet and pet.family
	end
	env.C_SpellBook = {
		HasPetSpells = function()
			W.petSpellbookReads = (W.petSpellbookReads or 0) + 1
			local pet = W.units.pet
			if not pet then
				return nil
			end
			return #pet.spells, "DEMON"
		end,
		GetSpellBookItemName = function(index, bank)
			check(bank == env.Enum.SpellBookSpellBank.Pet, "GetSpellBookItemName: the pet's spellbook expected")
			local spell = W.units.pet and W.units.pet.spells[index]
			if spell then
				return spell[1], spell[2]
			end
		end,
	}

	-- The vendor window: W.OpenVendor({ { id =, name = }, ... }) shows its first page.
	W.merchantItems = {}
	env.MERCHANT_ITEMS_PER_PAGE = 10
	env.MerchantFrame = NewFrame("Frame", "MerchantFrame", env.UIParent)
	env.MerchantFrame.page, env.MerchantFrame.selectedTab = 1, 1
	env.MerchantFrame:Hide()
	for i = 1, 10 do
		NewFrame("Frame", "MerchantItem" .. i, env.MerchantFrame)
		NewFrame("Button", "MerchantItem" .. i .. "ItemButton", env.MerchantFrame)
	end
	W.merchantRedraws = 0
	env.MerchantFrame_UpdateMerchantInfo = function()
		W.merchantRedraws = W.merchantRedraws + 1
	end
	env.MerchantFrame_UpdateBuybackInfo = function() end
	env.GetMerchantNumItems = function()
		return #W.merchantItems
	end
	env.C_MerchantFrame = {
		GetItemInfo = function(index)
			local item = W.merchantItems[index]
			if not item then
				return nil
			end
			return { name = item.name, price = 1000, stackCount = 1, numAvailable = -1, isPurchasable = true, isUsable = true }
		end,
	}
	function W.OpenVendor(items)
		W.merchantItems = items
		env.MerchantFrame.page, env.MerchantFrame.selectedTab = 1, 1
		env.MerchantFrame:Show()
		W.Fire("MERCHANT_SHOW")
		env.MerchantFrame_UpdateMerchantInfo()
	end
	function W.CloseVendor()
		env.MerchantFrame:Hide()
		W.Fire("MERCHANT_CLOSED")
	end

	-- Item tooltips: W.ItemTooltip(itemID) runs the tooltip post-calls and returns the lines added.
	W.itemNames = {}
	local postCalls = {}
	env.TooltipDataProcessor = {
		AddTooltipPostCall = function(kind, func)
			check(kind == env.Enum.TooltipDataType.Item and type(func) == "function", "AddTooltipPostCall: item post-call expected")
			postCalls[#postCalls + 1] = func
		end,
	}
	env.C_Item = {
		GetItemInfo = function(itemID)
			return W.itemNames[itemID]
		end,
	}
	function W.ItemTooltip(itemID)
		local lines = {}
		local tooltip = {
			AddLine = function(_, text, r, g, b)
				lines[#lines + 1] = { text = text, color = { r, g, b } }
			end,
			Show = function() end,
		}
		for _, func in ipairs(postCalls) do
			func(tooltip, { type = env.Enum.TooltipDataType.Item, id = itemID, lines = {} })
		end
		return lines
	end
	env._G = env
	for name in pairs(options.missingGlobals or {}) do
		env[name] = nil
	end

	setmetatable(env, {
		__index = function(_, key)
			if ADDON_GLOBALS[key] or OPTIONAL_GLOBALS[key] or (options.missingGlobals and options.missingGlobals[key]) then
				return nil
			end
			error("read of undefined global '" .. tostring(key) .. "'", 2)
		end,
		__newindex = function(t, key, value)
			if not ADDON_GLOBALS[key] then
				error("write to unexpected global '" .. tostring(key) .. "'", 2)
			end
			rawset(t, key, value)
		end,
	})

	function W.Fire(event, ...)
		local unit = ...
		for _, frame in ipairs(W.frames) do
			local registration = frame.events[event]
			if registration and (registration == true or registration[unit]) then
				local onEvent = frame.scripts.OnEvent
				if onEvent then
					onEvent(frame, event, ...)
				end
			end
		end
	end

	local function RunTimers()
		local i = 1
		while i <= #W.timers do
			local timer = W.timers[i]
			if timer.at <= W.now + 1e-9 then
				table.remove(W.timers, i)
				timer.callback()
			else
				i = i + 1
			end
		end
	end

	local function RunOnUpdate(elapsed)
		for _, frame in ipairs(W.frames) do
			local onUpdate = frame.scripts.OnUpdate
			if onUpdate and frame:IsVisible() then
				onUpdate(frame, elapsed)
			end
		end
	end

	-- Advances the clock in small steps: auras run out, timers and OnUpdate scripts run.
	function W.Advance(seconds, step)
		step = step or 0.02
		local target = W.now + seconds
		while W.now < target - 1e-9 do
			local delta = math.min(step, target - W.now)
			W.now = W.now + delta
			Expire()
			RunTimers()
			RunOnUpdate(delta)
		end
	end

	---------------------------------------------------------------------------
	-- Scenarios
	---------------------------------------------------------------------------
	-- fighting: it has you on its threat list (casting a spell at it does that).
	function W.Enemy(name, fields)
		W.enemyCount = W.enemyCount + 1
		local guid = string.format("Creature-0-4170-0-12-%d-00000%05d", 400 + W.enemyCount, W.enemyCount)
		local enemy = { name = name, guid = guid, hostile = true, dead = false, fighting = false, debuffs = {} }
		for key, value in pairs(fields or {}) do
			enemy[key] = value
		end
		return enemy
	end

	function W.Target(enemy)
		if enemy and W.newIDsOnRetarget then
			for _, aura in ipairs(enemy.debuffs) do
				W.nextAuraID = W.nextAuraID + 1
				aura.id = W.nextAuraID
			end
		end
		W.units.target = enemy
		W.Fire("PLAYER_TARGET_CHANGED")
	end

	function W.ShowPlates(list)
		for i = #W.plates, 1, -1 do
			W.plates[i] = nil
			W.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate" .. i)
		end
		for i, enemy in ipairs(list) do
			W.plates[i] = enemy
			W.Fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. i)
		end
	end

	function W.EnterCombat()
		W.inCombat = true
		W.Fire("PLAYER_REGEN_DISABLED")
	end

	function W.LeaveCombat()
		W.inCombat = false
		W.Fire("PLAYER_REGEN_ENABLED")
	end

	-- An instant spell of yours goes off; its debuff (if enemy is given) lands
	-- delay seconds later, as the server's aura update follows the cast.
	function W.Cast(spellID, enemy, duration, delay)
		W.nextCastID = W.nextCastID + 1
		W.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-" .. W.nextCastID, spellID)
		if not enemy then
			return nil
		end
		enemy.fighting = W.inCombat or enemy.fighting
		if delay and delay > 0 then
			W.Advance(delay)
		end
		local aura = W.AddAura(enemy, spellID, duration)
		W.Fire("UNIT_AURA", "target", {})
		return aura
	end

	-- A spell with a cast time starts (it ends with W.FinishCast).
	function W.StartCast(spellID, seconds, channel, tradeskill)
		W.nextCastID = W.nextCastID + 1
		local cast = {
			spellID = spellID, name = W.spellNames[spellID], guid = "Cast-" .. W.nextCastID,
			startMs = W.now * 1000, endMs = (W.now + seconds) * 1000, tradeskill = tradeskill,
		}
		if channel then
			W.channeling = cast
			W.Fire("UNIT_SPELLCAST_CHANNEL_START", "player", cast.guid, spellID)
		else
			W.casting = cast
			W.Fire("UNIT_SPELLCAST_START", "player", cast.guid, spellID)
		end
		return cast
	end

	function W.FinishCast()
		local cast = W.casting or W.channeling
		local channel = W.channeling ~= nil
		W.casting, W.channeling = nil, nil
		if channel then
			W.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", cast.guid, cast.spellID)
		else
			W.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", cast.guid, cast.spellID)
			W.Fire("UNIT_SPELLCAST_STOP", "player", cast.guid, cast.spellID)
		end
	end

	-- A wand shot goes off.
	function W.WandShot(speed)
		speed = speed or W.wandSpeed
		W.Fire("PLAYER_SWING", speed, 2)
		W.nextCastID = W.nextCastID + 1
		W.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-" .. W.nextCastID, 5019)
	end

	function W.Slash(input)
		W.env.SlashCmdList.LOCKEYE(input)
	end

	-- One click event: PreClick, OnClick and PostClick.
	function W.FireClick(frame, mouseButton, down)
		local scripts = frame.scripts
		for _, name in ipairs({ "PreClick", "OnClick", "PostClick" }) do
			if scripts[name] then
				scripts[name](frame, mouseButton, down)
			end
		end
	end

	function W.SetAttributeSecurely(frame, name, value)
		frame.attributes[name] = value
	end

	-- A mouse click on a button, acting on the release.
	function W.Click(frame, mouseButton)
		W.FireClick(frame, mouseButton or "LeftButton", false)
	end

	function W.Printed(pattern)
		for _, line in ipairs(W.printed) do
			if line:find(pattern, 1, true) then
				return true
			end
		end
		return false
	end

	-- A player drag on a slider (snapped to its step, as SetObeyStepOnDrag does).
	function W.Drag(slider, value)
		if slider.obeyStep and slider.step then
			value = slider.min + math.floor((value - slider.min) / slider.step + 0.5) * slider.step
		end
		slider.value = math.max(slider.min, math.min(slider.max, value))
		slider.scripts.OnValueChanged(slider, slider.value, true)
	end

	-- Typing into an edit box and pressing Enter.
	function W.Type(box, text)
		box:SetFocus()
		box:SetText(text)
		box.scripts.OnEnterPressed(box)
	end

	function W.PickColor(r, g, b, a)
		W.pickerColor = { r, g, b, a }
		W.colorPicker.swatchFunc()
		if W.colorPicker.hasOpacity then
			W.colorPicker.opacityFunc()
		end
	end

	return W
end

-- Loads the addon the way the client does: every file listed in the .toc, in
-- order, called with (addonName, namespace), then the login event sequence.
function H.LoadAddon(W, root)
	local files = {}
	for line in io.lines(root .. "/Lockeye.toc") do
		line = line:gsub("\r", "")
		if line ~= "" and not line:find("^##") then
			files[#files + 1] = line:gsub("\\", "/")
		end
	end
	local ns = { strictErrors = not W.keepErrors } -- errors stop the tests unless a test catches them
	for _, file in ipairs(files) do
		local chunk = assert(loadfile(root .. "/" .. file))
		setfenv(chunk, W.env)
		chunk("Lockeye", ns)
	end
	W.ns = ns
	W.Fire("ADDON_LOADED", "Lockeye")
	W.Fire("PLAYER_LOGIN")
	W.Fire("PLAYER_ENTERING_WORLD", true, false)
	return ns
end

---------------------------------------------------------------------------
-- Assertions
---------------------------------------------------------------------------
function H.Equal(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
	end
end

function H.Near(actual, expected, tolerance, what)
	if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
		error(string.format("%s: expected %s +/- %s, got %s", what or "value", tostring(expected), tostring(tolerance), tostring(actual)), 2)
	end
end

function H.True(value, what)
	if not value then
		error((what or "condition") .. " was not true", 2)
	end
end

function H.False(value, what)
	if value then
		error((what or "condition") .. " was not false", 2)
	end
end

function H.SameColor(actual, expected, what)
	for i = 1, 3 do
		if not actual or math.abs(actual[i] - expected[i]) > 1e-6 then
			error((what or "color") .. " does not match", 2)
		end
	end
end

return H
