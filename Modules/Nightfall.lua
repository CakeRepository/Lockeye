-- The Nightfall alert: when the Nightfall talent puts you in a Shadow Trance,
-- your next Shadow Bolt is instant. A purple bar shows above your character
-- until you cast it or the trance runs out, draining as time runs down.
--
-- How it knows (any one is enough):
--  * Shadow Bolt's cast time: while the trance is up, the game lists it as 0
--    (C_Spell.GetSpellInfo). Your own spells' cast times stay readable in
--    combat.
--  * The Shadow Trance buff itself, when the game lets addons read it (it can
--    keep your buffs' details secret in combat). This gives the exact end.
--  * Shadow Bolt's proc glow on your action bars
--    (SPELL_ACTIVATION_OVERLAY_GLOW_SHOW), if the game sends it.
-- The log notes which of them fired.
local _, ns = ...
local L = ns.L

local Nightfall = ns:NewModule("Nightfall", {
	enabled = true,
	position = { x = 0, y = 150 }, -- center relative to the screen center: above your character
	scale = 1,
	width = 200,
	height = 8,
	color = { 0.65, 0.30, 1.00 },
	showIcon = true,
	showText = true,
	pulse = true,
	sound = "NONE", -- when the trance starts
	font = "Default",
	fontSize = 12,
	learned = nil, -- seconds a Shadow Trance lasted when the game showed it
})
Nightfall.title = L["Nightfall alert"]
Nightfall.slashPrefix = "nightfall"

local SHADOW_BOLT = 686
local SHADOW_TRANCE = 17941
local TRANCE_SECONDS = 10
local POLL_SECONDS = 0.1
local CONSUMED_GRACE = 0.4 -- after an instant Shadow Bolt, the cast time can take a moment to come back
local BUFF_FILTER = "HELPFUL"

local state = {
	active = false,
	started = nil,
	ends = nil,
	duration = TRANCE_SECONDS,
	glow = false, -- Shadow Bolt's proc glow is on
	consumedAt = -math.huge,
	nextPoll = 0,
	test = false,
	preview = false,
}

local function Name(spellID)
	return C_Spell.GetSpellName and ns.Readable(C_Spell.GetSpellName(spellID)) or nil
end

local function IsShadowBolt(spellID)
	if spellID == nil or ns.IsSecret(spellID) then
		return false
	end
	local name = Name(SHADOW_BOLT)
	return spellID == SHADOW_BOLT or (name ~= nil and Name(spellID) == name)
end

-- true while Shadow Bolt is listed as instant, false when it has a cast
-- time, nil when you don't know it or the game won't say.
local function ShadowBoltInstant()
	local name = Name(SHADOW_BOLT)
	local info = name and C_Spell.GetSpellInfo and ns.Readable(C_Spell.GetSpellInfo(name))
	if type(info) ~= "table" then
		return nil
	end
	local castTime = ns.Readable(info.castTime)
	if type(castTime) ~= "number" then
		return nil
	end
	return castTime <= 0
end

-- Whether you have the Shadow Trance buff, and its end time and duration,
-- when the game shows them (nil, nil when it won't say).
local function ReadTrance()
	if InCombatLockdown() and not (C_Secrets and C_Secrets.ShouldSpellAuraBeSecret
		and ns.Readable(C_Secrets.ShouldSpellAuraBeSecret(SHADOW_TRANCE)) == false) then
		return nil -- can't tell
	end
	local aura
	if C_UnitAuras.GetPlayerAuraBySpellID then
		local ok, found = pcall(C_UnitAuras.GetPlayerAuraBySpellID, SHADOW_TRANCE)
		aura = ok and ns.Readable(found) or nil
	end
	local name = Name(SHADOW_TRANCE)
	if type(aura) ~= "table" and name and C_UnitAuras.GetAuraDataBySpellName then
		local ok, found = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", name, BUFF_FILTER)
		aura = ok and ns.Readable(found) or nil
	end
	if type(aura) ~= "table" then
		return false
	end
	local expires, duration = ns.Readable(aura.expirationTime), ns.Readable(aura.duration)
	if type(expires) == "number" and expires > 0 and type(duration) == "number" and duration > 0 then
		return true, expires, duration
	end
	return true
end

---------------------------------------------------------------------------
-- The alert
---------------------------------------------------------------------------
function Nightfall:CreateFrame()
	local frame = CreateFrame("Frame", "LockeyeNightfallFrame", UIParent)
	frame:SetFrameStrata("HIGH")
	frame:Hide()
	frame:SetScript("OnUpdate", function()
		ns.Guard("Nightfall alert", self.OnUpdate, self, GetTime())
	end)
	-- A soft purple glow around a purple line that drains as the trance runs out.
	frame.outerGlow = frame:CreateTexture(nil, "BACKGROUND")
	frame.innerGlow = frame:CreateTexture(nil, "BORDER")
	frame.outerGlow:SetBlendMode("ADD")
	frame.innerGlow:SetBlendMode("ADD")
	frame.edge = frame:CreateTexture(nil, "BORDER", nil, 1)
	frame.bar = CreateFrame("StatusBar", nil, frame)
	frame.bar:SetAllPoints()
	frame.bar:SetMinMaxValues(0, 1)
	frame.bar:SetStatusBarTexture(ns.Media.Texture("Flat"))
	frame.iconEdge = frame:CreateTexture(nil, "ARTWORK")
	frame.icon = frame:CreateTexture(nil, "ARTWORK", nil, 1)
	frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	ns.Frames.MakeMovable(self, frame, L["Nightfall"])
	self.frame = frame

	-- Watches for the trance while the alert is hidden.
	self.ticker = CreateFrame("Frame")
	self.ticker:SetScript("OnUpdate", function()
		if not frame:IsShown() then
			ns.Guard("Nightfall alert", self.OnUpdate, self, GetTime())
		end
	end)
end

function Nightfall:ApplyLayout()
	local db, frame = self.db, self.frame
	local color = db.color
	frame:SetSize(db.width, db.height)
	frame:SetScale(db.scale)
	frame.outerGlow:ClearAllPoints()
	frame.outerGlow:SetPoint("TOPLEFT", -14, 14)
	frame.outerGlow:SetPoint("BOTTOMRIGHT", 14, -14)
	frame.outerGlow:SetColorTexture(color[1], color[2], color[3], 0.15)
	frame.innerGlow:ClearAllPoints()
	frame.innerGlow:SetPoint("TOPLEFT", -5, 5)
	frame.innerGlow:SetPoint("BOTTOMRIGHT", 5, -5)
	frame.innerGlow:SetColorTexture(color[1], color[2], color[3], 0.35)
	frame.edge:ClearAllPoints()
	frame.edge:SetPoint("TOPLEFT", -1, 1)
	frame.edge:SetPoint("BOTTOMRIGHT", 1, -1)
	frame.edge:SetColorTexture(0, 0, 0, 0.8)
	frame.bar:SetStatusBarColor(color[1], color[2], color[3])

	local iconSize = math.max(db.height * 3, 20)
	frame.icon:ClearAllPoints()
	frame.icon:SetPoint("BOTTOM", frame, "TOP", 0, 8)
	frame.icon:SetSize(iconSize, iconSize)
	frame.icon:SetTexture(C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(SHADOW_BOLT) or "Interface\\Icons\\Spell_Shadow_ShadowBolt")
	frame.iconEdge:ClearAllPoints()
	frame.iconEdge:SetPoint("TOPLEFT", frame.icon, "TOPLEFT", -2, 2)
	frame.iconEdge:SetPoint("BOTTOMRIGHT", frame.icon, "BOTTOMRIGHT", 2, -2)
	frame.iconEdge:SetColorTexture(color[1], color[2], color[3], 1)
	frame.icon:SetShown(db.showIcon)
	frame.iconEdge:SetShown(db.showIcon)

	ns.Media.ApplyFont(frame.text, db.font, db.fontSize, "OUTLINE")
	frame.text:ClearAllPoints()
	frame.text:SetPoint("TOP", frame, "BOTTOM", 0, -6)
	frame.text:SetJustifyH("CENTER")
	frame.text:SetShown(db.showText)

	ns.Frames.UpdateMover(frame)
	ns.Frames.ApplyPosition(self, frame)
	self:Refresh()
end

function Nightfall:Start(now, how, ends)
	state.active, state.started = true, now
	state.ends = ends or (now + state.duration)
	ns.Debug("Nightfall: Shadow Trance, instant Shadow Bolt (seen by " .. how .. ")")
	local sound = ns.Media.Sound(self.db.sound)
	if sound then
		PlaySound(sound, "Master")
	end
end

function Nightfall:Stop(why)
	if state.active then
		ns.Debug("Nightfall: over (" .. why .. ")")
	end
	state.active, state.started, state.ends = false, nil, nil
end

-- Looks at the three signs and starts or ends the alert.
function Nightfall:Poll(now)
	if now < state.nextPoll then
		return
	end
	state.nextPoll = now + POLL_SECONDS
	if not self.db.enabled then
		self:Stop("turned off")
		return
	end
	local instant = ShadowBoltInstant()
	local buff, buffEnds, buffDuration = ReadTrance()
	if buffDuration and buffEnds and buffEnds - now <= buffDuration + 0.1 then
		state.duration = buffDuration
		if not self.db.learned or math.abs(self.db.learned - buffDuration) > 0.05 then
			self.db.learned = buffDuration
		end
	end
	local on = instant == true or buff or state.glow
	if on and now - state.consumedAt < CONSUMED_GRACE then
		on = false -- the Shadow Bolt that used it just went off
	end
	if on and not state.active then
		local how = {}
		if instant then
			how[#how + 1] = "Shadow Bolt's cast time"
		end
		if buff then
			how[#how + 1] = "the buff"
		end
		if state.glow then
			how[#how + 1] = "the proc glow"
		end
		self:Start(now, table.concat(how, ", "), buffEnds)
	elseif on and buffEnds then
		state.ends = buffEnds
	elseif not on and state.active then
		self:Stop(instant == false and "Shadow Bolt has its cast time again" or "the signs are gone")
	end
end

function Nightfall:ShouldShow()
	return state.active or state.test or state.preview or ns:IsUnlocked()
end

function Nightfall:Render(now)
	local db, frame = self.db, self.frame
	local left, duration
	if state.active then
		left, duration = math.max(state.ends - now, 0), math.max(state.ends - state.started, 0.1)
	else
		duration = TRANCE_SECONDS
		left = duration - (now % duration) -- the preview's and test mode's trance
	end
	frame.bar:SetValue(math.min(left / duration, 1))
	frame.text:SetText(L["Instant Shadow Bolt"] .. string.format("  %.1f", left))
	local color = db.color
	frame.text:SetTextColor(color[1] * 0.4 + 0.6, color[2] * 0.4 + 0.6, color[3] * 0.4 + 0.6)
	if db.pulse then
		frame:SetAlpha(0.7 + 0.3 * math.sin(now * math.pi * 3))
	else
		frame:SetAlpha(1)
	end
end

function Nightfall:OnUpdate(now)
	self:Poll(now)
	if self:ShouldShow() then
		if not self.frame:IsShown() then
			self.frame:Show()
		end
		self:Render(now)
	else
		self.frame:Hide()
	end
end

function Nightfall:Refresh()
	if self.frame then
		state.nextPoll = 0
		self:OnUpdate(GetTime())
	end
end

function Nightfall:SetTestMode(enabled)
	state.test = enabled
	self:Refresh()
end

function Nightfall:SetPreview(enabled)
	if state.preview ~= enabled then
		state.preview = enabled
		self:Refresh()
	end
end

function Nightfall:OnUnlockChanged()
	self:ApplyLayout()
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------
function Nightfall:OnOptionChanged()
	self:ApplyLayout()
end

function Nightfall:GetOptionSections()
	local controls = {
		{ type = "toggle", label = L["Show an alert when Nightfall makes Shadow Bolt instant"], key = "enabled", slash = "enabled" },
		{ type = "color", label = L["Color"], key = "color", slash = "color" },
		{ type = "toggle", label = L["Shadow Bolt icon"], key = "showIcon", slash = "icon" },
		{ type = "toggle", label = L["Text with the time left"], key = "showText", slash = "text" },
		{ type = "toggle", label = L["Pulse"], key = "pulse", slash = "pulse" },
		{ type = "select", label = L["Sound when it starts"], key = "sound", values = ns.Media.Sounds(), slash = "sound" },
		{ type = "header", label = L["Position & Size"] },
	}
	for _, spec in ipairs(ns.Frames.PositionOptions(self)) do
		controls[#controls + 1] = spec
	end
	controls[#controls + 1] = { type = "range", label = L["Width"], key = "width", min = 40, max = 600, step = 1, slash = "width" }
	controls[#controls + 1] = { type = "range", label = L["Line thickness"], key = "height", min = 2, max = 40, step = 1, slash = "height" }
	return {
		{
			name = L["Nightfall alert"],
			keys = { "enabled", "color", "showIcon", "showText", "pulse", "sound", "position", "scale", "width", "height" },
			controls = controls,
		},
	}
end

---------------------------------------------------------------------------
-- Module hooks and events
---------------------------------------------------------------------------
function Nightfall:ShouldEnable()
	return ns.IsWarlock()
end

function Nightfall:OnEnable()
	state.duration = self.db.learned or TRANCE_SECONDS
	self:CreateFrame()
	local events = ns.CreateEventFrame(self)
	for _, event in ipairs({ "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" }) do
		pcall(events.RegisterEvent, events, event) -- in case this build doesn't have them
	end
	events:RegisterEvent("PLAYER_ENTERING_WORLD")
	events:RegisterUnitEvent("UNIT_AURA", "player")
	events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
	self.events = events
	self:ApplyLayout()
end

function Nightfall:OnSettingsReset()
	self:ApplyLayout()
end

function Nightfall:SPELL_ACTIVATION_OVERLAY_GLOW_SHOW(spellID)
	if IsShadowBolt(spellID) then
		state.glow = true
		self:Refresh()
	end
end

function Nightfall:SPELL_ACTIVATION_OVERLAY_GLOW_HIDE(spellID)
	if IsShadowBolt(spellID) then
		state.glow = false
		self:Refresh()
	end
end

function Nightfall:UNIT_AURA()
	state.nextPoll = 0
end

-- An instant Shadow Bolt uses the trance up.
function Nightfall:UNIT_SPELLCAST_SUCCEEDED(_, _, spellID)
	if state.active and IsShadowBolt(spellID) then
		state.consumedAt, state.glow = GetTime(), false
		self:Stop("Shadow Bolt cast")
		self:Refresh()
	end
end

function Nightfall:PLAYER_ENTERING_WORLD()
	state.glow = false
	self:Stop("loading screen")
	self:Refresh()
end

-- For the tests.
Nightfall.state = state
