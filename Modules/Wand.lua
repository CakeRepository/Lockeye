-- The wand bar: when your next wand shot (Shoot) goes off.
--
-- How a wand fires on WoW: Forever:
--  * Shoot repeats on its own (START_AUTOREPEAT_SPELL / STOP_AUTOREPEAT_SPELL)
--    once per wand speed. Each shot fires PLAYER_SWING(swingDuration,
--    Enum.PlayerSwingType.Ranged), the event the game's own swing timer uses
--    for any ranged weapon. swingDuration stays readable in combat, while
--    UnitAttackSpeed / UnitRangedDamage turn secret there. Shoot's own cast
--    event is the fallback.
--  * The shot only goes off while you stand still and aren't casting. The bar
--    shades the end of each cycle, where you should stop moving, and turns red
--    if you move or cast there. A held-back shot is retried about every 0.5s.
--  * A cast fits between two shots if it ends before that shaded stretch. The
--    bar marks the last moment to start one, for the spell you pick (or the
--    last spell with a cast time you cast), and while you cast, where the cast
--    ends and how much it holds the shot back.
--  * If Shoot turns off (you cast something that stops it, or pressed it
--    again), the cycle still runs out: the wand is ready again when it ends.
--    In a fight, the bar then says Shoot is off.
--  * The combat log is closed to addons, so nothing here depends on it.
local _, ns = ...
local L = ns.L

local Wand = ns:NewModule("Wand", {
	position = { x = 0, y = -200 }, -- center relative to the screen center, in UI units
	width = 220,
	height = 14,
	scale = 1,
	texture = "Blizzard",
	background = { 0, 0, 0, 0.55 },
	borderSize = 1,
	borderColor = { 0, 0, 0, 1 },
	showSpark = true,
	showStillZone = true,
	stillZoneAlpha = 0.3,
	stillTime = 0.5, -- seconds at the end of the cycle you must stand still for
	latency = true, -- widen that by your world latency
	weaveSpell = "LAST", -- the cast to fit between shots (see WEAVE_SPELLS)
	showSafeWindow = true,
	showCastEnd = true,
	showClipText = true,
	font = "Default",
	fontSize = 10,
	fontOutline = "OUTLINE",
	labelPosition = "LEFT",
	timerPosition = "RIGHT",
	timerDecimals = 1,
	show = "auto", -- "auto" (shooting or the wand reloading), "combat" or "always"
	rangeCheck = true,
	warnStopped = true, -- say so when Shoot went off in a fight you were wanding in
	labels = {
		reload = L["Wand"],
		still = L["Stand still"],
		moving = L["Moving"],
		casting = L["Casting"],
		outOfRange = L["Out of range"],
		facing = L["Face your target"],
		lineOfSight = L["No line of sight"],
		idle = L["Shoot"],
		stopped = L["Shoot is off"],
	},
	colors = {
		reload = { 0.58, 0.51, 0.79 },
		still = { 0.25, 0.85, 0.30 },
		blocked = { 0.90, 0.20, 0.20 },
		idle = { 0.45, 0.45, 0.45 },
		text = { 1, 1, 1 },
		warning = { 1, 0.35, 0.35 },
		safe = { 0.35, 0.75, 1, 0.5 },
		clip = { 1, 0.25, 0.25, 0.6 },
	},
	outOfRangeAlpha = 0.5,
})
Wand.title = L["Wand bar"]

local SHOOT_SPELL_ID = 5019
local RANGED_SWING = Enum and Enum.PlayerSwingType and Enum.PlayerSwingType.Ranged or 2
local RETRY_INTERVAL = 0.5
local SAME_SHOT_WINDOW = 0.25 -- PLAYER_SWING and Shoot's cast event report the same shot
local MAX_LATENCY = 0.4
local LATENCY_POLL = 5
local RANGE_POLL = 0.2
local FALLBACK_SPEED = 1.8 -- only for drawing before the first shot is seen
local SAMPLE_SPEED = 1.6 -- the preview's and test mode's wand
local SAMPLE_CAST = 1.0
local WEAVE_POLL = 0.5
local LINE_WIDTH = 2
local MIN_CLIP_TEXT = 0.05
local LONGEST_WEAVE = 4 -- longer casts of unknown kind (summoning, Hearthstone) aren't "the last cast"
local PROBLEM_SECONDS = 1.2
-- Why a shot failed, from the game's error messages (GetGameMessageInfo names).
local SHOT_PROBLEMS = {
	ERR_BADATTACKFACING = "facing",
	SPELL_FAILED_UNIT_NOT_INFRONT = "facing",
	SPELL_FAILED_NOT_INFRONT = "facing",
	SPELL_FAILED_LINE_OF_SIGHT = "lineOfSight",
}
-- Spells with a cast time to fit between shots. "LAST" is whichever spell
-- with a cast time you cast last.
local WEAVE_SPELLS = {
	{ key = "SHADOW_BOLT", id = 686 },
	{ key = "IMMOLATE", id = 348 },
	{ key = "SEARING_PAIN", id = 5676 },
	{ key = "INCINERATE", id = 412758 },
	{ key = "SOUL_FIRE", id = 6353 },
	{ key = "CORRUPTION", id = 172 },
}

