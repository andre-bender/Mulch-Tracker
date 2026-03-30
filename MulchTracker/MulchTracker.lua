if _G.__MulchTrackerLoaded then
    return
end
_G.__MulchTrackerLoaded = true

local ADDON_NAME = ...
local MT = CreateFrame("Frame", "MulchTrackerFrame")

-- =========================================================
-- CONFIG
-- =========================================================

local VERSION = "v1.3.9"
local ITEM_ID = 238388
local READY_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:16|t"
local SOON_THRESHOLD = 300 -- 5 Minuten

local EXTRA_ITEMS = {
    { id = 238388, name = "Verzauberter Mulch" },
    { id = 237497, name = "Item 237497" },
}

local MULCH_BUFF_ID = 1223395
local NIGHTLOTUS_ITEM_ID = 236780
local MULCH_LOOT_GRACE_SECONDS = 10

local DEBUG_MODE = false

MulchTrackerDB = MulchTrackerDB or {}

local ticker
local panel

-- =========================================================
-- DEBUG
-- =========================================================

local function ChatPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99MulchTracker:|r " .. tostring(msg))
end

local function DebugPrint(...)
    if not DEBUG_MODE then
        return
    end

    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end

    ChatPrint("DEBUG -> " .. table.concat(parts, " "))
end

-- =========================================================
-- DATA / HELPERS
-- =========================================================

local function EnsureDB()
    MulchTrackerDB = MulchTrackerDB or {}
    MulchTrackerDB.characters = MulchTrackerDB.characters or {}

    MulchTrackerDB.window = MulchTrackerDB.window or {
        point = "CENTER",
        relativePoint = "CENTER",
        x = 0,
        y = 0,
        width = 620,
        height = 300,
    }
end

local function GetCharKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetNormalizedRealmName() or GetRealmName() or "UnknownRealm"
    return name .. "-" .. realm
end

local HERBALISM_ID = 182

local function CharacterHasHerbalism()
    local professions = { GetProfessions() }

    for _, profIndex in ipairs(professions) do
        if profIndex then
            local _, _, _, _, _, _, skillLine = GetProfessionInfo(profIndex)
            if skillLine == HERBALISM_ID then
                return true
            end
        end
    end

    return false
end

local function GetClassColor(classFile)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if not color then
        return 1, 1, 1
    end
    return color.r or 1, color.g or 1, color.b or 1
end

local function GetTodayKey()
    return date("%Y-%m-%d")
end

local function GetCharData(key)
    EnsureDB()

    if not MulchTrackerDB.characters[key] then
        local name = UnitName("player") or "Unknown"
        local realm = GetNormalizedRealmName() or GetRealmName() or "UnknownRealm"

        MulchTrackerDB.characters[key] = {
            name = name,
            realm = realm,
            class = select(2, UnitClass("player")),
            displayName = name .. "-" .. realm,
            hasHerbalism = false,
            itemKnown = false,
            readyAt = 0,
            lotus = {
                dayKey = GetTodayKey(),
                dayCount = 0,
                allTimeCount = 0,
            },
            mulchBuffActive = false,
            mulchTrackUntil = 0,
        }
    end

    return MulchTrackerDB.characters[key]
end

local function ResetLotusStatsIfNeeded(data)
    if not data.lotus then
        data.lotus = {
            dayKey = GetTodayKey(),
            dayCount = 0,
            allTimeCount = 0,
        }
        return
    end

    local todayKey = GetTodayKey()

    if data.lotus.dayKey ~= todayKey then
        data.lotus.dayKey = todayKey
        data.lotus.dayCount = 0
    end

    data.lotus.allTimeCount = data.lotus.allTimeCount or 0
end

local function IsReady(ts)
    return (not ts) or ts == 0 or ts <= time()
end

local function GetRemainingSeconds(ts)
    if IsReady(ts) then
        return 0
    end
    return math.max(0, ts - time())
end

local function GetItemCountSafe(itemID)
    if C_Item and C_Item.GetItemCount then
        local count = C_Item.GetItemCount(itemID, false, false, false)
        if count ~= nil then
            return count
        end
    end

    if GetItemCount then
        return GetItemCount(itemID, false, false) or 0
    end

    return 0
end

local function IsItemUsableSafe(itemID)
    if C_Item and C_Item.IsUsableItem then
        local usable, noMana = C_Item.IsUsableItem(itemID)
        return usable, noMana
    end

    if IsUsableItem then
        local usable, noMana = IsUsableItem(itemID)
        return usable, noMana
    end

    return false, false
end

