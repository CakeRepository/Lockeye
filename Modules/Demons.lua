-- Demon abilities: what each of your demons knows, so you can tell at the
-- demon trainer which grimoires are new for it, which are upgrades and which
-- it already has, without summoning each demon to look.
--
-- A demon's abilities only show (in its spellbook) while it's summoned. So
-- every time you summon one, Lockeye notes its abilities and their ranks for
-- this character (LockeyeCharDB). At a vendor, each grimoire gets a mark on
-- its icon: Known, Upgrade, New, or ? for a demon you haven't summoned since
-- Lockeye was installed. Grimoire tooltips (at the vendor or in your bags) say
-- what your demon has, and a list of your demons sits beside the trainer's
-- window (or anywhere with /lockeye demons).
local _, ns = ...
local L = ns.L

local Demons = ns:NewModule("Demons", {
	marks = true, -- marks on the grimoires at a vendor
	tooltips = true, -- a line on grimoire tooltips
	panel = true, -- the list of your demons beside the trainer's window
})
Demons.title = L["Demon abilities"]
Demons.slashPrefix = "demons"

-- Each demon's grimoire abilities by the spell ID of their first rank (the
-- game names them in the client's language), with English names as a fallback.
local DEMONS = {
	{ key = "Imp", abilities = { { 3110, "Firebolt" }, { 6307, "Blood Pact" }, { 2947, "Fire Shield" }, { 4511, "Phase Shift" } } },
	{ key = "Voidwalker", abilities = { { 3716, "Torment" }, { 7812, "Sacrifice" }, { 17767, "Consume Shadows" }, { 17735, "Suffering" } } },
	{ key = "Succubus", abilities = { { 7814, "Lash of Pain" }, { 6358, "Seduction" }, { 6360, "Soothing Kiss" }, { 7870, "Lesser Invisibility" } } },
	{ key = "Felhunter", abilities = { { 19505, "Devour Magic" }, { 19244, "Spell Lock" }, { 19478, "Tainted Blood" }, { 19480, "Paranoia" } } },
}
local PET_BANK = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet or "pet"
local ITEM_TOOLTIP = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item or 0
local ITEMS_PER_PAGE = 10
local PANEL_WIDTH = 250

local STATUS = {
	known = { text = L["Known"], color = { 0.45, 1, 0.45 } },
	upgrade = { text = L["Upgrade"], color = { 1, 0.82, 0 } },
	new = { text = L["New"], color = { 0.45, 0.8, 1 } },
	unseen = { text = "?", color = { 0.7, 0.7, 0.7 } },
}

local charDB -- LockeyeCharDB: { demons = { [demon key] = { name =, abilities = { [ability] = rank }, seen = } } }

local function Text(value)
	value = ns.Readable(value)
	return type(value) == "string" and value ~= "" and value or nil
end

local function SpellName(id, fallback)
	return C_Spell.GetSpellName and Text(C_Spell.GetSpellName(id)) or fallback
end

-- [ability name] = demon key, from the list above and the demons you've summoned.
local function AbilityIndex()
	local index = {}
	for _, demon in ipairs(DEMONS) do
		for _, ability in ipairs(demon.abilities) do
			index[SpellName(ability[1], ability[2])] = demon.key
		end
	end
	for key, record in pairs(charDB and charDB.demons or {}) do
		for name in pairs(record.abilities) do
			index[name] = index[name] or key
		end
	end
	return index
end

local function DemonName(key)
	local record = charDB and charDB.demons[key]
	return record and record.name or key
end

---------------------------------------------------------------------------
-- Your demon's spellbook
---------------------------------------------------------------------------
-- The summoned demon's abilities: { [ability] = rank }. Commands such as
-- Attack have no rank and aren't grimoire abilities, so they're left out.
local function PetAbilities()
	local count = C_SpellBook and C_SpellBook.HasPetSpells and ns.Readable(C_SpellBook.HasPetSpells())
	if type(count) ~= "number" then
		return nil
	end
	local index, abilities = AbilityIndex(), {}
	for slot = 1, count do
		local name, sub = C_SpellBook.GetSpellBookItemName(slot, PET_BANK)
		name, sub = Text(name), Text(sub)
		local rank = sub and tonumber(sub:match("%d+"))
		if name and (rank or index[name]) then
			abilities[name] = math.max(abilities[name] or 0, rank or 1)
		end
	end
	return abilities
end

-- Which demon this is: one of the four by its abilities or English family
-- name, else by the family name the game gives it.
local function DemonKey(family, abilities)
	for _, demon in ipairs(DEMONS) do
		if demon.key == family then
			return demon.key
		end
		for _, ability in ipairs(demon.abilities) do
			if abilities[SpellName(ability[1], ability[2])] then
				return demon.key
			end
		end
	end
	return family
