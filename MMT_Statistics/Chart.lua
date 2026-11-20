-- MMT Statistics: a small line chart (gold over the last 60 days).
--   chart = mod.CreateChart(parent, width, height)
--   chart:SetData({ {label, value|nil}, ... }, format)   value nil = no data
-- Lines are drawn with Frame:CreateLine; hovering shows the day's value.
-- The y axis has round steps in whole gold ("9.5k g", "10k g"); the left
-- margin follows the widest label, so no label crosses the chart's border.

local _, mod = ...
local MMT = MMT
local UI = MMT.UI
local A = UI.ACCENT

local PAD_L, PAD_R, PAD_T, PAD_B = 40, 10, 10, 18   -- PAD_L = the least left margin
local GOLD = 10000

-- the smallest 1 / 2 / 2.5 / 5 x 10^n gold step of at least `raw` copper,
-- never below 1 gold and always whole gold
local function NiceStep(raw)
    local g = math.max(1, raw / GOLD)
    local p = 10 ^ math.floor(math.log10(g))
    for _, m in ipairs({ 1, 2, 2.5, 5, 10 }) do
        local s = m * p
        if s >= g - 1e-9 and s == math.floor(s) then return s * GOLD end
    end
    return 10 * p * GOLD
end

-- "1234567.5" -> "1,234,567.5"
local function Group(text)
    local int, rest = text:match("^(%d+)(.*)$")
    if not int then return text end
    local sep = LARGE_NUMBER_SEPARATOR
    if type(sep) ~= "string" or sep == "" then sep = "," end
    int = int:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
    if int:sub(1, #sep) == sep then int = int:sub(#sep + 1) end
    return int .. rest
end

-- axis for values lo..hi (copper): bottom, top, step (copper) and the label
-- function. One unit for every label: g below 10,000 gold, then k, then M.
function mod.ChartAxis(lo, hi)
    local least = math.max(GOLD, hi * 0.05)   -- a flat line still gets a scale
    if hi - lo < least then
        local mid = (lo + hi) / 2
        lo, hi = math.max(0, mid - least / 2), math.max(mid + least / 2, least)
    else   -- a little room above and below
        local pad = (hi - lo) * 0.02
        lo, hi = math.max(0, lo - pad), hi + pad
    end
    local step = NiceStep((hi - lo) / 4)
    local bottom, top = math.floor(lo / step) * step, math.ceil(hi / step) * step
    if top <= bottom then top = bottom + step end
    local unit, suffix = 1, "g"
    if top >= 1e6 * GOLD then unit, suffix = 1e6, "M g"
    elseif top >= 1e4 * GOLD then unit, suffix = 1e3, "k g" end
    local s, decimals = step / GOLD / unit, 0
    while decimals < 3 and math.abs(s * 10 ^ decimals - math.floor(s * 10 ^ decimals + 0.5)) > 1e-6 do
        decimals = decimals + 1
    end
    local fmt = "%." .. decimals .. "f"
    local function label(v)
        if v < 1 then return "0g" end
        local text = fmt:format(v / GOLD / unit)
        if decimals > 0 then text = text:gsub("0+$", ""):gsub("%.$", "") end   -- "10.0" -> "10"
        return Group(text) .. suffix
    end
    return bottom, top, step, label
end

function mod.CreateChart(parent, width, height)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(width, height)
    UI.Fill(c, 1, 1, 1, 0.025)
    UI.Border(c, 1, 1, 1, 0.08)
    c.padL = PAD_L
    c.plotW, c.plotH = width - PAD_L - PAD_R, height - PAD_T - PAD_B

    -- grid lines and axis labels: one per step, made when needed
    c.grid, c.yLabels = {}, {}
    local function Grid(i)
        if not c.grid[i] then
            local g = c:CreateTexture(nil, "BORDER")
            g:SetColorTexture(1, 1, 1, 0.06)
            g:SetHeight(1)
            c.grid[i] = g
            local l = UI.Label(c, "")
            l:SetTextColor(0.6, 0.6, 0.6)
            c.yLabels[i] = l
        end
        return c.grid[i], c.yLabels[i]
    end
    -- day labels under the chart: the first, the last and every 5th day between
    c.xLabels = {}
    local function XLabel(i)
        local l = c.xLabels[i]
        if not l then
            l = UI.Label(c, "", "GameFontNormalSmall")
            l:SetTextColor(0.6, 0.6, 0.6)
            c.xLabels[i] = l
        end
        return l
    end
    -- kept for code that still clears them
    c.xFirst = { SetText = function() end, ClearAllPoints = function() end, SetPoint = function() end }
    c.xLast = c.xFirst
    function c:DrawDayLabels(points)
        for _, l in ipairs(self.xLabels) do l:Hide() end
        local n = points and #points or 0
        if n == 0 then return end
        local k = 0
        for i = 1, n do
            local edge = i == 1 or i == n
            local every = (i - 1) % 5 == 0 and i > 1 and n - i >= 3   -- not too close to the last one
            if edge or every then
                k = k + 1
                local l = XLabel(k)
                l:SetText(tostring(points[i][1]):sub(6))
                local x = self.padL + (n > 1 and (i - 1) / (n - 1) or 0.5) * self.plotW
                l:ClearAllPoints()
                if i == 1 then l:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", self.padL, 3)
                elseif i == n then l:SetPoint("BOTTOMRIGHT", self, "BOTTOMLEFT", self.padL + self.plotW, 3)
                else l:SetPoint("BOTTOM", self, "BOTTOMLEFT", x, 3) end
                l:Show()
            end
        end
    end
    c.empty = UI.Label(c, "No gold recorded yet.")
    c.empty:SetPoint("CENTER")
    c.empty:SetTextColor(0.5, 0.5, 0.5)

    c.lines, c.dots = {}, {}
    -- a dot on every day with data (a single day has no line to draw)
    local function Dot(i)
        local d = c.dots[i]
        if not d then
            d = c:CreateTexture(nil, "ARTWORK")
            d:SetSize(4, 4)
            d:SetColorTexture(A[1], A[2], A[3], 1)
            c.dots[i] = d
        end
        return d
    end
    local function Line(i)
        local l = c.lines[i]
        if not l then
            local ok, line = pcall(function() return c.CreateLine and c:CreateLine(nil, "ARTWORK") end)
            if ok and line and line.SetStartPoint then
                l = line
                l:SetThickness(2)
            else   -- no lines on this client: small dots instead
                l = c:CreateTexture(nil, "ARTWORK")
                l:SetSize(3, 3)
            end
            l:SetColorTexture(A[1], A[2], A[3], 1)
            c.lines[i] = l
        end
        return l
    end

    -- hover marker
    c.marker = c:CreateTexture(nil, "OVERLAY")
    c.marker:SetColorTexture(1, 1, 1, 0.25)
    c.marker:SetWidth(1)
    c.marker:SetHeight(c.plotH)
    c.marker:Hide()
    c.dot = c:CreateTexture(nil, "OVERLAY")
    c.dot:SetColorTexture(1, 1, 1, 1)
    c.dot:SetSize(5, 5)
    c.dot:Hide()

    local function XY(i, v)
        local n = #c.points
        local x = c.padL + (n > 1 and (i - 1) / (n - 1) or 0.5) * c.plotW
        local y = PAD_B + (c.max > c.min and (v - c.min) / (c.max - c.min) or 0.5) * c.plotH
        return x, y
    end

    function c:SetData(points, format)
        self.points, self.format = points, format
        local lo, hi
        for _, p in ipairs(points) do
            local v = p[2]
            if v then lo = math.min(lo or v, v); hi = math.max(hi or v, v) end
        end
        for _, l in ipairs(self.lines) do l:Hide() end
        for _, d in ipairs(self.dots) do d:Hide() end
        self.empty:SetShown(lo == nil)
        if not lo then
            for i, g in ipairs(self.grid) do g:Hide(); self.yLabels[i]:Hide() end
            self:DrawDayLabels(nil)
            return
        end
        -- round steps; the left margin is as wide as the widest label needs
        local step, label
        self.min, self.max, step, label = mod.ChartAxis(lo, hi)
        local n = math.floor((self.max - self.min) / step + 0.5)
        local widest = 0
        for i = 0, n do
            local _, l = Grid(i + 1)
            l:SetText(label(self.min + step * i))
            widest = math.max(widest, l:GetStringWidth() or 0)
        end
        self.padL = math.max(PAD_L, math.ceil(widest) + 12)
        self.plotW = width - self.padL - PAD_R
        for i, g in ipairs(self.grid) do
            local l = self.yLabels[i]
            g:SetShown(i <= n + 1); l:SetShown(i <= n + 1)
            local y = PAD_B + self.plotH * (i - 1) / n
            g:ClearAllPoints()
            g:SetPoint("LEFT", self, "BOTTOMLEFT", self.padL, y)
            g:SetWidth(self.plotW)
            l:ClearAllPoints()
            l:SetPoint("RIGHT", self, "BOTTOMLEFT", self.padL - 6, y)
        end
        self.xFirst:ClearAllPoints()
        self.xFirst:SetPoint("BOTTOMLEFT", self.padL, 3)
        self:DrawDayLabels(points)   -- the caller trims empty days at the start
        -- one line per pair of neighbouring days with data
        local k, prev = 0, nil
        for i, p in ipairs(points) do
            if p[2] then
                local x, y = XY(i, p[2])
                k = k + 1
                local dot = Dot(k)
                dot:ClearAllPoints()
                dot:SetPoint("CENTER", self, "BOTTOMLEFT", x, y)
                dot:Show()
                local l = Line(k)
                if l.SetStartPoint and prev then
                    l:SetStartPoint("BOTTOMLEFT", self, prev[1], prev[2])
                    l:SetEndPoint("BOTTOMLEFT", self, x, y)
                    l:Show()
                elseif not l.SetStartPoint then
                    l:ClearAllPoints()
                    l:SetPoint("CENTER", self, "BOTTOMLEFT", x, y)
                    l:Show()
                end
                prev = { x, y }
            end
        end
    end

    -- earned (green) / spent (red) per day: thin bars along the bottom, on a
    -- scale of their own (the lower third of the chart)
    c.bars = {}
    local function Bar(i)
        local b = c.bars[i]
        if not b then
            b = c:CreateTexture(nil, "BACKGROUND", nil, 1)
            c.bars[i] = b
        end
        return b
    end
    function c:SetFlows(days, format)
        self.flows, self.flowFormat = days, format
        for _, b in ipairs(self.bars) do b:Hide() end
        if not days then return end
        local most = 0
        for _, d in ipairs(days) do most = math.max(most, d.e or 0, d.s or 0) end
        if most <= 0 then return end
        local n = #days
        local slot = self.plotW / math.max(1, n)
        -- one column per day: earned (green) at the bottom, spent (red) on top of it,
        -- on a scale of their own (the lower third); kept inside the plot
        local w = math.max(1, math.floor(slot * 0.55))
        local most2 = 0
        for _, d in ipairs(days) do most2 = math.max(most2, (d.e or 0) + (d.s or 0)) end
        local k = 0
        for i, d in ipairs(days) do
            local x = self.padL + (n > 1 and (i - 1) / (n - 1) or 0.5) * self.plotW
            x = math.max(self.padL + w / 2, math.min(self.padL + self.plotW - w / 2, x))
            local base = 0
            for _, part in ipairs({ { d.e or 0, 0.35, 0.85, 0.35 }, { d.s or 0, 0.9, 0.35, 0.35 } }) do
                local v = part[1]
                if v > 0 then
                    k = k + 1
                    local b = Bar(k)
                    local h = math.max(1, v / most2 * self.plotH * 0.33)
                    b:SetColorTexture(part[2], part[3], part[4], 0.5)
                    b:SetSize(w, h)
                    b:ClearAllPoints()
                    b:SetPoint("BOTTOM", self, "BOTTOMLEFT", x, PAD_B + base)
                    b:Show()
                    base = base + h
                end
            end
        end
    end

    -- hover: the nearest day with its value
    c:EnableMouse(true)
    c:SetScript("OnUpdate", function(self)
        if not self:IsMouseOver() or not self.points or not self.min then
            if self.marker:IsShown() then self.marker:Hide(); self.dot:Hide(); GameTooltip:Hide() end
            return
        end
        local scale = self:GetEffectiveScale()
        local mx = GetCursorPosition() / scale - self:GetLeft()
        local n = #self.points
        local i = math.floor((mx - self.padL) / math.max(1, self.plotW) * (n - 1) + 1.5)
        i = math.max(1, math.min(n, i))
        if i == self.hover and self.marker:IsShown() then return end
        self.hover = i
        local p = self.points[i]
        local x = XY(i, 0)
        self.marker:ClearAllPoints()
        self.marker:SetPoint("BOTTOM", self, "BOTTOMLEFT", x, PAD_B)
        self.marker:Show()
        if p[2] then
            local _, y = XY(i, p[2])
            self.dot:ClearAllPoints()
            self.dot:SetPoint("CENTER", self, "BOTTOMLEFT", x, y)
            self.dot:Show()
        else
            self.dot:Hide()
        end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetText(p[1])
        GameTooltip:AddLine(p[2] and self.format(p[2]) or "no data", 1, 1, 1)
        local fl = self.flows and self.flows[i]
        if fl and ((fl.e or 0) > 0 or (fl.s or 0) > 0) then
            GameTooltip:AddDoubleLine("Earned", self.flowFormat(fl.e or 0), 0.4, 0.9, 0.4, 1, 1, 1)
            GameTooltip:AddDoubleLine("Spent", self.flowFormat(fl.s or 0), 0.95, 0.4, 0.4, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    return c
end