local TEXT_ANCHORS = {
	LEFT = { "LEFT", "LEFT", 4, 0, "LEFT" },
	CENTER = { "CENTER", "CENTER", 0, 0, "CENTER" },
	RIGHT = { "RIGHT", "RIGHT", -4, 0, "RIGHT" },
	ABOVE = { "BOTTOM", "TOP", 0, 3, "CENTER" },
	BELOW = { "TOP", "BOTTOM", 0, -3, "CENTER" },
}

local CHOICES = {
	textPosition = {
		{ value = "LEFT", text = L["Inside, left"] },
		{ value = "CENTER", text = L["Inside, center"] },
		{ value = "RIGHT", text = L["Inside, right"] },
		{ value = "ABOVE", text = L["Above the bar"] },
		{ value = "BELOW", text = L["Below the bar"] },
		{ value = "HIDDEN", text = L["Hidden"] },
	},
	outline = {
		{ value = "", text = L["None"] },
		{ value = "OUTLINE", text = L["Outline"] },
		{ value = "THICKOUTLINE", text = L["Thick outline"] },
	},
	decimals = {
		{ value = 0, text = "2" },
		{ value = 1, text = "1.6" },
		{ value = 2, text = "1.62" },
	},
	show = {
		{ value = "auto", text = L["While shooting or reloading"] },
		{ value = "combat", text = L["In combat"] },
		{ value = "always", text = L["Always"] },
	},
}

