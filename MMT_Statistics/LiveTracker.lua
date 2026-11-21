-- MMT Statistics: the live tracker, a small window of its own (option "Show
-- live tracker"): the session (since login or /reload) of the character you
-- play - its length, time on the current level, XP % (rested %, quest % of the
-- quests ready to turn in), and XP, gold and kills
-- in the session and per hour. "Reset" starts a new session in this window
-- only; the statistics themselves are not touched.
-- Redrawn at most once a second after a change, else every 15 seconds.
--
-- With a damage meter of HUF or EllesmereUI loaded, two options make it sit with
-- the meter: liveLook "METER" takes the meter's header band (height, colour, title
-- colour, accent line), background, edge and font, and liveDock ABOVE / BELOW anchors
-- it to a meter window (liveDockWin; LEFT / RIGHT too): above / below it at its width,
-- beside it at its height, following the meter when that is moved, resized or dimmed.
-- liveFill stretches it to line up with the window beside the one it is on (above the
-- right-hand window: up to the top of the left-hand one), so it fills that slot.
-- Dragging it next to a meter window docks it there; dragged away, it is free again. HUF's meter: _G.HUF.db.damageMeter (HUF's public table) and
-- _G.HUF_DamageMeter; EllesmereUI's: _G._EDM_DB.profile.dm, its paint functions
-- (EllesmereUI._ModuleNS.EllesmereUIDamageMeters, so its Style choices carry over) and
-- _G.EllesmereUIDMFrame1. All of it in pcall: anything missing falls back to plain
-- colours / MMT's look.

local _, mod = ...
local MMT = MMT
local M = mod.M

local Safe, IsSecret = MMT.Safe, MMT.IsSecret
local function Plain(v) if v == nil or IsSecret(v) then return nil end return v end
local function Num(f, ...) return tonumber(Plain(Safe(f, ...))) end

local A = { 0.31, 0.70, 1.00 }
local PAD = 4

---------------------------------------------------------------------------
-- The damage meter it can sit with: HUF's (when its meter is on) or EllesmereUI's.
-- Meter() describes it:
--   frames(i)      its window i (HUF_DamageMeter[i] / EllesmereUIDMFrame<i>; nil: not made yet)
--   hdrH, hdr, bg  header band height, its colour and the background's { r, g, b, a }
--   paintHdr / paintBg (optional) the meter's own painters (EllesmereUI: its Style choices)
--   title          title text { r, g, b }; line / border: an accent line under the band /
--                  an edge around the window { r, g, b, a } or nil
--   rowSize, titleSize, Font(fs, size) the meter's font (false: not set)
---------------------------------------------------------------------------
local function HufMeter()
    local H = rawget(_G, "HUF")
    local c = type(H) == "table" and type(H.db) == "table" and H.db.damageMeter
    if type(c) ~= "table" or c.enabled == false then return nil end
    local bg, tc = c.bgColor or { r = 0.04, g = 0.04, b = 0.05 }, c.titleColor or { r = 0.08, g = 0.08, b = 0.09 }
    local ta = (c.titleAlpha or -1) >= 0 and c.titleAlpha or math.min(1, (c.bgAlpha or 0.75) + 0.15)
    local a = type(H.ACCENT) == "table" and H.ACCENT or A
    return {
        kind = "HUF", frames = function(i) return rawget(_G, i == 1 and "HUF_DamageMeter" or ("HUF_DamageMeter" .. i)) end,
        hdrH = c.titleHeight or 20,
        hdr = { tc.r or 0, tc.g or 0, tc.b or 0, ta },
        bg = { bg.r or 0, bg.g or 0, bg.b or 0, c.bgAlpha or 0.75 },
        title = { 1, 1, 1 },
        line = c.titleLine ~= false and { a[1], a[2], a[3], 0.9 } or nil,
        border = c.windowBorder ~= false and { 0.15, 0.15, 0.17, 1 } or nil,
        rowSize = c.fontSize or 12, titleSize = c.titleSize or 11,
        Font = function(fs, size)
            return H.ApplyFont and pcall(H.ApplyFont, fs, c.font, size, c.outline) or false
        end,
    }
end

