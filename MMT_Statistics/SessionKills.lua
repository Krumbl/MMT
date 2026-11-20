-- MMT Statistics: Session Kill-Details - every NPC this character killed in
-- the current session, as a window opened from the live tracker:
--   Zone | NPC | Avg Lvl | Kills | XP | XP / Kill | Money
-- Kept in memory only: a new session (live tracker "Reset session", or a
-- login / reload) starts empty.
--   kills: counted with the Kills tab's counting (Kills.lua)
--   XP:    the "X dies, you gain N experience." message
--   level: the NPC's level when it was last seen (target, mouseover, nameplates)
--   money: coins looted from its corpse (the loot window's sources; several
--          corpses at once share the coins by what each had, else evenly)

local _, mod = ...
local MMT = MMT
local M = mod.M
local A = { 0.31, 0.70, 1.00 }

local data = {}         -- [zone] = { [npc] = { k, xp, money, lvlSum, lvlN } }
local levelOf = {}      -- [npc name] = level seen last
local guidName = {}     -- [guid] = npc name (kills of this session)
local lastKill          -- { zone, name } of the last kill
local lootSources       -- { { name, zone, share } } of the open loot window

local function Plain(v)
    if v == nil or MMT.IsSecret(v) then return nil end
    return v
end
local function Safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if ok then return Plain(v) end
end

local function Zone()
    local z = Safe(GetRealZoneText)
    return (z and z ~= "") and z or "?"
end

local function Entry(zone, name)
    data[zone] = data[zone] or {}
    local e = data[zone][name]
    if not e then
        e = { k = 0, xp = 0, money = 0, lvlSum = 0, lvlN = 0 }
        data[zone][name] = e
    end
    return e
end