end

function Demons:ReadPet()
	if not (charDB and ns.Readable(UnitExists("pet"), false)) or ns.Readable(UnitIsDead("pet"), false) then
		return
	end
	local family = Text(UnitCreatureFamily("pet"))
	local abilities = PetAbilities()
	if not (family and abilities and next(abilities)) then
		return
	end
	local key = DemonKey(family, abilities)
	local record = charDB.demons[key] or { abilities = {} }
	local changed = record.name ~= family
	for name, rank in pairs(abilities) do
		if record.abilities[name] ~= rank then
			changed = true
		end
	end
	for name in pairs(record.abilities) do
		if not abilities[name] then
			changed = true
		end
	end
	record.name, record.abilities, record.seen = family, abilities, time()
	charDB.demons[key] = record
	if changed then
		local list = {}
		for name, rank in pairs(abilities) do
			list[#list + 1] = name .. " " .. rank
		end
		table.sort(list)
		ns.Debug("Demons:", family, "knows", table.concat(list, ", "))
		self:Refresh()
	end
end

---------------------------------------------------------------------------
-- Grimoires
---------------------------------------------------------------------------
-- A grimoire by its item name: the demon ability it teaches (the longest known
-- ability name in it, so "Fire Shield" wins over a shorter one), its rank
-- ("(Rank 4)", else 1) and its demon. Nil for other items.
function Demons:Grimoire(name)
	name = Text(name)
	if not name then
		return nil
	end
	local rank = tonumber(name:match("%(%D*(%d+)%)%s*$") or "")
	if not (rank or name:find(L["Grimoire"], 1, true)) then
		return nil
	end
	local best, demon
	for ability, key in pairs(AbilityIndex()) do
		if name:find(ability, 1, true) and (not best or #ability > #best) then
			best, demon = ability, key
		end
	end
	if not best then
		return nil
	end
	return { ability = best, rank = rank or 1, demon = demon }
end

-- "known", "upgrade", "new" or "unseen", and the rank your demon has.
function Demons:Status(grimoire)
	local record = charDB and charDB.demons[grimoire.demon]
	if not record then
		return "unseen"
	end
	local have = record.abilities[grimoire.ability]
	if not have then
		return "new"
	elseif have >= grimoire.rank then
		return "known", have
	end
	return "upgrade", have
end

function Demons:Describe(grimoire)
	local status, have = self:Status(grimoire)
	local demon = DemonName(grimoire.demon)
	if status == "known" then
		return status, L["Your %s knows %s (Rank %d)."]:format(demon, grimoire.ability, have)
	elseif status == "upgrade" then
		return status, L["Upgrade: your %s has %s (Rank %d)."]:format(demon, grimoire.ability, have)
	elseif status == "new" then
		return status, L["New: your %s doesn't know %s yet."]:format(demon, grimoire.ability)
	end
	return status, L["Summon your %s once so Lockeye can see what it knows."]:format(demon)
end

---------------------------------------------------------------------------
-- The vendor
---------------------------------------------------------------------------
local function MerchantName(index)
	local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo and C_MerchantFrame.GetItemInfo(index)
	return type(info) == "table" and Text(info.name) or nil
end

-- Whether this vendor sells any grimoire.
function Demons:SellsGrimoires()
	for index = 1, ns.Readable(GetMerchantNumItems(), 0) do
		if self:Grimoire(MerchantName(index)) then
			return true
		end
	end
	return false
end

local function Badge(button)
	if not button.lockeyeBadge then
		local badge = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
		badge:SetPoint("BOTTOM", button, "BOTTOM", 0, 2)
		badge:SetJustifyH("CENTER")
		button.lockeyeBadge = badge
	end
	return button.lockeyeBadge
end

-- Marks the grimoires on the vendor's current page.
function Demons:UpdateMarks()
	if not MerchantFrame then
		return
	end
	local buyback = MerchantFrame.selectedTab == 2
	local page = ns.Readable(MerchantFrame.page, 1)
	for i = 1, ITEMS_PER_PAGE do
		local button = _G["MerchantItem" .. i .. "ItemButton"]
		if button then
			local grimoire = self.db.marks and not buyback and self:Grimoire(MerchantName((page - 1) * ITEMS_PER_PAGE + i))
			if grimoire then
				local style = STATUS[(self:Status(grimoire))]
				local badge = Badge(button)
				badge:SetText(style.text)
				badge:SetTextColor(style.color[1], style.color[2], style.color[3])
				badge:Show()
			elseif button.lockeyeBadge then
				button.lockeyeBadge:Hide()
			end
		end
	end
end

---------------------------------------------------------------------------
-- The list of your demons
---------------------------------------------------------------------------
local function Hex(color)
	return string.format("%02x%02x%02x", color[1] * 255, color[2] * 255, color[3] * 255)
end

-- One line per demon, then its abilities: rank, or "no" in gray when it
-- doesn't have one; "not summoned yet" for demons you haven't summoned.
function Demons:PanelLines()
	local lines, listed = {}, {}
	local function Add(key, abilities)
		listed[key] = true
		local record = charDB and charDB.demons[key]
		if not record then
			lines[#lines + 1] = { demon = key, text = "|cff999999" .. L["not summoned yet"] .. "|r" }
			return
		end
		local parts = {}
		for _, ability in ipairs(abilities) do
			local have = record.abilities[ability]
			if have then
				parts[#parts + 1] = ability .. " " .. have
			else
				parts[#parts + 1] = "|cff999999" .. ability .. " " .. L["no"] .. "|r"
			end
		end
		for ability, have in pairs(record.abilities) do
			local known = false
			for _, name in ipairs(abilities) do
				known = known or name == ability
			end
			if not known then
				parts[#parts + 1] = ability .. " " .. have
			end
		end
		lines[#lines + 1] = { demon = record.name or key, text = table.concat(parts, ", ") }
	end
	for _, demon in ipairs(DEMONS) do
		local names = {}
		for _, ability in ipairs(demon.abilities) do
			names[#names + 1] = SpellName(ability[1], ability[2])
		end
		Add(demon.key, names)
	end
	local others = {}
	for key in pairs(charDB and charDB.demons or {}) do
		if not listed[key] then
			others[#others + 1] = key
		end
	end
	table.sort(others)
	for _, key in ipairs(others) do
		Add(key, {})
	end
	return lines
end

function Demons:CreatePanel()
	local panel = CreateFrame("Frame", "LockeyeDemonsPanel", UIParent)
	panel:SetSize(PANEL_WIDTH, 60)
	panel:SetFrameStrata("HIGH")
	panel:SetClampedToScreen(true)
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
	panel:Hide()
	local background = panel:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(0.05, 0.04, 0.08, 0.92)
	local edge = panel:CreateTexture(nil, "BORDER")
	edge:SetPoint("TOPLEFT")
	edge:SetPoint("TOPRIGHT")
	edge:SetHeight(2)
	edge:SetColorTexture(0.58, 0.51, 0.79, 1)
	panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	panel.title:SetPoint("TOPLEFT", 10, -10)
	panel.title:SetText(L["Your demons"])
	local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)
	close:SetScript("OnClick", function()
		panel:Hide()
		self.dismissed = panel.atVendor -- closed at the vendor: stay closed until the next visit
	end)
	panel.lines = {}
	self.panel = panel
end

function Demons:RenderPanel()
	local panel = self.panel
	local y = 30
	local lines = self:PanelLines()
	for i, line in ipairs(lines) do
		local row = panel.lines[i]
		if not row then
			row = {
				demon = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight"),
				text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
			}
			row.text:SetJustifyH("LEFT")
			row.text:SetWordWrap(true)
			row.text:SetWidth(PANEL_WIDTH - 24)
			panel.lines[i] = row
		end
		row.demon:ClearAllPoints()
		row.demon:SetPoint("TOPLEFT", 10, -y)
		row.demon:SetText(line.demon)
		row.demon:Show()
		row.text:ClearAllPoints()
		row.text:SetPoint("TOPLEFT", 16, -(y + 15))
		row.text:SetText(line.text)
		row.text:Show()
		y = y + 15 + math.max(math.ceil(row.text:GetStringHeight()), 12) + 8
	end
	for i = #lines + 1, #panel.lines do
		panel.lines[i].demon:Hide()
		panel.lines[i].text:Hide()
	end
	panel:SetHeight(y + 4)
end

-- Beside the trainer's window, while it sells grimoires.
function Demons:ShowAtVendor()
	if self.dismissed or (self.panel:IsShown() and self.panel.atVendor)
		or not (self.db.panel and MerchantFrame and self:SellsGrimoires()) then
		return
	end
	local panel = self.panel
	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 4, 0)
	panel.atVendor = true
	self:RenderPanel()
	panel:Show()
end

function Demons:TogglePanel()
	local panel = self.panel
	if panel:IsShown() then
		panel:Hide()
		return
	end
	panel:ClearAllPoints()
	panel:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
	panel.atVendor = false
	self:RenderPanel()
	panel:Show()
end

function Demons:Refresh()
	if self.panel and self.panel:IsShown() then
		self:RenderPanel()
	end
	if self.vendorOpen then
		self:UpdateMarks()
	end
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------
function Demons:OnItemTooltip(tooltip, data)
	if not (self.db.tooltips and type(data) == "table") then
		return
	end
	local itemID = ns.Readable(data.id)
	local name = itemID and C_Item and C_Item.GetItemInfo and Text((C_Item.GetItemInfo(itemID)))
	if not name and type(data.lines) == "table" and type(data.lines[1]) == "table" then
		name = Text(data.lines[1].leftText)
	end
	local grimoire = self:Grimoire(name)
	if not grimoire then
		return
	end
	local status, text = self:Describe(grimoire)
	local color = STATUS[status].color
	tooltip:AddLine("|cff" .. Hex({ 0.58, 0.51, 0.79 }) .. "Lockeye:|r " .. text, color[1], color[2], color[3], true)
	tooltip:Show()
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------
function Demons:OnOptionChanged()
	self:Refresh()
end

function Demons:GetOptionSections()
	return {
		{
			name = L["Demon abilities"],
			keys = { "marks", "tooltips", "panel" },
			controls = {
				{ type = "toggle", label = L["Mark grimoires at the demon trainer"], key = "marks", slash = "marks" },
				{ type = "toggle", label = L["Say what my demon has on grimoire tooltips"], key = "tooltips", slash = "tooltips" },
				{ type = "toggle", label = L["List my demons beside the trainer's window"], key = "panel", slash = "panel" },
				{ type = "button", label = L["Show what my demons know"], slash = "show", func = function()
					self:TogglePanel()
				end },
				{ type = "note", text = L["A demon's abilities only show while it's summoned, so Lockeye notes them each time you summon one. Summon each demon once to fill the list in."] },
			},
		},
	}
end

---------------------------------------------------------------------------
-- Module hooks and events
---------------------------------------------------------------------------
function Demons:OnInitialize()
	if type(LockeyeCharDB) ~= "table" then
		LockeyeCharDB = {}
	end
	if type(LockeyeCharDB.demons) ~= "table" then
		LockeyeCharDB.demons = {}
	end
	charDB = LockeyeCharDB
end

function Demons:ShouldEnable()
	return ns.IsWarlock()
end

function Demons:OnEnable()
	self:CreatePanel()
	local events = ns.CreateEventFrame(self)
	for _, event in ipairs({ "PET_BAR_UPDATE", "SPELLS_CHANGED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "PLAYER_ENTERING_WORLD" }) do
		events:RegisterEvent(event)
	end
	events:RegisterUnitEvent("UNIT_PET", "player")
	self.events = events
	-- The vendor's pages and its Buyback tab redraw the items: mark them again after.
	for _, name in ipairs({ "MerchantFrame_UpdateMerchantInfo", "MerchantFrame_UpdateBuybackInfo" }) do
		if type(_G[name]) == "function" then
			hooksecurefunc(name, function()
				if self.vendorOpen then
					-- Item names can arrive after the window opens: look again.
					ns.Guard("demon trainer marks", self.UpdateMarks, self)
					ns.Guard("demon trainer list", self.ShowAtVendor, self)
				end
			end)
		end
	end
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
		TooltipDataProcessor.AddTooltipPostCall(ITEM_TOOLTIP, function(tooltip, data)
			ns.Guard("grimoire tooltip", self.OnItemTooltip, self, tooltip, data)
		end)
	end
	ns:RegisterCommand("demons", "demons", L["Show what your demons know (summon each once to fill it in)."], function(text)
		local name = (text or ""):match("^%s*(%S*)"):lower()
		if name == "" then
			self:TogglePanel()
		elseif name == "settings" or name == "list" then
			ns.Slash.List(self)
		elseif not ns.Slash.Handle(self, name, (text or ""):match("^%s*%S+%s*(.-)%s*$") or "") then
			ns.Print(L["No demons setting called '%s'. Type /lockeye demons settings."]:format(name))
		end
	end)
	self:ReadPet()
end

function Demons:UNIT_PET()
	self:ReadPet()
end
Demons.PET_BAR_UPDATE = Demons.UNIT_PET
Demons.SPELLS_CHANGED = Demons.UNIT_PET
Demons.PLAYER_ENTERING_WORLD = Demons.UNIT_PET

function Demons:MERCHANT_SHOW()
	self.vendorOpen, self.dismissed = true, false
	self:ReadPet()
	self:UpdateMarks()
	self:ShowAtVendor()
end

function Demons:MERCHANT_CLOSED()
	self.vendorOpen = false
	if self.panel.atVendor then
		self.panel:Hide()
	end
end