local function GetItemIconSafe(itemID)
    local icon

    if C_Item and C_Item.GetItemIconByID then
        icon = C_Item.GetItemIconByID(itemID)
    end

    if not icon and GetItemIcon then
        icon = GetItemIcon(itemID)
    end

    if not icon and C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end

    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function PlayerHasMulchBuff()
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(MULCH_BUFF_ID)
        local hasAura = aura ~= nil
        DebugPrint("C_UnitAuras buff:", hasAura)
        return hasAura
    end

    if AuraUtil and AuraUtil.FindAuraBySpellID then
        local aura = AuraUtil.FindAuraBySpellID(MULCH_BUFF_ID, "player", "HELPFUL")
        local hasAura = aura ~= nil
        DebugPrint("AuraUtil buff:", hasAura)
        return hasAura
    end

    local i = 1
    while true do
        local name, _, _, _, _, _, _, _, _, spellId = UnitBuff("player", i)
        if not name then
            break
        end

        if spellId == MULCH_BUFF_ID then
            DebugPrint("UnitBuff buff:", true)
            return true
        end

        i = i + 1
    end

    DebugPrint("UnitBuff buff:", false)
    return false
end

local function IsMulchTrackingActive(data)
    if not data then
        return false
    end

    if data.mulchBuffActive then
        return true
    end

    if (data.mulchTrackUntil or 0) > GetTime() then
        return true
    end

    return false
end

local function UpdateMulchBuffState()
    local key = GetCharKey()
    local data = GetCharData(key)
    ResetLotusStatsIfNeeded(data)

    local hasBuff = PlayerHasMulchBuff()
    local wasActive = data.mulchBuffActive

    if hasBuff then
        data.mulchBuffActive = true
        data.mulchTrackUntil = GetTime() + MULCH_LOOT_GRACE_SECONDS
    else
        data.mulchBuffActive = false

        if wasActive then
            data.mulchTrackUntil = GetTime() + MULCH_LOOT_GRACE_SECONDS
            DebugPrint("Buff ended -> grace window until", string.format("%.1f", data.mulchTrackUntil))
        end
    end

    DebugPrint(
        "Tracking state:",
        "buffActive=", tostring(data.mulchBuffActive),
        "trackUntil=", string.format("%.1f", data.mulchTrackUntil or 0),
        "trackingActive=", tostring(IsMulchTrackingActive(data))
    )
end

local function UpdateCurrentCharacterData()
    local key = GetCharKey()
    local data = GetCharData(key)

    data.name = UnitName("player") or data.name
    data.realm = GetNormalizedRealmName() or GetRealmName() or data.realm
    data.class = select(2, UnitClass("player")) or data.class
    data.displayName = (data.name or "Unknown") .. "-" .. (data.realm or "UnknownRealm")
    data.hasHerbalism = CharacterHasHerbalism()

    local startTime, duration = C_Item.GetItemCooldown(ITEM_ID)
    startTime = startTime or 0
    duration = duration or 0

    if startTime > 0 and duration > 0 then
        local remaining = math.max(0, math.ceil((startTime + duration) - GetTime()))
        data.readyAt = time() + remaining
    else
        data.readyAt = 0
    end

    ResetLotusStatsIfNeeded(data)
    UpdateMulchBuffState()
end

local function FormatReady(ts)
    if IsReady(ts) then
        return READY_ICON
    end

    return date("%H:%M", ts)
end

local function GetRowStatus(data)
    local remaining = GetRemainingSeconds(data.readyAt)

    if remaining <= 0 then
        return "ready"
    elseif remaining <= SOON_THRESHOLD then
        return "soon"
    elseif remaining > 0 then
        return "cooldown"
    else
        return "unknown"
    end
end

local function SortKeysByReady(keys)
    table.sort(keys, function(a, b)
        local da = MulchTrackerDB.characters[a]
        local db = MulchTrackerDB.characters[b]

        local ta = da and da.readyAt or 0
        local tb = db and db.readyAt or 0

        local now = time()
        local aReady = (ta == 0) or (ta <= now)
        local bReady = (tb == 0) or (tb <= now)

        if aReady and not bReady then
            return true
        elseif bReady and not aReady then
            return false
        end

        if not aReady and not bReady and ta ~= tb then
            return ta < tb
        end

        return a < b
    end)
end

-- =========================================================
-- LOTUS TRACKING VIA LOOT EVENT
-- =========================================================

local function EscapeLuaPattern(text)
    return text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