local function EuiMeter()
    local d = rawget(_G, "_EDM_DB")
    local dm = type(d) == "table" and type(d.profile) == "table" and d.profile.dm
    if type(dm) ~= "table" then return nil end   -- (only made while EllesmereUIDamageMeters is on)
    local eui = rawget(_G, "EllesmereUI")
    local reg = type(eui) == "table" and eui._ModuleNS
    local ns = type(reg) == "table" and reg.EllesmereUIDamageMeters or nil
    local hc = dm.hdrBgColor
    local m = {
        kind = "EUI", frames = function(i) return rawget(_G, "EllesmereUIDMFrame" .. i) end,
        hdrH = dm.hdrHeight or 22,
        hdr = { hc and hc.r or 0x1B / 255, hc and hc.g or 0x1B / 255, hc and hc.b or 0x1B / 255, dm.hdrBgAlpha or 1 },
        bg = { dm.bgR or 0, dm.bgG or 0, dm.bgB or 0, dm.bgAlpha or 0.75 },
        title = { 1, 1, 1 },
        rowSize = dm.fontSize or 11, titleSize = dm.hdrFontSize or 11,
    }
    if ns and ns.DMPaintHeaderBg then m.paintHdr = function(t, c) return pcall(ns.DMPaintHeaderBg, t, c[1], c[2], c[3], c[4]) end end
    if ns and ns.DMPaintWindowBg then m.paintBg = function(t, c) return pcall(ns.DMPaintWindowBg, t, c[1], c[2], c[3], c[4], true, dm.bgTexture) end end
    if dm.hdrTextUseAccent ~= false and ns and ns.DMTitleRGB then
        local ok, r, g, b = pcall(ns.DMTitleRGB)
        if ok and r then m.title = { r, g, b } end
    elseif type(dm.hdrTextColor) == "table" then
        m.title = { dm.hdrTextColor.r or 1, dm.hdrTextColor.g or 1, dm.hdrTextColor.b or 1 }
    end
    m.Font = function(fs, size)
        if type(eui) ~= "table" then return false end
        local ok, path = pcall(eui.GetFontPath, "damageMeters")
        if not ok or type(path) ~= "string" then return false end
        local ok2, flags = pcall(eui.GetFontOutlineFlag, "damageMeters")
        return pcall(fs.SetFont, fs, path, size, (ok2 and type(flags) == "string") and flags or "")
    end
    return m
end

local function Meter() return HufMeter() or EuiMeter() end
local MAX_WINDOWS = 8
-- the meter's windows that are made and shown: { [i] = frame }
local function MeterWindows()
    local m, out = Meter(), {}
    if not m then return out end
    for i = 1, MAX_WINDOWS do
        local w = m.frames(i)
        if w and w.IsShown and w:IsShown() then out[i] = w end
    end
    return out
end
-- the window it docks to (made, even if hidden right now)
local function MeterFrame()
    local m = Meter()
    return m and m.frames(M.db.liveDockWin or 1) or nil
end
function mod.MeterLoaded() return Meter() ~= nil end
local function MeterLook() return M.db.liveLook == "METER" and Meter() or nil end
local SIDES = { ABOVE = true, BELOW = true, LEFT = true, RIGHT = true }
local function DockWanted() return SIDES[M.db.liveDock] == true end
local function Docked() return DockWanted() and MeterFrame() ~= nil end
local function Wide() return M.db.liveDock == "ABOVE" or M.db.liveDock == "BELOW" end   -- the window's width
mod.LiveMeterLook, mod.LiveDocked = MeterLook, Docked

---------------------------------------------------------------------------
-- Session
---------------------------------------------------------------------------
local session = { start = GetTime(), xp = 0 }
local lastLevel, lastXP, lastMax

local function Kills()
    local c = mod.Char()
    return c and c.killTotal or 0
end

local function StartSession()
    session.start = GetTime()
    session.xp = 0
    session.money = Num(GetMoney)
    session.kills = Kills()
    lastLevel, lastXP, lastMax = Num(UnitLevel, "player"), Num(UnitXP, "player"), Num(UnitXPMax, "player")
    if mod.ResetSessionKills then mod.ResetSessionKills() end   -- Session Kill-Details (SessionKills.lua)
end