-- levels: remember what is seen (a dead NPC's level can still be read)
local function SeeUnit(unit)
    if Safe(UnitIsPlayer, unit) then return end
    local name, level = Safe(UnitName, unit), Safe(UnitLevel, unit)
    if name and level and level > 0 then levelOf[name] = level end
end
M:On("PLAYER_TARGET_CHANGED", function() SeeUnit("target") end)
M:On("UPDATE_MOUSEOVER_UNIT", function() SeeUnit("mouseover") end)
M:On("NAME_PLATE_UNIT_ADDED", function(unit) SeeUnit(unit) end)

local function LevelNow(name, guid)
    for _, unit in ipairs({ "target", "mouseover", "focus" }) do
        if guid and Safe(UnitGUID, unit) == guid or (not guid and Safe(UnitName, unit) == name) then
            local l = Safe(UnitLevel, unit)
            if l and l > 0 then return l end
        end
    end
    return levelOf[name]
end

-- from Kills.lua
function mod.SessionKill(name, guid)
    if not name then return end
    local zone = Zone()
    local e = Entry(zone, name)
    e.k = e.k + 1
    local lvl = LevelNow(name, guid)
    if lvl then e.lvlSum = e.lvlSum + lvl; e.lvlN = e.lvlN + 1 end
    if guid then guidName[guid] = name end
    lastKill = { zone = zone, name = name }
    if mod.RedrawSessionKills then mod.RedrawSessionKills() end
end

function mod.SessionRename(old, new, guid)
    local zone = Zone()
    local z = data[zone]
    local from = z and z[old]
    if from and from.k > 0 then
        from.k = from.k - 1
        if from.k <= 0 and from.xp == 0 and from.money == 0 then z[old] = nil end
    end
    mod.SessionKill(new, guid)
end

function mod.SessionKillXP(name, xp)
    if not name or not xp or xp <= 0 then return end
    local e = Entry(Zone(), name)
    e.xp = e.xp + xp
    if mod.RedrawSessionKills then mod.RedrawSessionKills() end
end

-- the loot window: whose coins are in it
M:On("LOOT_OPENED", function()
    lootSources = nil
    local n = Safe(GetNumLootItems) or 0
    local list, byName = {}, {}
    for slot = 1, n do
        local kind = Safe(GetLootSlotType, slot)
        if kind == (Enum and Enum.LootSlotType and Enum.LootSlotType.Money or 2) and type(GetLootSourceInfo) == "function" then
            local src = { pcall(GetLootSourceInfo, slot) }
            if src[1] then
                for i = 2, #src, 2 do
                    local guid, amount = Plain(src[i]), Plain(src[i + 1])
                    local name = guid and guidName[guid]
                    if not name and guid and Safe(UnitGUID, "target") == guid then name = Safe(UnitName, "target") end
                    if name then
                        local e = byName[name]
                        if not e then e = { name = name, zone = Zone(), share = 0 } byName[name] = e list[#list + 1] = e end
                        e.share = e.share + (tonumber(amount) or 0)
                    end
                end
            end
        end
    end
    if #list == 0 then
        local t = Safe(UnitName, "target")
        if t and Safe(UnitIsDead, "target") and not Safe(UnitIsPlayer, "target") then list[1] = { name = t, zone = Zone(), share = 0 } end
    end
    lootSources = #list > 0 and list or nil
end)
M:On("LOOT_CLOSED", function() C_Timer.After(2, function() lootSources = nil end) end)

-- from Money.lua: looted coins
function mod.SessionLootMoney(copper)
    local list = lootSources
    if not list then
        if not lastKill then return end
        list = { { name = lastKill.name, zone = lastKill.zone, share = 0 } }
    end
    local total = 0
    for _, s in ipairs(list) do total = total + (s.share or 0) end
    local given = 0
    for i, s in ipairs(list) do
        local part
        if i == #list then part = copper - given
        elseif total > 0 then part = math.floor(copper * s.share / total)
        else part = math.floor(copper / #list) end
        given = given + part
        local e = Entry(s.zone, s.name)
        e.money = e.money + part
    end
    if mod.RedrawSessionKills then mod.RedrawSessionKills() end
end

-- a new session (live tracker "Reset session"; login / reload start empty anyway)
function mod.ResetSessionKills()
    wipe(data)
    wipe(guidName)
    lastKill, lootSources = nil, nil
    if mod.RedrawSessionKills then mod.RedrawSessionKills() end
end

-- { { zone, name, avgLvl|nil, k, xp, money } } sorted: zone, then kills
function mod.SessionKillRows()
    local rows = {}
    for zone, npcs in pairs(data) do
        for name, e in pairs(npcs) do
            rows[#rows + 1] = { zone, name, e.lvlN > 0 and e.lvlSum / e.lvlN or nil, e.k, e.xp, e.money }
        end
    end
    table.sort(rows, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        if a[4] ~= b[4] then return a[4] > b[4] end
        return a[2] < b[2]
    end)
    return rows
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local win
local ROW_H, ROWS = 16, 18
local COLS = {   -- { title, right edge (nil: left aligned at x), x }
    { "Zone", nil, 8 }, { "NPC", nil, 150 }, { "Avg Lvl", 352 }, { "Kills", 400 },
    { "XP", 470 }, { "XP / Kill", 536 }, { "Money", 640 },
}
local WIN_W = 652

local function Money(c) return mod.Money(c or 0) end
local function Num(n)
    n = math.floor((n or 0) + 0.5)
    local s = tostring(n)
    local k
    repeat s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
end

local function Cell(parent, col, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local c = COLS[col]
    if c[2] then
        fs:SetPoint("TOPRIGHT", parent, "TOPLEFT", c[2], y)
        fs:SetJustifyH("RIGHT")
    else
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", c[3], y)
        fs:SetWidth((col == 1 and 138) or 196)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
    end
    return fs
end

local function Build()
    if win then return win end
    local UI = MMT.UI
    win = CreateFrame("Frame", "MMTSessionKillDetails", UIParent)
    win:SetSize(WIN_W, 70 + ROW_H * (ROWS + 1))
    win:SetFrameStrata("DIALOG")
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        M.db.sessionKillsPos = { p, rp, x, y }
    end)
    local pos = M.db.sessionKillsPos
    if pos then win:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else win:SetPoint("CENTER", 0, 80) end
    UI.Fill(win, 0.05, 0.05, 0.06, 0.94)
    UI.Border(win, A[1], A[2], A[3], 0.45)
    if UI.CloseOnEscape then UI.CloseOnEscape(win) end

    local title = UI.Label(win, "Session Kill-Details", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetTextColor(A[1], A[2], A[3])
    local x = UI.Button(win, 20, "x", function() win:Hide() end)
    x:SetPoint("TOPRIGHT", -6, -5)
    win.sub = UI.Label(win, "", "GameFontNormalSmall")
    win.sub:SetPoint("LEFT", title, "RIGHT", 10, 0)
    win.sub:SetTextColor(0.6, 0.6, 0.6)

    local y0 = -30
    for i, c in ipairs(COLS) do
        local h = Cell(win, i, y0)
        h:SetFontObject("GameFontNormalSmall")
        h:SetText(c[1])
        h:SetTextColor(A[1], A[2], A[3])
    end
    win.rows = {}
    for r = 1, ROWS do
        local y = y0 - ROW_H * r
        local row = { cells = {} }
        row.bg = win:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.bg:SetPoint("TOPLEFT", 4, y + 2)
        row.bg:SetSize(WIN_W - 8, ROW_H)
        row.bg:SetColorTexture(1, 1, 1, r % 2 == 0 and 0.03 or 0)
        for i = 1, #COLS do row.cells[i] = Cell(win, i, y) end
        win.rows[r] = row
    end
    win.total = {}
    local ty = y0 - ROW_H * (ROWS + 1) - 4
    local line = win:CreateTexture(nil, "BORDER")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 6, ty + 3) line:SetPoint("TOPRIGHT", -6, ty + 3)
    for i = 1, #COLS do win.total[i] = Cell(win, i, ty) end

    win.offset = 0
    win:EnableMouseWheel(true)
    win:SetScript("OnMouseWheel", function(self, delta)
        self.offset = math.max(0, self.offset - delta * 3)
        mod.RedrawSessionKills()
    end)
    win:Hide()
    return win
end

function mod.RedrawSessionKills()
    if not (win and win:IsShown()) then return end
    local rows = mod.SessionKillRows()
    win.offset = math.max(0, math.min(win.offset, #rows - ROWS))
    local t = { k = 0, xp = 0, money = 0 }
    for _, r in ipairs(rows) do t.k = t.k + r[4]; t.xp = t.xp + r[5]; t.money = t.money + r[6] end
    local prevZone
    for i, row in ipairs(win.rows) do
        local r = rows[i + win.offset]
        for c = 1, #COLS do row.cells[c]:SetText("") end
        if r then
            local zone = r[1]
            row.cells[1]:SetText(zone ~= prevZone and zone or "")
            prevZone = zone
            row.cells[2]:SetText(r[2])
            row.cells[3]:SetText(r[3] and ("%.1f"):format(r[3]) or "-")
            row.cells[4]:SetText(Num(r[4]))
            row.cells[5]:SetText(r[5] > 0 and Num(r[5]) or "-")
            row.cells[6]:SetText((r[4] > 0 and r[5] > 0) and Num(r[5] / r[4]) or "-")
            row.cells[7]:SetText(r[6] > 0 and Money(r[6]) or "-")
        end
    end
    win.total[1]:SetText(#rows == 0 and "|cff999999No kills in this session yet.|r" or "Total")
    win.total[2]:SetText(#rows > 0 and ("%d NPC types"):format(#rows) or "")
    win.total[4]:SetText(#rows > 0 and Num(t.k) or "")
    win.total[5]:SetText(t.xp > 0 and Num(t.xp) or "")
    win.total[6]:SetText((t.k > 0 and t.xp > 0) and Num(t.xp / t.k) or "")
    win.total[7]:SetText(t.money > 0 and Money(t.money) or "")
    win.sub:SetText(#rows > ROWS and ("scroll for more (%d-%d of %d)"):format(win.offset + 1, math.min(#rows, win.offset + ROWS), #rows)
        or "this session (reset with the live tracker)")
end

function mod.ToggleSessionKills()
    Build()
    if win:IsShown() then win:Hide() else win:Show() mod.RedrawSessionKills() end
end
