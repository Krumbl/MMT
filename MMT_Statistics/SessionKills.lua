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
local mlMoney = {}      -- [zone .. "\t" .. npc] = coins the master looter looted from it (sent by it)
local mlFrom            -- { key, id } of the master looter session those came from
local dirty = {}        -- [zone .. "\t" .. npc] = true: its coins changed since the last send
local function NewId() return ("%x"):format(math.random(0, 0x7fffffff)) end
local sessionId = NewId()
local levelOf = {}      -- [npc name] = level seen last
local guidName = {}     -- [guid] = npc name (kills of this session)
local lastKill          -- { zone, name, t } of the last kill
local lastNamed         -- the same, the last kill with a real name
local lootSources       -- { { name, zone, share } } of the open loot window
local deathLevels = {}  -- { { t, lvl, used } }: the level of targets as they died (names may be hidden)
local unknownLevels = {} -- { { t, lvl } }: levels counted for unknown NPCs (moved on a rename)
local LEVEL_FOR = 8     -- seconds a target's death level waits for its kill (Kills.lua PAIR)

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

-- from Kills.lua: the target died; its level is read right away (the XP line
-- naming it can come seconds later, when another NPC is targeted)
function mod.SessionTargetDied()
    local l = Safe(UnitLevel, "target")
    local now = GetTime()
    for i = #deathLevels, 1, -1 do
        if now - deathLevels[i].t > LEVEL_FOR then table.remove(deathLevels, i) end
    end
    if l and l > 0 then deathLevels[#deathLevels + 1] = { t = now, lvl = l } end
    M:Debug("session: target died, level %s", l and tostring(l) or "not readable")
end

local function OldestDeathLevel()
    local now = GetTime()
    for _, d in ipairs(deathLevels) do
        if not d.used and now - d.t <= LEVEL_FOR then d.used = true return d.lvl end
    end
end

-- level, and where it came from (for the debug log)
local function LevelNow(name, guid)
    for _, unit in ipairs({ "target", "mouseover", "focus" }) do
        if guid and Safe(UnitGUID, unit) == guid or (not guid and Safe(UnitName, unit) == name) then
            local l = Safe(UnitLevel, unit)
            if l and l > 0 then return l, unit end
        end
    end
    if levelOf[name] then return levelOf[name], "seen before" end
    -- instances hide names and GUIDs: the level of a target that died a moment ago
    local d = OldestDeathLevel()
    if d then return d, "target death" end
    -- the dead NPC you have targeted
    if Safe(UnitExists, "target") and Safe(UnitIsDead, "target") and not Safe(UnitIsPlayer, "target") then
        local l = Safe(UnitLevel, "target")
        if l and l > 0 then return l, "dead target" end
    end
end

-- from Kills.lua
function mod.SessionKill(name, guid, carried)
    if not name then return end
    local zone = Zone()
    local e = Entry(zone, name)
    e.k = e.k + 1
    local lvl, from = LevelNow(name, guid)
    if not lvl and carried then lvl, from = carried, "unknown NPC before" end
    if lvl then e.lvlSum = e.lvlSum + lvl; e.lvlN = e.lvlN + 1 end
    if name == mod.UNKNOWN_NPC then unknownLevels[#unknownLevels + 1] = { t = GetTime(), lvl = lvl } end
    M:Debug("session: %s in %s, level %s (%s)%s", name, zone, tostring(lvl), from or "not found",
        lvl and "" or (" target: name %s, level %s, dead %s"):format(tostring(Safe(UnitName, "target") ~= nil),
            tostring(Safe(UnitLevel, "target")), tostring(Safe(UnitIsDead, "target"))))
    if guid then guidName[guid] = name end
    lastKill = { zone = zone, name = name, t = GetTime() }
    if name ~= mod.UNKNOWN_NPC then lastNamed = lastKill end
    if mod.RedrawSessionKills then mod.RedrawSessionKills() end
end

function mod.SessionRename(old, new, guid)
    local zone = Zone()
    local z = data[zone]
    local from = z and z[old]
    local carried
    if from and from.k > 0 then
        from.k = from.k - 1
        -- its level goes with it
        local u = table.remove(unknownLevels, 1)
        if u and u.lvl and from.lvlN > 0 then
            from.lvlSum, from.lvlN = from.lvlSum - u.lvl, from.lvlN - 1
            carried = u.lvl
        end
        if from.money > 0 then dirty[zone .. "\t" .. old] = true end
        if from.k <= 0 and from.xp == 0 and from.money == 0 then z[old] = nil end
    end
    mod.SessionKill(new, guid, carried)
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
        -- the corpse can't be told (instances hide it): the last named kill of the
        -- last half minute, else the last kill
        local k = (lastNamed and GetTime() - lastNamed.t < 30) and lastNamed or lastKill
        if not k then return end
        list = { { name = k.name, zone = k.zone, share = 0 } }
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
        dirty[s.zone .. "\t" .. s.name] = true
    end
    if mod.RedrawSessionKills then mod.RedrawSessionKills() end
end

-- a new session (live tracker "Reset session"; login / reload start empty anyway)
function mod.ResetSessionKills()
    wipe(data)
    wipe(guidName)
    wipe(deathLevels)
    wipe(unknownLevels)
    lastKill, lastNamed, lootSources = nil, nil, nil
    wipe(mlMoney)
    mlFrom = nil
    sessionId = NewId()
    dirty = {}
    if mod.RedrawSessionKills then mod.RedrawSessionKills() end
end

-- { { zone, name, avgLvl|nil, k, xp, money } } sorted: zone, then kills. The
-- money is what this character looted, or what the master looter sent for the
-- NPC when that is more.
function mod.SessionKillRows()
    local rows = {}
    for zone, npcs in pairs(data) do
        for name, e in pairs(npcs) do
            local money = math.max(e.money, mlMoney[zone .. "\t" .. name] or 0)
            rows[#rows + 1] = { zone, name, e.lvlN > 0 and e.lvlSum / e.lvlN or nil, e.k, e.xp, money }
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

---------------------------------------------------------------------------
-- Money from the master looter: with Master Looter only the master looter
-- loots the coins, so it sends what it looted per NPC (rows whose coins
-- changed, out of combat, a few seconds later). The others fill in their own
-- rows' money with it. Kills, XP and levels stay each character's own.
--   SKM:<packed { id = session id, rows = { { zone, npc, copper } } }>
---------------------------------------------------------------------------
local function LootMethod()
    if C_PartyInfo and C_PartyInfo.GetLootMethod then
        local ok, m, party, raid = pcall(C_PartyInfo.GetLootMethod)
        if ok then
            m = Plain(m)
            if type(m) == "number" then
                m = (Enum and Enum.LootMethod and m == Enum.LootMethod.Masterlooter) and "master" or tostring(m)
            end
            return m, Plain(party), Plain(raid)
        end
    end
    if type(GetLootMethod) == "function" then
        local ok, m, party, raid = pcall(GetLootMethod)
        if ok then return Plain(m), Plain(party), Plain(raid) end
    end
end
local function MasterLoot() return IsInGroup() and LootMethod() == "master" end
-- this character is the master looter
local function IAmMasterLooter()
    if not MasterLoot() then return false end
    local _, party, raid = LootMethod()
    if IsInRaid() then return raid ~= nil and Safe(UnitIsUnit, "raid" .. raid, "player") or false end
    return party == 0
end
mod.SessionMasterLoot, mod.SessionIAmMasterLooter = MasterLoot, IAmMasterLooter

local syncSoon = false
local syncStats = { sent = 0, received = 0 }
local function Sync()
    syncSoon = false
    if not next(dirty) then return end
    if not IAmMasterLooter() then dirty = {} return end   -- only the master looter's coins are shared
    if InCombatLockdown() then return end   -- PLAYER_REGEN_ENABLED tries again
    local rows = {}
    for key in pairs(dirty) do
        local zone, name = key:match("^(.-)\t(.*)$")
        local e = zone and data[zone] and data[zone][name]
        if zone then rows[#rows + 1] = { zone, name, e and e.money or 0 } end
    end
    dirty = {}
    syncStats.sent = syncStats.sent + 1
    MMT.SendLong("SKM:" .. MMT.Pack(MMT.Serialize({ id = sessionId, rows = rows })), nil, "BULK")
end
local function SyncSoon()
    if syncSoon then return end
    syncSoon = true
    C_Timer.After(5, Sync)
end
M:On("PLAYER_REGEN_ENABLED", function() if next(dirty) then SyncSoon() end end)

M:Listen("TEAM_MESSAGE", function(key, sender, text)
    local body = text:match("^SKM:(.*)$")
    if not body or MMT.IsSelf(key) or not MasterLoot() then return end
    local plain = MMT.Unpack(body)
    local t = plain and MMT.Deserialize(plain)
    if type(t) ~= "table" or type(t.rows) ~= "table" then return end
    -- another master looter, or a new session there: start over
    if not mlFrom or mlFrom.key ~= key or mlFrom.id ~= t.id then
        wipe(mlMoney)
        mlFrom = { key = key, id = t.id }
    end
    for _, r in ipairs(t.rows) do
        if type(r) == "table" and type(r[1]) == "string" and type(r[2]) == "string" then
            local n = tonumber(r[3]) or 0
            mlMoney[r[1] .. "\t" .. r[2]] = n > 0 and n or nil
        end
    end
    syncStats.received = syncStats.received + 1
    mod.RedrawSessionKills()
end)

function mod.SessionKillsReport(add)
    local n = 0
    for _ in pairs(mlMoney) do n = n + 1 end
    add(("  session kill-details: rows=%d masterLoot=%s iAmML=%s sent=%d received=%d (rows with the master looter's coins: %d, from %s) session=%s"):format(
        #mod.SessionKillRows(), tostring(MasterLoot()), tostring(IAmMasterLooter()), syncStats.sent, syncStats.received, n,
        mlFrom and MMT.Repr(mlFrom.key) or "-", sessionId))
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
    if next(dirty) then SyncSoon() end
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