local function WeaveChoices()
	local list = { { value = "LAST", text = L["The last spell I cast with a cast time"] } }
	for _, spell in ipairs(WEAVE_SPELLS) do
		local name = C_Spell.GetSpellName and ns.Readable(C_Spell.GetSpellName(spell.id)) or spell.key
		list[#list + 1] = { value = spell.key, text = name }
	end
	list[#list + 1] = { value = "NONE", text = L["None"] }
	return list
end

local IsPlayerMoving, IsFalling = IsPlayerMoving, IsFalling

local state = {
	shooting = false, -- Shoot is on
	start = nil, -- GetTime() when the current cycle started (the last shot)
	duration = nil, -- its length: the wand speed at that shot
	synthetic = false, -- made up when Shoot came on with nothing to reload
	fake = false, -- made up by test mode or the options preview
	due = false, -- the client already tried to fire this cycle's shot
	retryAt = nil,
	lastSwing = nil, -- time of the last PLAYER_SWING for the ranged slot
	speed = nil, -- last known wand speed (always a plain number)
	castGUID = nil, -- set while casting or channeling anything but Shoot
	castEnds = nil, -- when that cast will end, or nil if the game won't say
	lastCast = nil, -- { name =, seconds = }: the last spell with a cast time you cast
	learned = {}, -- [spell name] = { seconds =, listedMs = }: your last real cast of it
	weaveCast = nil,
	nextWeaveCheck = 0,
	moving = false, -- event-tracked fallback if IsPlayerMoving is missing
	inRange = nil,
	nextRangeCheck = 0,
	problem = nil,
	problemUntil = 0,
	latency = 0,
	nextLatencyCheck = 0,
	wandedThisFight = false, -- you used Shoot in this fight
	test = false,
	preview = false,
}

---------------------------------------------------------------------------
-- Reading the game
---------------------------------------------------------------------------
local shootName

local function IsShoot(spellID)
	if ns.IsSecret(spellID) or spellID == nil then
		return false
	end
	if spellID == SHOOT_SPELL_ID then
		return true
	end
	shootName = shootName or (C_Spell.GetSpellName and ns.Readable(C_Spell.GetSpellName(SHOOT_SPELL_ID)))
	return shootName ~= nil and C_Spell.GetSpellName ~= nil and ns.Readable(C_Spell.GetSpellName(spellID)) == shootName
end

-- The wand's speed. Secret in combat; then the cached speed stays.
local function ReadWandSpeed()
	local _, _, ranged = UnitAttackSpeed("player")
	ranged = ns.Readable(ranged)
	if ranged and ranged > 0 then
		return ranged
	end
	local speed = ns.Readable((UnitRangedDamage("player")))
	if speed and speed > 0 then
		return speed
	end
end

local function RefreshSpeed()
	state.speed = ReadWandSpeed() or state.speed
end

local function IsMoving()
	if IsPlayerMoving then
		if IsPlayerMoving() then
			return true
		end
	elseif state.moving then
		return true
	end
	return IsFalling ~= nil and IsFalling() or false
end

local function IsBlocked()
	return state.castGUID ~= nil or IsMoving()
end

local function InCombat()
	return ns.Readable(UnitAffectingCombat("player"), false)
end

local function HostileTarget()
	return ns.Readable(UnitExists("target"), false) and ns.Readable(UnitCanAttack("player", "target"), false)
		and not ns.Readable(UnitIsDead("target"), false)
end

local function UpdateLatency(now)
	if now < state.nextLatencyCheck then
		return
	end
	state.nextLatencyCheck = now + LATENCY_POLL
	local world = GetNetStats and ns.Readable((select(4, GetNetStats())))
	state.latency = world and math.min(world / 1000, MAX_LATENCY) or 0
end

-- The stretch at the end of each cycle you must stand still for.
local function StillWindow()
	local db = Wand.db
	return db.stillTime + (db.latency and state.latency or 0)
end

local function CheckRange(now)
	if now < state.nextRangeCheck then
		return
	end
	state.nextRangeCheck = now + RANGE_POLL
	local inRange
	if Wand.db.rangeCheck then
		if C_Spell.IsSpellInRange then
			inRange = ns.Readable(C_Spell.IsSpellInRange(SHOOT_SPELL_ID, "target"))
		end
		if inRange == nil and C_SwingTimer and C_SwingTimer.IsTargetWithinSwingRange then
			inRange = ns.Readable(C_SwingTimer.IsTargetWithinSwingRange(RANGED_SWING))
		end
	end
	state.inRange = inRange
end

---------------------------------------------------------------------------
-- The cycle
---------------------------------------------------------------------------
local function StartCycle(start, duration, synthetic)
	state.start, state.duration = start, duration
	state.synthetic, state.fake, state.due = synthetic or false, false, false
	state.retryAt = nil
end

local function ClearCycle()
	state.start, state.duration = nil, nil
	state.synthetic, state.fake, state.due = false, false, false
	state.retryAt = nil
end

local function CycleActive(now)
	return state.start ~= nil and not state.due and now < state.start + state.duration
end

local function Simulating()
	return (state.test or state.preview) and not state.shooting
end

local function AdvanceSimulation(now)
	if not state.start or (now >= state.start + state.duration and not IsBlocked()) then
		StartCycle(now, state.speed or SAMPLE_SPEED)
		state.fake = true
	end
end

-- phase ("reload", "still", "blocked", "stopped" or "idle"), bar fill (0-1),
-- seconds until the shot (or nil) and the cycle length used for drawing.
local function Evaluate(now)
	if CycleActive(now) then
		local duration = state.duration
		local elapsed = now - state.start
		if elapsed < duration - StillWindow() or not (state.shooting or Simulating()) then
			-- Reloading. With Shoot off the wand still reloads; nothing to stand still for.
			return "reload", elapsed / duration, duration - elapsed, duration
		end
		return IsBlocked() and "blocked" or "still", elapsed / duration, duration - elapsed, duration
	end
	if state.shooting or Simulating() then
		-- The cycle is over but the shot hasn't gone off yet.
		local left = state.retryAt and state.retryAt > now and state.retryAt - now or nil
		return IsBlocked() and "blocked" or "still", 1, left, state.duration or state.speed
	end
	return "idle", 0, nil, state.speed
end

---------------------------------------------------------------------------
-- Casting between shots
---------------------------------------------------------------------------
local function CastTimes(channel)
	local info = channel and UnitChannelInfo or UnitCastingInfo
	if not info then
		return nil
	end
	local _, _, _, startMs, endMs, isTradeskill = info("player")
	startMs, endMs = ns.Readable(startMs), ns.Readable(endMs)
	if startMs and endMs and endMs > startMs then
		return startMs, endMs, ns.Readable(isTradeskill) == true
	end
end

-- The cast time the game lists for a spell you know (by name, so any rank), in ms.
local function ListedCastMs(name)
	local info = name and C_Spell.GetSpellInfo and ns.Readable(C_Spell.GetSpellInfo(name))
	if type(info) ~= "table" then
		return nil, false
	end
	return ns.Readable(info.castTime), true
end

-- Your last real cast of a spell, unless the listed time changed since (a
-- haste effect came or went); else the listed time.
local function CastSeconds(name)
	local listedMs, known = ListedCastMs(name)
	if not known then
		return nil
	end
	local learned = state.learned[name]
	if learned and learned.listedMs == listedMs then
		return learned.seconds
	elseif listedMs then
		return listedMs > 0 and listedMs / 1000 or nil
	end
	return learned and learned.seconds
end

local function UpdateWeave(now)
	if now < state.nextWeaveCheck then
		return
	end
	state.nextWeaveCheck = now + WEAVE_POLL
	state.weaveCast = nil
	local choice = Wand.db.weaveSpell
	if choice == "NONE" then
		return
	elseif choice == "LAST" then
		state.weaveCast = state.lastCast and state.lastCast.seconds
		return
	end
	for _, spell in ipairs(WEAVE_SPELLS) do
		if spell.key == choice then
			local name = C_Spell.GetSpellName and ns.Readable(C_Spell.GetSpellName(spell.id))
			state.weaveCast = CastSeconds(name)
		end
	end
end

local function WeaveCastTime(now)
	UpdateWeave(now)
	return state.weaveCast or (state.fake and Wand.db.weaveSpell ~= "NONE" and SAMPLE_CAST or nil)
end

local function EndCast()
	state.castGUID, state.castEnds = nil, nil
end

local function BeginCast(castGUID, spellID, channel)
	state.castGUID = ns.Readable(castGUID, true)
	state.castEnds = nil
	local name = not ns.IsSecret(spellID) and spellID and C_Spell.GetSpellName and ns.Readable(C_Spell.GetSpellName(spellID)) or nil
	local startMs, endMs, tradeskill = CastTimes(channel)
	if startMs then
		state.castEnds = endMs / 1000
		if name and not channel and not tradeskill then
			local seconds = (endMs - startMs) / 1000
			state.learned[name] = { seconds = seconds, listedMs = (ListedCastMs(name)) }
			-- Only attacks count as the cast you fit between shots.
			local harmful = C_Spell.IsSpellHarmful and ns.Readable(C_Spell.IsSpellHarmful(spellID))
			local counts = harmful or (harmful == nil and seconds <= LONGEST_WEAVE)
			if counts then
				state.lastCast = { name = name, seconds = seconds }
			end
			state.nextWeaveCheck = 0
			ns.Debug("Wand: cast", name, "takes", seconds, counts and "" or "(not an attack: not the cast to fit)")
		end
	elseif name then
		local seconds = CastSeconds(name)
		state.castEnds = seconds and GetTime() + seconds or nil
	end
end

local function MoveCastEnd(channel)
	if state.castGUID ~= nil then
		local _, endMs = CastTimes(channel)
		if endMs then
			state.castEnds = endMs / 1000
		end
	end
end

---------------------------------------------------------------------------
-- The bar
---------------------------------------------------------------------------
function Wand:CreateBar()
	local bar = CreateFrame("Frame", "LockeyeWandBar", UIParent)
	bar:SetFrameStrata("MEDIUM")
	bar:SetScript("OnUpdate", function(frame)
		ns.Guard("wand bar", function()
			local now = GetTime()
			if Simulating() then
				AdvanceSimulation(now)
			end
			if self:ShouldShow(now) then
				self:Render(now)
			else
				frame:Hide()
			end
		end)
	end)
	bar:Hide()

	bar.background = bar:CreateTexture(nil, "BACKGROUND")
	bar.background:SetAllPoints()
	bar.edges = {}
	for i = 1, 4 do
		bar.edges[i] = bar:CreateTexture(nil, "BORDER")
	end
	-- Under the fill: the stand-still stretch at the end, the stretch after a
	-- shot where a cast still fits, and the part of the stand-still stretch the
	-- cast in progress runs into.
	bar.stillZone = bar:CreateTexture(nil, "ARTWORK")
	bar.safeZone = bar:CreateTexture(nil, "ARTWORK")
	bar.clipZone = bar:CreateTexture(nil, "ARTWORK", nil, 1)

	local status = CreateFrame("StatusBar", nil, bar)
	status:SetAllPoints()
	status:SetMinMaxValues(0, 1)
	status:SetValue(0)
	bar.status = status

	bar.spark = status:CreateTexture(nil, "OVERLAY")
	bar.spark:SetColorTexture(1, 1, 1, 0.9)
	bar.spark:SetBlendMode("ADD")
	-- Over the fill: the last moment to start the cast, and where the cast in
	-- progress ends.
	bar.safeLine = status:CreateTexture(nil, "OVERLAY")
	bar.castLine = status:CreateTexture(nil, "OVERLAY")

	bar.label = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	bar.time = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	bar.clipText = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	for _, piece in ipairs({ bar.safeZone, bar.clipZone, bar.safeLine, bar.castLine, bar.clipText }) do
		piece:Hide()
	end

	ns.Frames.MakeMovable(self, bar, L["Wand bar"])
	self.bar = bar
end

function Wand:ApplyBorder()
	local bar, size, color = self.bar, self.db.borderSize, self.db.borderColor
	local top, bottom, left, right = bar.edges[1], bar.edges[2], bar.edges[3], bar.edges[4]
	for _, edge in ipairs(bar.edges) do
		edge:ClearAllPoints()
		edge:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
		edge:SetShown(size > 0)
	end
	if size <= 0 then
		return
	end
	top:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", -size, 0)
	top:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", size, 0)
	top:SetHeight(size)
	bottom:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", -size, 0)
	bottom:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", size, 0)
	bottom:SetHeight(size)
	left:SetPoint("TOPRIGHT", bar, "TOPLEFT")
	left:SetPoint("BOTTOMRIGHT", bar, "BOTTOMLEFT")
	left:SetWidth(size)
	right:SetPoint("TOPLEFT", bar, "TOPRIGHT")
	right:SetPoint("BOTTOMLEFT", bar, "BOTTOMRIGHT")
	right:SetWidth(size)
end

function Wand:ApplyText(fontString, position)
	local db = self.db
	local anchor = TEXT_ANCHORS[position]
	fontString:ClearAllPoints()
	if not anchor then
		fontString:Hide()
		return
	end
	ns.Media.ApplyFont(fontString, db.font, db.fontSize, db.fontOutline)
	local y = anchor[4]
	if position == "ABOVE" then
		y = y + db.borderSize
	elseif position == "BELOW" then
		y = y - db.borderSize
	end
	fontString:SetPoint(anchor[1], self.bar, anchor[2], anchor[3], y)
	fontString:SetJustifyH(anchor[5])
	fontString:Show()
end

function Wand:ApplyLayout()
	local db, bar = self.db, self.bar
	bar:SetSize(db.width, db.height)
	bar:SetScale(db.scale)
	local background = db.background
	bar.background:SetColorTexture(background[1], background[2], background[3], background[4] or 1)
	self:ApplyBorder()
	bar.status:SetStatusBarTexture(ns.Media.Texture(db.texture))

	local still = bar.stillZone
	still:ClearAllPoints()
	still:SetPoint("TOPRIGHT")
	still:SetPoint("BOTTOMRIGHT")
	local color = db.colors.still
	still:SetColorTexture(color[1], color[2], color[3], db.stillZoneAlpha)
	still:SetShown(db.showStillZone)
	bar.spark:SetSize(2, db.height)
	local safe, clip = db.colors.safe, db.colors.clip
	bar.safeZone:SetColorTexture(safe[1], safe[2], safe[3], safe[4] or 1)
	bar.clipZone:SetColorTexture(clip[1], clip[2], clip[3], clip[4] or 1)
	state.nextWeaveCheck = 0

	self:ApplyText(bar.label, db.labelPosition)
	self:ApplyText(bar.time, db.timerPosition)
	self.timerFormat = "%." .. db.timerDecimals .. "f"
	ns.Media.ApplyFont(bar.clipText, db.font, db.fontSize, db.fontOutline)
	bar.clipText:ClearAllPoints()
	bar.clipText:SetPoint("RIGHT", still, "LEFT", -2, 0)
	self.clipFormat = "+%." .. math.max(db.timerDecimals, 1) .. "f"

	ns.Frames.UpdateMover(bar)
	ns.Frames.ApplyPosition(self, bar)
	self:Refresh()
end

function Wand:OnUnlockChanged()
	self:ApplyLayout()
end

function Wand:ShouldShow(now)
	local db = self.db
	if state.test or state.preview or ns:IsUnlocked() or db.show == "always" then
		return true
	end
	if state.shooting or CycleActive(now) then
		return true
	end
	if db.show == "combat" and InCombat() then
		return true
	end
	return Wand:ShootIsOff()
end

-- You were wanding in this fight, Shoot is off now, and there's an enemy to shoot.
function Wand:ShootIsOff()
	return self.db.warnStopped and state.wandedThisFight and not state.shooting and InCombat() and HostileTarget()
end

-- Places a texture along the bar: centered offset pixels from the left, size long.
function Wand:PlaceAlong(texture, offset, size)
	texture:ClearAllPoints()
	texture:SetPoint("CENTER", self.bar, "LEFT", offset, 0)
	texture:SetSize(size, self.db.height)
	texture:Show()
end

-- A stretch of the cycle, from and to as fractions of it, or nothing when from is nil.
function Wand:PlaceSpan(texture, from, to)
	local length = self.db.width
	local size = from and (to - from) * length or 0
	if size < 1 then
		texture:Hide()
		return
	end
	self:PlaceAlong(texture, (from + to) / 2 * length, size)
end

function Wand:PlaceLine(line, at, color)
	if not at then
		line:Hide()
		return
	end
	local length = self.db.width
	local half = LINE_WIDTH / 2
	self:PlaceAlong(line, math.min(math.max(at * length, half), length - half), LINE_WIDTH)
	line:SetColorTexture(color[1], color[2], color[3], 1)
end

-- Not casting: where a cast started now still ends before the stand-still
-- stretch, and a line at the last safe moment. If it can't fit, the line
-- sits at the start of the bar with "+0.6", the least it will cost. Casting:
-- a line where the cast ends, the part of the stand-still stretch it runs
-- into, and how long that holds the shot back.
function Wand:RenderWeave(now, phase, duration)
	local db, bar = self.db, self.bar
	local safeTo, lineAt, lineColor, castAt, castColor, clipFrom, clipTo, delay
	if phase ~= "idle" and state.start and duration and duration > 0 then
		local reload = math.max(duration - StillWindow(), 0)
		if state.castGUID ~= nil then
			if state.castEnds then
				local ends = state.castEnds - state.start
				local over = ends - reload
				if db.showCastEnd then
					castAt = math.min(math.max(ends / duration, 0), 1)
					castColor = over > 0 and db.colors.clip or db.colors.safe
					if over > 0 then
						clipFrom, clipTo = reload / duration, math.min(ends / duration, 1)
					end
				end
				delay = db.showClipText and over or nil
			end
		elseif db.showSafeWindow then
			local cast = WeaveCastTime(now)
			if cast then
				local latest = reload - cast
				if latest >= 0 then
					safeTo, lineAt, lineColor = latest / duration, latest / duration, db.colors.safe
				else
					lineAt, lineColor = 0, db.colors.clip
					delay = db.showClipText and -latest or nil
				end
			end
		end
	end
	self:PlaceSpan(bar.safeZone, safeTo and 0, safeTo)
	self:PlaceLine(bar.safeLine, lineAt, lineColor)
	self:PlaceSpan(bar.clipZone, clipFrom, clipTo)
	self:PlaceLine(bar.castLine, castAt, castColor)
	local clipText = bar.clipText
	if delay and delay >= MIN_CLIP_TEXT then
		local clip = db.colors.clip
		clipText:SetFormattedText(self.clipFormat, delay)
		clipText:SetTextColor(clip[1], clip[2], clip[3])
		clipText:Show()
	else
		clipText:Hide()
	end
end

function Wand:GetProblem(now)
	if state.problem and now < state.problemUntil then
		return state.problem
	end
end

function Wand:Render(now)
	UpdateLatency(now)
	CheckRange(now)
	local db, bar = self.db, self.bar
	local phase, fill, left, duration = Evaluate(now)
	local outOfRange = state.inRange == false and phase ~= "idle"
	local stopped = phase == "idle" and self:ShootIsOff()

	local color = db.colors[phase]
	bar.status:SetStatusBarColor(color[1], color[2], color[3], outOfRange and db.outOfRangeAlpha or 1)
	bar.status:SetValue(fill)
	bar.stillZone:SetWidth(math.max(db.width * math.min(StillWindow() / (duration or FALLBACK_SPEED), 1), 1))

	local spark = bar.spark
	if db.showSpark and fill > 0 and fill < 1 then
		spark:ClearAllPoints()
		spark:SetPoint("CENTER", bar.status, "LEFT", db.width * fill, 0)
		spark:Show()
	else
		spark:Hide()
	end
	self:RenderWeave(now, phase, duration)

	local textColor = db.colors.text
	if bar.label:IsShown() then
		local problem = phase ~= "idle" and self:GetProblem(now)
		local key, warn = phase, false
		if problem then
			key, warn = problem, true
		elseif outOfRange then
			key, warn = "outOfRange", true
		elseif phase == "blocked" then
			key = state.castGUID and "casting" or "moving"
		elseif stopped then
			key, warn = "stopped", true
		end
		local labelColor = warn and db.colors.warning or textColor
		bar.label:SetText(db.labels[key])
		bar.label:SetTextColor(labelColor[1], labelColor[2], labelColor[3])
	end
	if bar.time:IsShown() then
		if left then
			bar.time:SetFormattedText(self.timerFormat, left)
		elseif phase == "idle" and duration then
			bar.time:SetFormattedText("%.2fs", duration)
		else
			bar.time:SetText("")
		end
		bar.time:SetTextColor(textColor[1], textColor[2], textColor[3])
	end
end

function Wand:Refresh()
	local bar = self.bar
	if not bar then
		return
	end
	local now = GetTime()
	if Simulating() and not CycleActive(now) and not state.fake then
		AdvanceSimulation(now)
	end
	if self:ShouldShow(now) then
		bar:Show()
		self:Render(now)
	else
		bar:Hide()
	end
end

local function EndSimulation()
	if not Simulating() and state.fake then
		ClearCycle()
	end
end

function Wand:SetTestMode(enabled)
	state.test = enabled
	EndSimulation()
	self:Refresh()
	if enabled then
		ns.Print(L["Test mode on: a fake wand loops. Move in the green stretch to see it turn red. /lockeye test to stop."])
	else
		ns.Print(L["Test mode off."])
	end
end

function Wand:SetPreview(enabled)
	if state.preview == enabled then
		return
	end
	state.preview = enabled
	EndSimulation()
	self:Refresh()
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------
function Wand:OnOptionChanged()
	self:ApplyLayout()
end

function Wand:GetOptionSections()
	local position = ns.Frames.PositionOptions(self)
	for _, spec in ipairs({
		{ type = "range", label = L["Width"], key = "width", min = 20, max = 800, step = 1, slash = "width" },
		{ type = "range", label = L["Height"], key = "height", min = 4, max = 80, step = 1, slash = "height" },
		{ type = "note", text = L["You can also drag the bar while Blizzard's Edit Mode is open."] },
	}) do
		position[#position + 1] = spec
	end
	return {
		{
			name = L["Wand: position"],
			keys = { "position", "width", "height", "scale" },
			controls = position,
		},
		{
			name = L["Wand: bar"],
			keys = { "texture", "background", "borderSize", "borderColor", "showSpark", "showStillZone", "stillZoneAlpha",
				"weaveSpell", "showSafeWindow", "showCastEnd", "showClipText", "colors" },
			controls = {
				{ type = "select", label = L["Texture"], key = "texture", slash = "texture",
					values = function() return ns.Media.List("statusbar") end },
				{ type = "color", label = L["Background"], key = "background", alpha = true, slash = "background" },
				{ type = "range", label = L["Border size"], key = "borderSize", min = 0, max = 6, step = 1, slash = "border" },
				{ type = "color", label = L["Border color"], key = "borderColor", alpha = true, slash = "bordercolor" },
				{ type = "toggle", label = L["Spark at the fill edge"], key = "showSpark", slash = "spark" },
				{ type = "toggle", label = L["Shade where to stand still"], key = "showStillZone", slash = "shade" },
				{ type = "range", label = L["Shading"], key = "stillZoneAlpha", min = 0, max = 1, step = 0.05, slash = "shadealpha" },
				{ type = "header", label = L["Casting between shots"] },
				{ type = "select", label = L["Cast to fit between shots"], key = "weaveSpell", values = WeaveChoices, slash = "weavespell" },
				{ type = "toggle", label = L["Show where it's safe to start it"], key = "showSafeWindow", slash = "safewindow" },
				{ type = "toggle", label = L["Show where a cast will end"], key = "showCastEnd", slash = "castend" },
				{ type = "toggle", label = L["Show how much a cast delays the shot"], key = "showClipText", slash = "clipdelay" },
				{ type = "header", label = L["Colors"] },
				{ type = "color", label = L["Reloading"], key = "colors.reload", slash = "reloadcolor" },
				{ type = "color", label = L["Stand still"], key = "colors.still", slash = "stillcolor" },
				{ type = "color", label = L["Moving or casting when it should fire"], key = "colors.blocked", slash = "blockedcolor" },
				{ type = "color", label = L["Idle"], key = "colors.idle", slash = "idlecolor" },
				{ type = "color", label = L["Safe to start the cast"], key = "colors.safe", alpha = true, slash = "safecolor" },
				{ type = "color", label = L["Cast runs into the stand-still stretch"], key = "colors.clip", alpha = true, slash = "clipcolor" },
				{ type = "color", label = L["Text"], key = "colors.text", slash = "textcolor" },
				{ type = "color", label = L["Warnings"], key = "colors.warning", slash = "warningcolor" },
			},
		},
		{
			name = L["Wand: text and timing"],
			keys = { "font", "fontSize", "fontOutline", "labelPosition", "timerPosition", "timerDecimals", "show", "stillTime",
				"latency", "rangeCheck", "warnStopped", "outOfRangeAlpha", "labels" },
			controls = {
				{ type = "select", label = L["Font"], key = "font", slash = "font",
					values = function() return ns.Media.List("font") end },
				{ type = "range", label = L["Font size"], key = "fontSize", min = 6, max = 32, step = 1, slash = "fontsize" },
				{ type = "select", label = L["Outline"], key = "fontOutline", values = CHOICES.outline, slash = "outline" },
				{ type = "select", label = L["Label"], key = "labelPosition", values = CHOICES.textPosition, slash = "label" },
				{ type = "select", label = L["Timer"], key = "timerPosition", values = CHOICES.textPosition, slash = "timer" },
				{ type = "select", label = L["Timer decimals"], key = "timerDecimals", values = CHOICES.decimals, slash = "decimals" },
				{ type = "header", label = L["Timing"] },
				{ type = "select", label = L["Show the bar"], key = "show", values = CHOICES.show, slash = "show" },
				{ type = "range", label = L["Stand still for the last (seconds)"], key = "stillTime", min = 0, max = 1.5, step = 0.05, slash = "still" },
				{ type = "toggle", label = L["Add my latency to that"], key = "latency", slash = "latency" },
				{ type = "toggle", label = L["Dim the bar when out of range"], key = "rangeCheck", slash = "rangecheck" },
				{ type = "range", label = L["Fill opacity when out of range"], key = "outOfRangeAlpha", min = 0.1, max = 1, step = 0.05, slash = "rangealpha" },
				{ type = "toggle", label = L["Say so when Shoot is off in a fight"], key = "warnStopped", slash = "warnstopped" },
				{ type = "note", text = L["If your wand fires while you move, set the stand-still time to 0."] },
			},
		},
	}
end

---------------------------------------------------------------------------
-- Module hooks
---------------------------------------------------------------------------
function Wand:OnInitialize()
	ns:RegisterCommand("test", "test", L["Loop a fake wand and fake DoTs to preview the frames."], function()
		if not self.bar then
			ns.Print(L["Lockeye only runs on warlocks."])
			return
		end
		local on = not state.test
		self:SetTestMode(on)
		for _, name in ipairs({ "Dots", "Nightfall" }) do
			local module = ns.modules[name]
			if module and module.enabled then
				module:SetTestMode(on)
			end
		end
	end)
end

function Wand:ShouldEnable()
	return ns.IsWarlock()
end

function Wand:OnEnable()
	self:CreateBar()
	if self.freshSettings then
		self.db.position.y = ns.Frames.DefaultHudY()
	end
	local events = ns.CreateEventFrame(self)
	-- PLAYER_SWING is Forever's own swing event. pcall in case a later build
	-- renames it; Shoot's cast event is the fallback.
	local ok, registered = pcall(events.RegisterEvent, events, "PLAYER_SWING")
	self.hasSwingEvent = ok and registered ~= false
	for _, event in ipairs({
		"START_AUTOREPEAT_SPELL", "STOP_AUTOREPEAT_SPELL", "PLAYER_ENTERING_WORLD", "PLAYER_DEAD",
		"PLAYER_TARGET_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
		"PLAYER_STARTED_MOVING", "PLAYER_STOPPED_MOVING", "WEAPON_SLOT_CHANGED", "UI_ERROR_MESSAGE",
	}) do
		events:RegisterEvent(event)
	end
	for _, event in ipairs({
		"UNIT_ATTACK_SPEED", "UNIT_RANGEDDAMAGE", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED_QUIET",
		"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
		"UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE",
		"UNIT_SPELLCAST_CHANNEL_STOP",
	}) do
		events:RegisterUnitEvent(event, "player")
	end
	self.events = events
	RefreshSpeed()
	self:ApplyLayout()
end

function Wand:OnSettingsReset()
	self:ApplyLayout()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
function Wand:PLAYER_SWING(duration, swingType)
	if ns.IsSecret(swingType) or swingType ~= RANGED_SWING then
		return
	end
	duration = ns.Readable(duration, state.speed)
	if not duration or duration <= 0 then
		return
	end
	local now = GetTime()
	ns.Debug("Wand: shot, speed", duration, state.lastSwing and ("| since last " .. string.format("%.2f", now - state.lastSwing)) or "")
	EndCast() -- a shot can't go off mid-cast, so any cast is over
	state.lastSwing, state.speed = now, duration
	state.problem = nil
	state.wandedThisFight = InCombat()
	StartCycle(now, duration)
	self:Refresh()
end

function Wand:AnchorFromCast(shotAt)
	local speed = ReadWandSpeed() or state.speed
	if not speed then
		return
	end
	state.speed = speed
	StartCycle(shotAt, speed)
	self:Refresh()
end

function Wand:UNIT_SPELLCAST_SUCCEEDED(_, _, spellID)
	if not IsShoot(spellID) then
		return
	end
	local shotAt = GetTime()
	if not self.hasSwingEvent then
		self:AnchorFromCast(shotAt)
		return
	end
	-- PLAYER_SWING reports the same shot with the exact speed; only use this
	-- event if it doesn't show up.
	C_Timer.After(SAME_SHOT_WINDOW, function()
		if not (state.lastSwing and math.abs(state.lastSwing - shotAt) < SAME_SHOT_WINDOW) then
			self:AnchorFromCast(shotAt)
		end
	end)
end

function Wand:UNIT_SPELLCAST_FAILED_QUIET(_, _, spellID)
	if not IsShoot(spellID) then
		return
	end
	local now = GetTime()
	if CycleActive(now) and now < state.start + state.duration - StillWindow() then
		return -- still reloading: not the client trying to fire
	end
	ns.Debug("Wand: shot held back", IsMoving() and "(moving)" or "")
	state.due = true
	state.retryAt = now + RETRY_INTERVAL
	self:Refresh()
end

function Wand:START_AUTOREPEAT_SPELL()
	state.shooting = true
	state.wandedThisFight = InCombat() or state.wandedThisFight
	local now = GetTime()
	UpdateLatency(now)
	if state.fake then
		ClearCycle()
	end
	if not CycleActive(now) then
		-- Nothing to reload: the first shot only waits for you to stand still.
		local speed = state.speed or ReadWandSpeed() or FALLBACK_SPEED
		StartCycle(now - math.max(speed - StillWindow(), 0) - 0.001, speed, true)
	end
	ns.Debug("Wand: Shoot on")
	self:Refresh()
end

function Wand:STOP_AUTOREPEAT_SPELL()
	state.shooting = false
	state.retryAt = nil
	if state.synthetic then
		ClearCycle() -- nothing was fired, so there's no reload to finish
	end
	ns.Debug("Wand: Shoot off")
	self:Refresh()
end

function Wand:UNIT_SPELLCAST_START(_, castGUID, spellID)
	if not IsShoot(spellID) then
		BeginCast(castGUID, spellID, false)
		self:Refresh()
	end
end

function Wand:UNIT_SPELLCAST_CHANNEL_START(_, castGUID, spellID)
	if not IsShoot(spellID) then
		BeginCast(castGUID, spellID, true)
		self:Refresh()
	end
end

function Wand:UNIT_SPELLCAST_DELAYED()
	MoveCastEnd(false)
end

function Wand:UNIT_SPELLCAST_CHANNEL_UPDATE()
	MoveCastEnd(true)
end

function Wand:UNIT_SPELLCAST_STOP()
	EndCast()
	self:Refresh()
end
Wand.UNIT_SPELLCAST_CHANNEL_STOP = Wand.UNIT_SPELLCAST_STOP
Wand.UNIT_SPELLCAST_INTERRUPTED = Wand.UNIT_SPELLCAST_STOP

-- Trying to cast something else mid-cast fails without ending the cast in
-- progress, so only a failure of that cast counts.
function Wand:UNIT_SPELLCAST_FAILED(_, castGUID)
	if state.castGUID == true or ns.Readable(castGUID) == state.castGUID then
		EndCast()
		self:Refresh()
	end
end

function Wand:UI_ERROR_MESSAGE(errorType)
	if ns.IsSecret(errorType) or not GetGameMessageInfo then
		return
	end
	local name = ns.Readable((GetGameMessageInfo(errorType)), "")
	if SHOT_PROBLEMS[name] and (state.shooting or CycleActive(GetTime())) then
		state.problem, state.problemUntil = SHOT_PROBLEMS[name], GetTime() + PROBLEM_SECONDS
		self:Refresh()
	end
end

function Wand:PLAYER_STARTED_MOVING()
	state.moving = true
end

function Wand:PLAYER_STOPPED_MOVING()
	state.moving = false
end

function Wand:PLAYER_TARGET_CHANGED()
	state.nextRangeCheck = 0
	self:Refresh()
end

function Wand:UNIT_ATTACK_SPEED()
	RefreshSpeed()
end
Wand.UNIT_RANGEDDAMAGE = Wand.UNIT_ATTACK_SPEED
Wand.WEAPON_SLOT_CHANGED = Wand.UNIT_ATTACK_SPEED

function Wand:PLAYER_REGEN_DISABLED()
	state.wandedThisFight = state.shooting
	self:Refresh()
end

function Wand:PLAYER_REGEN_ENABLED()
	state.wandedThisFight = false
	RefreshSpeed()
	self:Refresh()
end

function Wand:PLAYER_ENTERING_WORLD()
	state.shooting = false
	EndCast()
	ClearCycle()
	RefreshSpeed()
	self:Refresh()
end

function Wand:PLAYER_DEAD()
	state.shooting = false
	EndCast()
	ClearCycle()
	self:Refresh()
end

-- For the tests.
Wand.state = state