local function OnXP()
    local L, xp, max = Num(UnitLevel, "player"), Num(UnitXP, "player"), Num(UnitXPMax, "player")
    if not (L and xp and max) then return end
    if lastLevel and lastXP then
        local gain
        if L == lastLevel then gain = xp - lastXP
        elseif L > lastLevel then gain = math.max(0, (lastMax or 0) - lastXP) + xp end
        if gain and gain > 0 then session.xp = session.xp + gain end
    end
    lastLevel, lastXP, lastMax = L, xp, max
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local f, cells, lines

local function Thousands(n)
    local s = tostring(math.floor(math.abs(n) + 0.5))
    s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. s
end

local function Clock(sec)
    sec = math.max(0, math.floor(sec or 0))
    return ("%02d:%02d"):format(math.floor(sec / 3600), math.floor(sec / 60) % 60)
end

local function SignedMoney(copper)
    if copper < 0 then return "-" .. mod.Money(-copper) end
    return mod.Money(copper)
end

-- the rows' font size: the meter's in its look, else ours
local function Size()
    local m = MeterLook()
    if m then return m.rowSize end
    return M.db.liveSize or 10
end

-- title: the header's size in the meter look
local function Font(fs, scale, title)
    local m = MeterLook()
    if m and m.Font(fs, title and m.titleSize or math.floor(Size() * (scale or 1) + 0.5)) then return end
    MMT.ApplyFont(fs, M.db.liveFont or "Friz Quadrata", math.floor((M.db.liveSize or 10) * (scale or 1) + 0.5), "OUTLINE")
end

-- a frame's edges in the tracker's coordinates (frames may have another scale)
local function Box(w)
    local l, r, t, b = w:GetLeft(), w:GetRight(), w:GetTop(), w:GetBottom()
    if not (l and r and t and b) then return nil end
    local k = (w:GetEffectiveScale() or 1) / (f:GetEffectiveScale() or 1)
    return { l = l * k, r = r * k, t = t * k, b = b * k }
end