local function GlobalStringToPattern(globalString)
    if not globalString or globalString == "" then
        return nil
    end

    local pattern = EscapeLuaPattern(globalString)
    pattern = pattern:gsub("%%%%%d+%$s", "(.+)")
    pattern = pattern:gsub("%%%%%d+%$d", "(%%d+)")
    pattern = pattern:gsub("%%%%s", "(.+)")
    pattern = pattern:gsub("%%%%d", "(%%d+)")

    return "^" .. pattern .. "$"
end

local function ParseSelfLootMessage(msg)
    if not msg or msg == "" then
        return nil, nil, nil
    end

    local candidates = {
        { key = "LOOT_ITEM_SELF_MULTIPLE", value = LOOT_ITEM_SELF_MULTIPLE, multiple = true },
        { key = "LOOT_ITEM_PUSHED_SELF_MULTIPLE", value = LOOT_ITEM_PUSHED_SELF_MULTIPLE, multiple = true },
        { key = "LOOT_ITEM_SELF", value = LOOT_ITEM_SELF, multiple = false },
        { key = "LOOT_ITEM_PUSHED_SELF", value = LOOT_ITEM_PUSHED_SELF, multiple = false },
    }

    for _, entry in ipairs(candidates) do
        if entry.value and entry.value ~= "" then
            local pattern = GlobalStringToPattern(entry.value)
            if pattern then
                local a, b = msg:match(pattern)
                if a then
                    if entry.multiple then
                        return a, tonumber(b) or 1, entry.key
                    else
                        return a, 1, entry.key
                    end
                end
            end
        end
    end

    return nil, nil, nil
end

local function ParseItemIDFromLink(itemLink)
    if not itemLink then
        return nil
    end

    local itemID = itemLink:match("|Hitem:(%d+):")
    if itemID then
        return tonumber(itemID)
    end

    local idFromAPI = GetItemInfoInstant(itemLink)
    if type(idFromAPI) == "number" then
        return idFromAPI
    end

    return nil
end

local function HandleLootMessage(msg, playerName)
    local key = GetCharKey()
    local data = GetCharData(key)

    ResetLotusStatsIfNeeded(data)
    UpdateMulchBuffState()

    DebugPrint("CHAT_MSG_LOOT raw:", msg or "nil")
    DebugPrint("CHAT_MSG_LOOT playerName:", playerName or "nil")
    DebugPrint(
        "Tracking check:",
        "buffActive=", tostring(data.mulchBuffActive),
        "trackUntil=", string.format("%.1f", data.mulchTrackUntil or 0),
        "now=", string.format("%.1f", GetTime()),
        "trackingActive=", tostring(IsMulchTrackingActive(data))
    )

    local itemLink, quantity, matchedPattern = ParseSelfLootMessage(msg)
    DebugPrint("Matched pattern:", matchedPattern or "none")
    DebugPrint("itemLink:", itemLink or "nil", "qty:", quantity or "nil")

    if not itemLink then
        DebugPrint("No matching self loot pattern.")
        return
    end

    local itemID = ParseItemIDFromLink(itemLink)
    DebugPrint("Parsed itemID:", tostring(itemID), "expected:", tostring(NIGHTLOTUS_ITEM_ID))

    if itemID ~= NIGHTLOTUS_ITEM_ID then
        DebugPrint("Item is not Nachtlotus.")
        return
    end

    if not IsMulchTrackingActive(data) then
        DebugPrint("Nachtlotus found, but tracking is inactive.")
        return
    end

    quantity = tonumber(quantity) or 1
    if quantity <= 0 then
        DebugPrint("Invalid quantity:", tostring(quantity))
        return
    end

    data.lotus.dayCount = (data.lotus.dayCount or 0) + quantity
    data.lotus.allTimeCount = (data.lotus.allTimeCount or 0) + quantity

    DebugPrint("Counted! +", quantity, "Daily:", data.lotus.dayCount, "AllTime:", data.lotus.allTimeCount)
end

-- =========================================================
-- MAIN PANEL
-- =========================================================

panel = CreateFrame("Frame", "MulchTrackerPanel", UIParent, "BackdropTemplate")
panel:SetSize(620, 300)
panel:SetResizeBounds(420, 300)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:SetResizable(true)
panel:RegisterForDrag("LeftButton")
panel:SetClampedToScreen(true)

panel:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
panel:SetBackdropColor(0, 0, 0, 0.85)

panel:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)

panel:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()

    EnsureDB()
    local point, _, relativePoint, x, y = self:GetPoint()
    MulchTrackerDB.window.point = point
    MulchTrackerDB.window.relativePoint = relativePoint
    MulchTrackerDB.window.x = x
    MulchTrackerDB.window.y = y
    MulchTrackerDB.window.width = self:GetWidth()
    MulchTrackerDB.window.height = self:GetHeight()