-- where it was let go: the meter window edge it is closest to (within SNAP px), as
-- side, window index; nil when no window is that close
local SNAP = 30
function mod.LiveSnap()
    if not f then return nil end
    local me = Box(f)
    if not me then return nil end
    local bestD, bestSide, bestWin
    local function Try(d, side, i)
        if d <= SNAP and (not bestD or d < bestD) then bestD, bestSide, bestWin = d, side, i end
    end
    for i, w in pairs(MeterWindows()) do
        local b = Box(w)
        if b then
            local overlapX = math.min(me.r, b.r) - math.max(me.l, b.l) > 10
            local overlapY = math.min(me.t, b.t) - math.max(me.b, b.b) > 10
            if overlapX then
                Try(math.abs(me.b - b.t), "ABOVE", i)
                Try(math.abs(me.t - b.b), "BELOW", i)
            end
            if overlapY then
                Try(math.abs(me.r - b.l), "LEFT", i)
                Try(math.abs(me.l - b.r), "RIGHT", i)
            end
        end
    end
    -- beside a window, with another meter window under the spot it was let go: on top of
    -- that one instead (its width, filled up to the first one's top: the free slot)
    if bestSide == "LEFT" or bestSide == "RIGHT" then
        local under, underTop
        for i, w in pairs(MeterWindows()) do
            local b = i ~= bestWin and Box(w)
            if b and math.min(me.r, b.r) - math.max(me.l, b.l) > 10 and b.t <= me.t + SNAP
                and (not underTop or b.t > underTop) then
                under, underTop = i, b.t
            end
        end
        if under then return "ABOVE", under end
    end
    return bestSide, bestWin
end

local function SavePoint()
    local point, _, relPoint, x, y = f:GetPoint()
    M.db.livePoint = { point, relPoint, math.floor(x + 0.5), math.floor(y + 0.5) }
end

local function Build()
    f = CreateFrame("Frame", "MMTStatsLiveTracker", UIParent)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not M.db.liveLocked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- let go next to a meter window: docked there; anywhere else: free
        local side, win = mod.LiveSnap()
        if side then
            M.db.liveDock, M.db.liveDockWin = side, win
        else
            if DockWanted() then M.db.liveDock = "OFF" end
            SavePoint()
        end
        mod.UpdateLiveTracker()
        if MMT.RefreshConfig then MMT.RefreshConfig() end
    end)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0, 0, 0, 0.6)
    f.hdr = f:CreateTexture(nil, "BACKGROUND", nil, 1)   -- the meter look's header band
    f.hdr:Hide()
    f.line = f:CreateTexture(nil, "BORDER")
    f.line:SetPoint("TOPLEFT"); f.line:SetPoint("TOPRIGHT")
    f.line:SetHeight(1)
    f.line:SetColorTexture(A[1], A[2], A[3], 0.8)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.title:SetText("Live tracker")
    f.title:SetTextColor(A[1], A[2], A[3])
    f.close = CreateFrame("Button", nil, f)
    f.close.text = f.close:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.close.text:SetPoint("CENTER")
    f.close.text:SetText("x")
    f.close.text:SetTextColor(0.6, 0.6, 0.6)
    f.close:SetScript("OnClick", function() M.db.liveTracker = false mod.UpdateLiveTracker() end)
    f.close:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Hide the live tracker")
        GameTooltip:AddLine("Turn it on again under Statistics > Settings.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.close:SetScript("OnLeave", function(self) self.text:SetTextColor(0.6, 0.6, 0.6) GameTooltip:Hide() end)

    -- Session / On this level / XP: label left, value right
    lines = {}
    for i = 1, 3 do
        lines[i] = { l = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), v = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") }
        lines[i].l:SetJustifyH("LEFT")
        lines[i].l:SetTextColor(0.75, 0.75, 0.75)
        lines[i].v:SetJustifyH("RIGHT")
    end
    lines[1].l:SetText("Session")
    lines[2].l:SetText("On this level")
    lines[3].l:SetText("XP")

    -- table: 4 rows (head, XP, Gold, Kills) x 3 columns
    cells = {}
    for r = 1, 4 do
        cells[r] = {}
        for c = 1, 3 do
            local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetJustifyH(c == 1 and "LEFT" or "RIGHT")
            fs:SetWordWrap(false)
            if r == 1 or c == 1 then fs:SetTextColor(0.75, 0.75, 0.75) end
            cells[r][c] = fs
        end
    end
    cells[1][1]:SetText("")
    cells[1][2]:SetText("Session")
    cells[1][3]:SetText("per hour")
    cells[2][1]:SetText("XP")
    cells[3][1]:SetText("Gold")
    cells[4][1]:SetText("Kills")
    f.sep = f:CreateTexture(nil, "BORDER")
    f.sep:SetHeight(1)
    f.sep:SetColorTexture(1, 1, 1, 0.12)

    f.reset = CreateFrame("Button", nil, f)
    f.reset.bg = f.reset:CreateTexture(nil, "BACKGROUND")
    f.reset.bg:SetAllPoints()
    f.reset.bg:SetColorTexture(1, 1, 1, 0.06)
    f.reset.text = f.reset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.reset.text:SetPoint("CENTER")
    f.reset.text:SetText("Reset session")
    f.reset:SetScript("OnClick", function() StartSession() mod.RedrawLiveTracker(true) end)
    f.reset:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(A[1], A[2], A[3], 0.25)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Reset session")
        GameTooltip:AddLine("Starts a new session in this window. The statistics themselves are not changed.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.reset:SetScript("OnLeave", function(self) self.bg:SetColorTexture(1, 1, 1, 0.06) GameTooltip:Hide() end)

    -- Session Kill-Details (SessionKills.lua)
    f.details = CreateFrame("Button", nil, f)
    f.details.bg = f.details:CreateTexture(nil, "BACKGROUND")
    f.details.bg:SetAllPoints()
    f.details.bg:SetColorTexture(1, 1, 1, 0.06)
    f.details.text = f.details:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.details.text:SetPoint("CENTER")
    f.details.text:SetText("Kill details")
    f.details:SetScript("OnClick", function() if mod.ToggleSessionKills then mod.ToggleSessionKills() end end)
    f.details:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(A[1], A[2], A[3], 0.25)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Session Kill-Details")
        GameTooltip:AddLine("Every NPC killed in this session: zone, NPC, average level, kills, XP, XP per kill and money looted. Starts empty with a new session (Reset session, login or reload).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.details:SetScript("OnLeave", function(self) self.bg:SetColorTexture(1, 1, 1, 0.06) GameTooltip:Hide() end)
    f:Hide()
end

-- docked with liveFill: the height that lines it up with the window beside its own
-- (above: up to the highest top of a window beside it; below: down to the lowest bottom;
-- left / right: its window's height); nil = no such window
local function FillHeight()
    if not (M.db.liveFill ~= false and Docked()) then return nil end
    local own = Box(MeterFrame())
    if not own then return nil end
    local side = M.db.liveDock
    if side == "LEFT" or side == "RIGHT" then
        -- its window's height, but never over a meter window below it in its column
        local width = f:GetWidth() or 0
        local l = side == "RIGHT" and own.r + 1 or own.l - 1 - width
        local r = l + width
        local floor = own.b
        for _, w in pairs(MeterWindows()) do
            local b = w ~= MeterFrame() and Box(w)
            if b and math.min(r, b.r) - math.max(l, b.l) > 10 and b.t <= own.t then floor = math.max(floor, b.t + 1) end
        end
        return math.max(0, own.t - floor)
    end
    local best
    for _, w in pairs(MeterWindows()) do
        local b = w ~= MeterFrame() and Box(w)
        -- beside it: no horizontal overlap with its window
        if b and (b.l >= own.r - 2 or b.r <= own.l + 2) then
            if side == "ABOVE" and b.t > own.t + 2 then best = math.max(best or 0, b.t - own.t - 1) end
            if side == "BELOW" and b.b < own.b - 2 then best = math.max(best or 0, own.b - b.b - 1) end
        end
    end
    return best
end
mod.LiveFillHeight = FillHeight

-- an edge around the window (the meter look of HUF's meter)
local function Edges()
    if f.edges then return f.edges end
    f.edges = {}
    for i, pts in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = f:CreateTexture(nil, "BORDER", nil, 2)
        t:SetPoint(pts[1]); t:SetPoint(pts[2])
        if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
        f.edges[i] = t
    end
    return f.edges
end

-- the look: MMT's (black, accent line and title) or the damage meter's
local function Paint()
    local m = MeterLook()
    local hdrH = m and m.hdrH or 0
    f.icon:SetShown(not m)
    f.hdr:SetShown(m and true or false)
    f.bg:ClearAllPoints()
    f.bg:SetPoint("TOPLEFT", 0, -hdrH)
    f.bg:SetPoint("BOTTOMRIGHT")
    if f.edges or (m and m.border) then
        for _, t in ipairs(Edges()) do
            t:SetShown(m and m.border and true or false)
            if m and m.border then t:SetColorTexture(m.border[1], m.border[2], m.border[3], m.border[4]) end
        end
    end
    f.line:ClearAllPoints()
    if not m then
        -- (back from the meter's paint: plain again)
        f.bg:SetVertexColor(1, 1, 1, 1)
        f.bg:SetTexCoord(0, 1, 0, 1)
        f.bg:SetColorTexture(0, 0, 0, 0.6)
        f.line:SetPoint("TOPLEFT"); f.line:SetPoint("TOPRIGHT")
        f.line:SetColorTexture(A[1], A[2], A[3], 0.8)
        f.line:Show()
        f.title:SetTextColor(A[1], A[2], A[3])
        return 0
    end
    f.hdr:ClearAllPoints()
    f.hdr:SetPoint("TOPLEFT"); f.hdr:SetPoint("TOPRIGHT")
    f.hdr:SetHeight(hdrH)
    if not (m.paintHdr and m.paintHdr(f.hdr, m.hdr)) then f.hdr:SetColorTexture(m.hdr[1], m.hdr[2], m.hdr[3], m.hdr[4]) end
    if not (m.paintBg and m.paintBg(f.bg, m.bg)) then f.bg:SetColorTexture(m.bg[1], m.bg[2], m.bg[3], m.bg[4]) end
    -- the accent line under the band (HUF's "titleLine")
    if m.line then
        f.line:SetPoint("TOPLEFT", 0, -(hdrH - 1)); f.line:SetPoint("TOPRIGHT", 0, -(hdrH - 1))
        f.line:SetColorTexture(m.line[1], m.line[2], m.line[3], m.line[4])
    end
    f.line:SetShown(m.line and true or false)
    f.title:SetTextColor(m.title[1], m.title[2], m.title[3])
    return hdrH
end

-- places everything for the font size (and, docked, the meter's width); returns nothing
local laying = false
local DoLayout
local function Layout()
    if laying then return end
    laying = true
    local ok, err = pcall(DoLayout)
    laying = false
    if not ok then
        mod.liveLayoutError = tostring(err)
        if M.Debug then M:Debug("live tracker layout: %s", tostring(err)) end
    end
end
DoLayout = function()
    local size = Size()
    local h = size + 3
    Font(f.title, 1, true)
    for _, ln in ipairs(lines) do Font(ln.l) Font(ln.v) end
    for r = 1, 4 do for c = 1, 3 do Font(cells[r][c]) end end
    Font(f.close.text)
    Font(f.reset.text, 0.9)
    Font(f.details.text, 0.9)
    local hdrH = Paint()

    -- widths from the font size (values change, the window should not jump);
    -- docked: the meter's width, shared out the same way
    local w1, w2, w3 = size * 5, size * 7, size * 7
    local width = PAD * 2 + w1 + w2 + w3
    if Docked() and Wide() then
        local meter = MeterFrame()
        local mw = (meter:GetWidth() or 0) * (meter:GetEffectiveScale() or 1) / (f:GetEffectiveScale() or 1)
        if mw > 40 then
            width = mw
            local inner = width - PAD * 2
            w1 = math.floor(inner * 5 / 19)
            w2 = math.floor(inner * 7 / 19)
            w3 = inner - w1 - w2
        end
    end
    f.icon:SetSize(size + 2, size + 2)
    f.icon:ClearAllPoints()
    f.icon:SetPoint("TOPLEFT", PAD, -PAD)
    f.title:ClearAllPoints()
    f.close:SetSize(h, h)
    f.close:ClearAllPoints()
    local y
    if hdrH > 0 then
        -- the meter's header: title at the left of the band, x at its right
        f.title:SetPoint("LEFT", f, "TOPLEFT", 6, -hdrH / 2)
        f.close:SetPoint("RIGHT", f, "TOPRIGHT", -2, -hdrH / 2)
        y = -hdrH - 4
    else
        f.title:SetPoint("LEFT", f.icon, "RIGHT", 4, 0)
        f.close:SetPoint("TOPRIGHT", -2, -PAD + 2)
        y = -PAD - (size + 2) - 4
    end
    for _, ln in ipairs(lines) do
        ln.l:ClearAllPoints(); ln.v:ClearAllPoints()
        if ln.hidden then
            ln.l:Hide(); ln.v:Hide()
        else
            ln.l:Show(); ln.v:Show()
            ln.l:SetPoint("TOPLEFT", PAD, y)
            ln.v:SetPoint("TOPRIGHT", -PAD, y)
            ln.v:SetWidth(width - PAD * 2 - size * 6)
            y = y - h
        end
    end
    y = y - 3
    for r = 1, 4 do
        local x = PAD
        for c, w in ipairs({ w1, w2, w3 }) do
            local fs = cells[r][c]
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", x, y)
            fs:SetWidth(w)
            x = x + w
        end
        y = y - h
        if r == 1 then
            f.sep:ClearAllPoints()
            f.sep:SetPoint("TOPLEFT", PAD, y + 1)
            f.sep:SetPoint("TOPRIGHT", -PAD, y + 1)
        end
    end
    y = y - 3
    f.reset:ClearAllPoints()
    f.reset:SetPoint("TOPLEFT", PAD, y)
    f.reset:SetPoint("TOPRIGHT", f, "TOP", -1, y)
    f.reset:SetHeight(h + 2)
    f.details:ClearAllPoints()
    f.details:SetPoint("TOPLEFT", f, "TOP", 1, y)
    f.details:SetPoint("TOPRIGHT", -PAD, y)
    f.details:SetHeight(h + 2)
    y = y - (h + 2) - PAD
    local height = math.max(-y, FillHeight() or 0)
    f.fillH = FillHeight()
    if Docked() and Wide() then f:SetHeight(height) else f:SetSize(width, height) end
end

local function MaxLevel()
    local m = GetMaxPlayerLevel and Num(GetMaxPlayerLevel)
    return m or MAX_PLAYER_LEVEL or 60
end

local lastDraw, dirty = 0, false
local hideLevel   -- the "On this level" line was hidden at the last layout

function mod.RedrawLiveTracker(now)
    if not (f and f:IsShown()) then return end
    if not now and GetTime() - lastDraw < 1 then dirty = true return end
    lastDraw, dirty = GetTime(), false
    local elapsed = GetTime() - session.start
    local L = Num(UnitLevel, "player") or 0
    local atMax = L >= MaxLevel()

    -- hide "On this level" at max level (layout changes only then)
    if (atMax and true or false) ~= hideLevel then
        hideLevel = atMax and true or false
        lines[2].hidden = hideLevel
        Layout()
    end

    lines[1].v:SetText(Clock(elapsed))
    local c = mod.Char()
    local rec = c and c.levels and c.levels[L]
    lines[2].v:SetText(rec and Clock(rec.t) or "-")
    local xp, max, rested = Num(UnitXP, "player"), Num(UnitXPMax, "player"), Num(GetXPExhaustion)
    if atMax or not (xp and max) or max <= 0 then
        lines[3].v:SetText("max level")
    else
        local text = ("%.1f%%"):format(xp / max * 100)
        if rested and rested > 0 then text = text .. ("  |cffbf99ff(%d%%)|r"):format(math.floor(rested / max * 100 + 0.5)) end
        -- XP of the quests ready to turn in (the core's sum, LevelUp.lua)
        local qx = MMT.TurnInXP and tonumber(MMT.TurnInXP(MMT.PlayerFull() or "")) or 0
        if qx > 0 then text = text .. ("  |cffffc04dQ %d%%|r"):format(math.floor(qx / max * 100 + 0.5)) end
        lines[3].v:SetText(text)
    end

    local hours = elapsed / 3600
    local function PerHour(v) return elapsed >= 60 and (v / hours) or nil end
    local money = (Num(GetMoney) or 0) - (session.money or Num(GetMoney) or 0)
    local kills = Kills() - (session.kills or Kills())
    local xpH, moneyH, killsH = PerHour(session.xp), PerHour(money), PerHour(kills)
    cells[2][2]:SetText(Thousands(session.xp))
    cells[2][3]:SetText(xpH and Thousands(xpH) or "-")
    cells[3][2]:SetText(SignedMoney(money))
    cells[3][3]:SetText(moneyH and SignedMoney(math.floor(moneyH)) or "-")
    cells[4][2]:SetText(Thousands(kills))
    cells[4][3]:SetText(killsH and ("%.1f"):format(killsH) or "-")
end

-- shown or hidden by the setting (and with the module); placed on the meter when docked
local dockTries
function mod.UpdateLiveTracker()
    local want = M.enabled and M.db.liveTracker and true or false
    if not want then
        if f then f:Hide() end
        return
    end
    if not f then Build() end
    f:ClearAllPoints()
    local meter = Docked() and MeterFrame()
    if meter then
        -- on the meter's window: above / below at its width (both edges anchored), beside it
        -- at its top; moved and resized with it
        local side = M.db.liveDock
        if side == "ABOVE" then
            f:SetPoint("BOTTOMLEFT", meter, "TOPLEFT", 0, 1)
            f:SetPoint("BOTTOMRIGHT", meter, "TOPRIGHT", 0, 1)
        elseif side == "BELOW" then
            f:SetPoint("TOPLEFT", meter, "BOTTOMLEFT", 0, -1)
            f:SetPoint("TOPRIGHT", meter, "BOTTOMRIGHT", 0, -1)
        elseif side == "LEFT" then
            f:SetPoint("TOPRIGHT", meter, "TOPLEFT", -1, 0)
        else
            f:SetPoint("TOPLEFT", meter, "TOPRIGHT", 1, 0)
        end
        if f.followsMeter ~= meter then
            f.followsMeter = meter
            meter:HookScript("OnSizeChanged", function(self) if f:IsShown() and Docked() and MeterFrame() == self then Layout() end end)
            -- HUF dims its windows out of combat: the same for the tracker on it
            hooksecurefunc(meter, "SetAlpha", function(self, a) if Docked() and MeterFrame() == self then f:SetAlpha(a or 1) end end)
        end
        f:SetAlpha(meter:GetAlpha() or 1)
    else
        f:SetAlpha(1)
        local p = M.db.livePoint or { "TOPLEFT", "TOPLEFT", 300, -200 }
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
        -- docking wanted, the meter's window not made yet (EllesmereUI builds it a moment after login)
        if DockWanted() and (dockTries or 0) < 10 then
            dockTries = (dockTries or 0) + 1
            C_Timer.After(3, mod.UpdateLiveTracker)
        end
    end
    hideLevel = nil
    f:Show()
    Layout()
    mod.RedrawLiveTracker(true)
end

local function Changed() mod.RedrawLiveTracker() end
M:On("PLAYER_XP_UPDATE", function(unit)
    if unit and unit ~= "player" then return end
    OnXP()
    Changed()
end)
M:On("PLAYER_LEVEL_UP", Changed)
M:On("PLAYER_MONEY", Changed)
M:On("UPDATE_EXHAUSTION", Changed)
M:Listen("STATUS_CHANGED", Changed)   -- e.g. the turn-in XP changed
-- kills: Kills.lua counts them (no event of its own): the 1 s ticker below catches them
local lastKills
M:On("PLAYER_ENTERING_WORLD", function()
    C_Timer.After(2, function()
        if not session.money then StartSession() end
        mod.UpdateLiveTracker()
    end)
end)

C_Timer.NewTicker(1, function()
    if not (f and f:IsShown()) then return end
    local k = Kills()
    if k ~= lastKills then lastKills = k dirty = true end
    if dirty or GetTime() - lastDraw >= 15 then mod.RedrawLiveTracker(true) end
    -- docked: the window beside it may have moved, been resized or hidden
    if Docked() and FillHeight() ~= f.fillH then Layout() end
end)

local oldEnable, oldDisable, oldProfile = M.OnEnable, M.OnDisable, M.OnProfileChanged
M.OnEnable = function(...)
    if oldEnable then oldEnable(...) end
    C_Timer.After(2, function()
        if not session.money then StartSession() end
        mod.UpdateLiveTracker()
    end)
end
M.OnDisable = function(...)
    if oldDisable then oldDisable(...) end
    mod.UpdateLiveTracker()
end
M.OnProfileChanged = function(...)
    if oldProfile then oldProfile(...) end
    mod.UpdateLiveTracker()
end

-- /mmt debug dump: what the window shows
local oldReport = M.Report
M.Report = function(m, add)
    if oldReport then oldReport(m, add) end
    if not (f and f:IsShown()) then add("  live tracker: off") return end
    local out = {}
    for _, ln in ipairs(lines) do
        if not ln.hidden then out[#out + 1] = tostring(ln.l:GetText()) .. "=" .. tostring(ln.v:GetText()) end
    end
    for r = 2, 4 do
        out[#out + 1] = ("%s=%s/%s per h"):format(tostring(cells[r][1]:GetText()), tostring(cells[r][2]:GetText()), tostring(cells[r][3]:GetText()))
    end
    add(("  live tracker: %s  (look %s%s, dock %s%s)"):format(table.concat(out, "  "), tostring(M.db.liveLook),
        (MeterLook() and (" - " .. Meter().kind)) or (M.db.liveLook == "METER" and " - no HUF / EllesmereUI meter" or ""), tostring(M.db.liveDock) .. " " .. tostring(M.db.liveDockWin or 1) .. (f.fillH and (" fill " .. math.floor(f.fillH)) or ""),
        DockWanted() and not Docked() and " - meter window not found" or "")
        .. (mod.liveLayoutError and ("  layout error: " .. mod.liveLayoutError) or ""))
end

-- HUF's unlock mode moves the live tracker too, docked or not: let go next
-- to a meter window and it docks there, anywhere else it is free (as when
-- dragging it here)
MMT.OnLogin(function()
    if MMT.HUFMover then
        MMT.HUFMover("livetracker", "Live tracker", function() return f end, function()
            local side, win = mod.LiveSnap()
            if side then
                M.db.liveDock, M.db.liveDockWin = side, win
            else
                if DockWanted() then M.db.liveDock = "OFF" end
                SavePoint()
            end
            mod.UpdateLiveTracker()
            if MMT.RefreshConfig then MMT.RefreshConfig() end
        end, nil, "mod:Statistics")
    end
end)