end)

panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
panel.title:SetPoint("TOPLEFT", 12, -10)
panel.title:SetText("Mulch Tracker")

panel.versionText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
panel.versionText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -30, -14)
panel.versionText:SetText(VERSION)
panel.versionText:SetTextColor(0.7, 0.7, 0.7)

panel.close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
panel.close:SetPoint("TOPRIGHT", 0, 0)

panel.scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
panel.scroll:SetPoint("TOPLEFT", 10, -35)
panel.scroll:SetPoint("BOTTOMRIGHT", -30, 72)
panel.content = CreateFrame("Frame", nil, panel.scroll)
panel.content:SetSize(550, 1)
panel.scroll:SetScrollChild(panel.content)

panel.headerName = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.headerName:SetJustifyH("LEFT")
panel.headerName:SetText("Character")
panel.headerName:SetTextColor(1, 0.82, 0)

panel.headerLotusTop = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.headerLotusTop:SetJustifyH("CENTER")
panel.headerLotusTop:SetText("Lotus")
panel.headerLotusTop:SetTextColor(1, 0.82, 0)

panel.headerLotusDaily = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.headerLotusDaily:SetJustifyH("CENTER")
panel.headerLotusDaily:SetText("Daily")
panel.headerLotusDaily:SetTextColor(1, 0.82, 0)

panel.headerAllTop = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.headerAllTop:SetJustifyH("CENTER")
panel.headerAllTop:SetText("All")
panel.headerAllTop:SetTextColor(1, 0.82, 0)

panel.headerLotusAllTime = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.headerLotusAllTime:SetJustifyH("CENTER")
panel.headerLotusAllTime:SetText("Time")
panel.headerLotusAllTime:SetTextColor(1, 0.82, 0)

panel.headerTime = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.headerTime:SetJustifyH("RIGHT")
panel.headerTime:SetText("Ready")
panel.headerTime:SetTextColor(1, 0.82, 0)

panel.rows = {}
panel.itemButtons = {}

panel.ResizeGrip = CreateFrame("Button", nil, panel)
panel.ResizeGrip:SetSize(20, 20)
panel.ResizeGrip:SetPoint("BOTTOMRIGHT")
panel.ResizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
panel.ResizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
panel.ResizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
panel.ResizeGrip:SetScript("OnMouseDown", function(self)
    self:GetParent():StartSizing()
end)
panel.ResizeGrip:SetScript("OnMouseUp", function(self)
    self:GetParent():StopMovingOrSizing()

    EnsureDB()
    local point, _, relativePoint, x, y = self:GetParent():GetPoint()
    MulchTrackerDB.window.point = point
    MulchTrackerDB.window.relativePoint = relativePoint
    MulchTrackerDB.window.x = x
    MulchTrackerDB.window.y = y
    MulchTrackerDB.window.width = self:GetParent():GetWidth()
    MulchTrackerDB.window.height = self:GetParent():GetHeight()
end)

local function UpdateContentWidth()
    local width = panel.scroll:GetWidth()
    if not width or width < 100 then
        width = 550
    end
    panel.content:SetWidth(width)
end

local function GetColumnLayout()
    local contentWidth = panel.content:GetWidth() or 550
    local leftPadding = 6
    local rightPadding = 12

    local available = math.max(300, contentWidth - leftPadding - rightPadding)

    local gap = math.max(4, math.min(10, math.floor(available * 0.012)))

    local baseTimeWidth = 62
    local baseDailyWidth = 40
    local baseAllTimeWidth = 40
    local minNameWidth = 135

    local baseTotal = minNameWidth + baseDailyWidth + baseAllTimeWidth + baseTimeWidth + (gap * 2)
    local extra = math.max(0, available - baseTotal)

    local nameWidth = minNameWidth + math.floor(extra * 0.38)
    local dailyWidth = baseDailyWidth + math.floor(extra * 0.22)
    local allTimeWidth = baseAllTimeWidth + math.floor(extra * 0.24)
    local timeWidth = baseTimeWidth + math.floor(extra * 0.16)

    local used = nameWidth + dailyWidth + allTimeWidth + timeWidth + (gap * 2)
    local remainder = available - used
    nameWidth = nameWidth + math.max(0, remainder)

    local nameLeft = leftPadding
    local dailyLeft = nameLeft + nameWidth + gap
    local allTimeLeft = dailyLeft + dailyWidth + gap
    local timeLeft = allTimeLeft + allTimeWidth + gap

    return {
        nameLeft = nameLeft,
        nameWidth = nameWidth,
        dailyLeft = dailyLeft,
        dailyWidth = dailyWidth,
        allTimeLeft = allTimeLeft,
        allTimeWidth = allTimeWidth,
        timeLeft = timeLeft,
        timeWidth = timeWidth,
    }
end

local function UpdateHeaderLayout()
    local layout = GetColumnLayout()

    local topY = -4
    local bottomY = -20

    panel.headerName:ClearAllPoints()
    panel.headerName:SetPoint("TOPLEFT", layout.nameLeft, bottomY)
    panel.headerName:SetWidth(layout.nameWidth)

    panel.headerLotusTop:ClearAllPoints()
    panel.headerLotusTop:SetPoint("TOPLEFT", layout.dailyLeft, topY)
    panel.headerLotusTop:SetWidth(layout.dailyWidth)

    panel.headerLotusDaily:ClearAllPoints()
    panel.headerLotusDaily:SetPoint("TOPLEFT", layout.dailyLeft, bottomY)
    panel.headerLotusDaily:SetWidth(layout.dailyWidth)

    panel.headerAllTop:ClearAllPoints()
    panel.headerAllTop:SetPoint("TOPLEFT", layout.allTimeLeft, topY)
    panel.headerAllTop:SetWidth(layout.allTimeWidth)

    panel.headerLotusAllTime:ClearAllPoints()
    panel.headerLotusAllTime:SetPoint("TOPLEFT", layout.allTimeLeft, bottomY)
    panel.headerLotusAllTime:SetWidth(layout.allTimeWidth)

    panel.headerTime:ClearAllPoints()
    panel.headerTime:SetPoint("TOPLEFT", layout.timeLeft, bottomY)
    panel.headerTime:SetWidth(layout.timeWidth)
end

local function UpdateRowLayout(row)
    local layout = GetColumnLayout()
    local contentWidth = panel.content:GetWidth() or 550

    row:SetWidth(contentWidth)

    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", layout.nameLeft, 0)
    row.name:SetWidth(layout.nameWidth)

    row.lotusDaily:ClearAllPoints()
    row.lotusDaily:SetPoint("LEFT", layout.dailyLeft, 0)
    row.lotusDaily:SetWidth(layout.dailyWidth)

    row.lotusAllTime:ClearAllPoints()
    row.lotusAllTime:SetPoint("LEFT", layout.allTimeLeft, 0)
    row.lotusAllTime:SetWidth(layout.allTimeWidth)

    row.time:ClearAllPoints()
    row.time:SetPoint("LEFT", layout.timeLeft, 0)
    row.time:SetWidth(layout.timeWidth)
end

local function ApplyWindowPosition()
    EnsureDB()

    panel:ClearAllPoints()
    panel:SetPoint(
        MulchTrackerDB.window.point or "CENTER",
        UIParent,
        MulchTrackerDB.window.relativePoint or "CENTER",
        MulchTrackerDB.window.x or 0,
        MulchTrackerDB.window.y or 0
    )
    panel:SetSize(
        MulchTrackerDB.window.width or 620,
        MulchTrackerDB.window.height or 300
    )

    C_Timer.After(0, function()
        UpdateContentWidth()
        UpdateHeaderLayout()
    end)
end

local function GetRow(i)
    if not panel.rows[i] then
        local row = CreateFrame("Frame", nil, panel.content)
        row:SetHeight(18)
        row:SetWidth(panel.content:GetWidth())

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetJustifyH("LEFT")

        row.lotusDaily = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.lotusDaily:SetJustifyH("CENTER")

        row.lotusAllTime = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.lotusAllTime:SetJustifyH("CENTER")

        row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.time:SetJustifyH("RIGHT")

        if i == 1 then
            row:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -40)
        else
            row:SetPoint("TOPLEFT", panel.rows[i - 1], "BOTTOMLEFT", 0, -2)
        end

        panel.rows[i] = row
    end

    UpdateRowLayout(panel.rows[i])
    return panel.rows[i]
end

local function ApplyRowVisualState(row, data, index)
    local classR, classG, classB = GetClassColor(data.class)
    row.name:SetTextColor(classR, classG, classB)

    if row.lotusDaily then
        row.lotusDaily:SetTextColor(1, 1, 1)
    end
    if row.lotusAllTime then
        row.lotusAllTime:SetTextColor(1, 1, 1)
    end

    local status = GetRowStatus(data)

    if status == "missing" then
        row.time:SetTextColor(0.7, 0.7, 0.7)
        if row.lotusDaily then
            row.lotusDaily:SetTextColor(0.7, 0.7, 0.7)
        end
        if row.lotusAllTime then
            row.lotusAllTime:SetTextColor(0.7, 0.7, 0.7)
        end
        row.bg:SetColorTexture(1, 1, 1, (index % 2 == 0) and 0.05 or 0.03)
        return
    end

    if status == "ready" then
        row.time:SetTextColor(0.35, 1.0, 0.35)
        row.bg:SetColorTexture(0.08, 0.35, 0.08, 0.22)
    elseif status == "soon" then
        row.time:SetTextColor(1.0, 0.9, 0.2)
        row.bg:SetColorTexture(0.40, 0.30, 0.05, 0.22)
    else
        row.time:SetTextColor(1.0, 0.25, 0.25)
        row.bg:SetColorTexture(0.35, 0.06, 0.06, 0.20)
    end
end

local function RefreshUI()
    EnsureDB()
    UpdateContentWidth()
    UpdateHeaderLayout()

    local keys = {}
    for key, data in pairs(MulchTrackerDB.characters) do
        if data.hasHerbalism then
            table.insert(keys, key)
        end
    end

    SortKeysByReady(keys)

    if #keys == 0 then
        local row = GetRow(1)
        row.name:SetText("No characters with herbalism found")
        row.name:SetTextColor(1, 1, 1)
        row.lotusDaily:SetText("")
        row.lotusAllTime:SetText("")
        row.time:SetText("")
        row.bg:SetColorTexture(1, 1, 1, 0.03)
        row:Show()

        for i = 2, #panel.rows do
            panel.rows[i]:Hide()
        end

        panel.content:SetHeight(72)
        return
    end

    for i, key in ipairs(keys) do
        local data = MulchTrackerDB.characters[key]
        local row = GetRow(i)

        ResetLotusStatsIfNeeded(data)

        row.name:SetText(data.displayName or key)
        row.lotusDaily:SetText(tostring(data.lotus.dayCount or 0))
        row.lotusAllTime:SetText(tostring(data.lotus.allTimeCount or 0))
        row.time:SetText(FormatReady(data.readyAt))

        ApplyRowVisualState(row, data, i)
        row:Show()
    end

    for i = #keys + 1, #panel.rows do
        panel.rows[i]:Hide()
    end

    panel.content:SetHeight(math.max(72, 40 + (#keys * 20)))
end

-- =========================================================
-- ITEM BUTTONS
-- =========================================================

local function UpdateItemButton(button)
    if not button or not button.itemID then
        return
    end

    local itemID = button.itemID
    local count = GetItemCountSafe(itemID)
    local usable = IsItemUsableSafe(itemID)
    local icon = GetItemIconSafe(itemID)

    local startTime, duration = C_Item.GetItemCooldown(itemID)
    startTime = startTime or 0
    duration = duration or 0

    local remaining = 0
    if startTime > 0 and duration > 0 then
        remaining = math.max(0, math.ceil((startTime + duration) - GetTime()))
    end

    button.icon:SetTexture(icon)
    button:SetAttribute("type", "item")
    button:SetAttribute("item", "item:" .. itemID)

    if count and count > 0 then
        button.count:SetText(count)
    else
        button.count:SetText("")
    end

    if remaining > 0 then
        if remaining < 60 then
            button.cooldownText:SetText(remaining)
        else
            local minutes = math.ceil(remaining / 60)
            button.cooldownText:SetText(minutes .. "m")
        end

        button.cooldownText:Show()
        button.icon:SetDesaturated(true)
        button.icon:SetAlpha(0.55)
    else
        button.cooldownText:SetText("")
        button.cooldownText:Hide()

        if count > 0 then
            button.icon:SetDesaturated(false)
            button.icon:SetAlpha(usable and 1 or 0.55)
        else
            button.icon:SetDesaturated(true)
            button.icon:SetAlpha(0.35)
        end
    end

    if count > 0 then
        button.count:SetTextColor(1, 1, 1)

        if remaining > 0 then
            button.border:SetBackdropBorderColor(0.8, 0.65, 0.2, 1)
        else
            if usable then
                button.border:SetBackdropBorderColor(0.2, 0.8, 0.2, 1)
            else
                button.border:SetBackdropBorderColor(0.8, 0.65, 0.2, 1)
            end
        end
    else
        button.icon:SetDesaturated(true)
        button.icon:SetAlpha(0.35)
        button.count:SetText("")
        button.cooldownText:SetText("")
        button.cooldownText:Hide()
        button.border:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
    end
end

local function UpdateItemButtons()
    if not panel.itemButtons then
        return
    end

    for _, button in ipairs(panel.itemButtons) do
        UpdateItemButton(button)
    end
end

local function CreateItemButton(parent, itemID, anchorTo, offsetX)
    local button = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    button:SetSize(42, 42)
    button.itemID = itemID
    button:RegisterForClicks("AnyUp", "AnyDown")

    if anchorTo then
        button:SetPoint("LEFT", anchorTo, "RIGHT", offsetX or 8, 0)
    else
        button:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 12, 34)
    end

    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.bg:SetColorTexture(0, 0, 0, 0.4)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", 2, -2)
    button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon:SetTexture(GetItemIconSafe(itemID))

    button.border = CreateFrame("Frame", nil, button, "BackdropTemplate")
    button.border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    button.border:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    button.border:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    button.border:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)

    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
    button.count:SetJustifyH("RIGHT")
    button.count:SetText("")

    button.cooldownText = button:CreateFontString(nil, "OVERLAY")
    button.cooldownText:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.cooldownText:SetJustifyH("CENTER")
    button.cooldownText:SetTextColor(1, 1, 1)
    button.cooldownText:SetFont("Fonts\\FRIZQT__.TTF", 20, "OUTLINE")
    button.cooldownText:SetShadowOffset(1, -1)
    button.cooldownText:SetShadowColor(0, 0, 0, 1)
    button.cooldownText:SetText("")
    button.cooldownText:Hide()

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("item:" .. self.itemID)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return button
end

local function CreateItemButtons()
    if panel.itemButtonsCreated then
        return
    end

    local button1 = CreateItemButton(panel, EXTRA_ITEMS[1].id, nil, nil)
    local button2 = CreateItemButton(panel, EXTRA_ITEMS[2].id, button1, 8)

    panel.itemButtons[1] = button1
    panel.itemButtons[2] = button2
    panel.itemButtonsCreated = true

    UpdateItemButtons()
end

-- =========================================================
-- URLClickerBox
-- =========================================================

local URLClickerBox

local function CreateURLClickerBox()
    if URLClickerBox then
        return
    end

    URLClickerBox = CreateFrame("Frame", "MulchTrackerURLClickerBox", UIParent, "DialogBoxFrame")
    URLClickerBox:SetSize(250, 125)
    URLClickerBox:SetPoint("CENTER")
    URLClickerBox:SetClampedToScreen(true)
    URLClickerBox:Hide()

    URLClickerBox:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\PVPFrame\\UI-Character-PVP-Highlight",
        edgeSize = 16,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    URLClickerBox:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.6)

    URLClickerBox:SetMovable(true)
    URLClickerBox:EnableMouse(true)
    URLClickerBox:RegisterForDrag("LeftButton")
    URLClickerBox:SetScript("OnDragStart", URLClickerBox.StartMoving)
    URLClickerBox:SetScript("OnDragStop", URLClickerBox.StopMovingOrSizing)

    URLClickerBox.text = URLClickerBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    URLClickerBox.text:SetPoint("TOP", 0, -30)
    URLClickerBox.text:SetText("CTRL + C to copy the link")

    URLClickerBox.editBox = CreateFrame("EditBox", nil, URLClickerBox, "InputBoxTemplate")
    URLClickerBox.editBox:SetSize(200, 30)
    URLClickerBox.editBox:SetPoint("CENTER", 0, 0)
    URLClickerBox.editBox:SetAutoFocus(true)
    URLClickerBox.editBox:SetFontObject(GameFontHighlight)
    URLClickerBox.editBox:SetTextInsets(6, 6, 0, 0)

    URLClickerBox.editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        URLClickerBox:Hide()
    end)

    URLClickerBox.editBox:SetScript("OnEnterPressed", function(self)
        self:HighlightText()
    end)
end

local function ShowURLCopyBox(url)
    CreateURLClickerBox()

    URLClickerBox:Show()
    URLClickerBox.editBox:SetText(url or "")
    URLClickerBox.editBox:SetFocus()
    URLClickerBox.editBox:HighlightText()
end

hooksecurefunc("SetItemRef", function(link, text, button, chatFrame)
    if type(link) == "string" and string.sub(link, 1, 4) == "url:" then
        local url = string.sub(link, 5)
        ShowURLCopyBox(url)
    end
end)

-- =========================================================
-- LOGOUT BUTTON
-- =========================================================

local function CreateLogoutButton()
    local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    button:SetSize(80, 22)
    button:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 10)
    button:SetText("Logout")

    local secure = CreateFrame("Button", nil, button, "SecureActionButtonTemplate")
    secure:SetAllPoints(button)
    secure:RegisterForClicks("AnyUp", "AnyDown")
    secure:SetAttribute("type", "macro")
    secure:SetAttribute("macrotext", "/logout")

    panel.logoutButton = button

    local devButton = CreateFrame("Button", nil, panel)
    devButton:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 12)
    devButton:SetSize(220, 16)

    local devText = devButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    devText:SetAllPoints()
    devText:SetText("Developed by twitch.tv/GoldbaronTV")
    devText:SetTextColor(0.6, 0.6, 0.6)
    devText:SetJustifyH("LEFT")

    devButton:SetScript("OnEnter", function()
        devText:SetTextColor(1, 0.82, 0)
    end)

    devButton:SetScript("OnLeave", function()
        devText:SetTextColor(0.6, 0.6, 0.6)
    end)

    devButton:SetScript("OnClick", function()
        SetItemRef("url:https://twitch.tv/goldbarontv", "https://twitch.tv/goldbarontv", "LeftButton")
    end)

    panel.devText = devText
    panel.devButton = devButton
end

-- =========================================================
-- TICKER / COMMANDS
-- =========================================================

local function StartTicker()
    if ticker then
        ticker:Cancel()
    end

    ticker = C_Timer.NewTicker(1, function()
        if panel:IsShown() then
            RefreshUI()
            UpdateItemButtons()
        end
    end)
end

SLASH_MULCHTRACKER1 = "/mulch"
SLASH_MULCHTRACKER2 = "/mulchtracker"
SLASH_MULCHTRACKERDEBUG1 = "/mulchdebug"
SLASH_MULCHTRACKERDEBUG2 = "/mtdebug"

SlashCmdList["MULCHTRACKER"] = function(msg)
    msg = string.lower((msg or ""):gsub("^%s+", ""):gsub("%s+$", ""))

    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
        RefreshUI()
        UpdateItemButtons()
    end
end

SlashCmdList["MULCHTRACKERDEBUG"] = function(msg)
    DEBUG_MODE = not DEBUG_MODE
    ChatPrint("Debug-Modus " .. (DEBUG_MODE and "|cff00ff00AKTIV|r" or "|cffff0000INAKTIV|r"))

    if DEBUG_MODE then
        local data = GetCharData(GetCharKey())
        UpdateMulchBuffState()
        ChatPrint("Buff aktiv = " .. tostring(data.mulchBuffActive))
        ChatPrint("Tracking aktiv = " .. tostring(IsMulchTrackingActive(data)))
        ChatPrint("Grace Window bis = " .. string.format("%.1f", data.mulchTrackUntil or 0))
        ChatPrint("Warte auf Loot von ItemID " .. tostring(NIGHTLOTUS_ITEM_ID))
    end
end

-- =========================================================
-- EVENTS
-- =========================================================

MT:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local addon = ...
        if addon ~= ADDON_NAME then
            return
        end

        EnsureDB()
        ApplyWindowPosition()
        CreateLogoutButton()
        CreateItemButtons()
        panel:Show()
        StartTicker()
        ChatPrint("geladen (" .. VERSION .. "). Befehle: /mulch, /mulchdebug")

    elseif event == "PLAYER_LOGIN" then
        C_Timer.After(2, function()
            UpdateCurrentCharacterData()
            RefreshUI()
            UpdateItemButtons()
        end)

    elseif event == "PLAYER_ENTERING_WORLD" then
        UpdateCurrentCharacterData()
        RefreshUI()
        UpdateItemButtons()

    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then
            UpdateMulchBuffState()
            DebugPrint("UNIT_AURA -> buff active =", tostring(GetCharData(GetCharKey()).mulchBuffActive))
            RefreshUI()
        end

    elseif event == "CHAT_MSG_LOOT" then
        local msg, playerName = ...
        HandleLootMessage(msg, playerName)
        RefreshUI()

    elseif event == "BAG_UPDATE_COOLDOWN" then
        UpdateCurrentCharacterData()
        RefreshUI()
        UpdateItemButtons()

    elseif event == "BAG_UPDATE_DELAYED" then
        UpdateCurrentCharacterData()
        RefreshUI()
        UpdateItemButtons()

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        UpdateItemButtons()
    end
end)

MT:RegisterEvent("ADDON_LOADED")
MT:RegisterEvent("PLAYER_LOGIN")
MT:RegisterEvent("PLAYER_ENTERING_WORLD")
MT:RegisterEvent("UNIT_AURA")
MT:RegisterEvent("CHAT_MSG_LOOT")
MT:RegisterEvent("BAG_UPDATE_COOLDOWN")
MT:RegisterEvent("BAG_UPDATE_DELAYED")
MT:RegisterEvent("GET_ITEM_INFO_RECEIVED")