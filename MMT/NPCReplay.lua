-- MMT: NPC Replay - record a talk with an NPC on one character and replay it on
-- the team.
--
-- Recording (Automations > Group-wide > "NPC Replay..."):
--   * key binding "Record an NPC talk", "/mmt record", or the "Rec" button on
--     the NPC window (gossip / quest window).
--   * Pressed with no NPC window open, MMT waits "Pause automation" seconds
--     (default 15) for you to talk to an NPC; MMT's own gossip and quest
--     automation (vendor, flights, bank, dialogs, quest accept / turn in) stays
--     off from the press until the talk is over, so every page is yours.
--   * Pressed on an open NPC window it records from that page on.
--   * Recorded: dialog lines (C_GossipInfo.SelectOption / SelectOptionByIndex),
--     quests picked in the gossip or quest greeting window, Accept, Decline,
--     Complete and the quest reward you took (GetQuestReward).
--   * The talk is over when no NPC window was open for 1.5 s (or "Stop" on the
--     button, or after 2 minutes). The steps then go to the team ("NPCR:").
--
-- Replay: a team member that talks to the same NPC (NPC ID from its GUID, else
-- its name) within 10 minutes walks through the same steps; a member that has
-- that NPC's window open already when the recording arrives starts at once.
-- Steps that don't fit that character (a quest it already has, a dialog line
-- it doesn't see) are skipped. Quest reward: the same choice as recorded
-- (option "Quest reward": same / leave to me); a quest with one reward or none
-- is always turned in. Lines that ask for a confirmation (cost gold) stay
-- yours. Hold Shift (with "Hold Shift to skip automation") to keep a window
-- manual.
--
-- Messages: NPCR:<serialized { npc = id, name = text, steps = { ... } }>

local _, ns = ...

local KEEP_FOR    = 600    -- seconds a received recording waits for its NPC
local END_GRACE   = 1.5    -- seconds without an NPC window: the talk is over
local MAX_RECORD  = 120    -- seconds: a recording ends anyway

local function Cfg() return ns.db and ns.db.npcReplay end

local armedUntil = 0       -- GetTime() until which a press waits for an NPC
local rec                  -- the recording: { npc, name, steps, started }
local recs = {}            -- [npcKey] = { steps, from, t, name }: received
local play                 -- { key, steps, pos }: the replay of this talk
local stats = { recorded = 0, sent = 0, received = 0, replayed = 0, skipped = 0 }

---------------------------------------------------------------------------
-- The NPC you talk to
---------------------------------------------------------------------------
local function Plain(v) if v ~= nil and not ns.IsSecret(v) then return v end end

-- npc ID from the GUID ("Creature-0-xxx-xxx-xxx-<npcID>-xxx"), else nil
local function NPCID()
    local guid = Plain(ns.Safe(UnitGUID, "npc"))
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" or kind == "GameObject" then return tonumber(id) end
end
local function NPCName() return Plain(ns.Safe(UnitName, "npc")) end

-- the key a recording is stored under
local function Key(id, name)
    if id then return "id:" .. id end
    if name then return "name:" .. name end
end
local function CurrentKey() return Key(NPCID(), NPCName()) end

local function Shown(name)
    local f = _G[name]
    return f and f.IsShown and f:IsShown() and true or false
end
local function NPCWindowOpen()
    return Shown("GossipFrame") or Shown("QuestFrame")
end

---------------------------------------------------------------------------
-- Holding MMT's own automation (Core's ns.IsBypassed asks this)
---------------------------------------------------------------------------
function ns.NPCReplayHolds()
    return rec ~= nil or GetTime() < armedUntil
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------
local button = {}   -- the "Rec" buttons on the NPC windows
local function UpdateButtons()
    for _, b in pairs(button) do
        b:SetText(rec and "|cffff4040Stop|r" or (GetTime() < armedUntil and "|cffffd000Rec...|r" or "Rec"))
        b:SetShown(Cfg() and Cfg().enabled and Cfg().button and true or false)
    end
end

local function Report(fmt, ...)
    if Cfg() and Cfg().report then ns.Print("NPC Replay: " .. fmt, ...) end
end

local function Add(step)
    if not rec then return end
    rec.steps[#rec.steps + 1] = step
    ns.Debug("NPC REPLAY recorded %s", ns.Serialize(step))
end

local function StartRecording()
    armedUntil = 0
    rec = { npc = NPCID(), name = NPCName(), steps = {}, started = GetTime() }
    ns.Debug("NPC REPLAY recording at %s (%s)", tostring(rec.name), tostring(rec.npc))
    UpdateButtons()
    C_Timer.After(MAX_RECORD, function()
        if rec and GetTime() - rec.started >= MAX_RECORD - 0.5 then ns.NPCReplayFinish() end
    end)
end

function ns.NPCReplayFinish()
    local r = rec
    rec = nil
    armedUntil = 0
    UpdateButtons()
    if not r then return end
    if #r.steps == 0 then
        Report("nothing recorded at %s.", r.name or "the NPC")
        return
    end
    stats.recorded = stats.recorded + 1
    local others = false
    for key in pairs(ns.db.team) do if not ns.IsSelf(key) then others = true break end end
    if others then
        stats.sent = stats.sent + 1
        ns.SendLong("NPCR:" .. ns.Serialize({ npc = r.npc, name = r.name, steps = r.steps }), nil, "NORMAL")
    end
    Report("recorded %d step%s at %s%s.", #r.steps, #r.steps == 1 and "" or "s", r.name or "the NPC",
        others and ", sent to the team: talk to it with them to replay" or "")
end

-- the key, "/mmt record" and the button
function ns.NPCReplayToggle()
    local cfg = Cfg()
    if not (cfg and cfg.enabled) then ns.Print("NPC Replay is off (Automations > NPC Replay...).") return end
    if rec then ns.NPCReplayFinish() return end
    if NPCWindowOpen() then
        StartRecording()
        Report("recording from this page on. Click \"Stop\" or close the window when done.")
        return
    end
    local secs = math.max(5, math.min(60, tonumber(cfg.armSeconds) or 15))
    armedUntil = GetTime() + secs
    UpdateButtons()
    Report("talk to the NPC within %d seconds; MMT's gossip and quest automation is paused until the talk is over.", secs)
    C_Timer.After(secs + 0.1, function()
        if not rec and armedUntil > 0 and GetTime() >= armedUntil then
            armedUntil = 0
            UpdateButtons()
            Report("no NPC talk, recording cancelled.")
        end
    end)
end
function MMT_NPCRecord() ns.NPCReplayToggle() end
BINDING_NAME_MMT_NPC_RECORD = "Record an NPC talk (NPC Replay)"

-- an NPC window opened: an armed press starts recording
local function WindowOpened()
    if not rec and GetTime() < armedUntil then StartRecording() end
end

-- an NPC window closed: the talk is over when none opens again soon
local function WindowClosed()
    C_Timer.After(END_GRACE, function()
        if NPCWindowOpen() then return end
        if rec then ns.NPCReplayFinish() end
        if play then
            ns.Debug("NPC REPLAY talk over at step %d of %d", play.pos, #play.steps)
            play = nil
        end
    end)
end

-- what the player clicks (hooks: also MMT's own calls, but the automation is
-- held while recording)
local function OptionInfo(field, value)
    for _, opt in ipairs(C_GossipInfo.GetOptions() or {}) do
        if opt[field] == value then return opt end
    end
end
local function GossipQuestTitle(list, questID)
    for _, q in ipairs(list or {}) do
        if q.questID == questID then return Plain(q.title) end
    end
end

local function Hooks()
    if C_GossipInfo then
        if C_GossipInfo.SelectOption then
            hooksecurefunc(C_GossipInfo, "SelectOption", function(id)
                if not rec then return end
                local opt = OptionInfo("gossipOptionID", id)
                Add({ k = "opt", id = id, text = opt and Plain(opt.name) })
            end)
        end
        if C_GossipInfo.SelectOptionByIndex then
            hooksecurefunc(C_GossipInfo, "SelectOptionByIndex", function(index)
                if not rec then return end
                local opt = OptionInfo("orderIndex", index)
                Add({ k = "opt", id = opt and opt.gossipOptionID, i = index, text = opt and Plain(opt.name) })
            end)
        end
        if C_GossipInfo.SelectAvailableQuest then
            hooksecurefunc(C_GossipInfo, "SelectAvailableQuest", function(questID)
                if not rec then return end
                Add({ k = "avail", q = questID, title = GossipQuestTitle(C_GossipInfo.GetAvailableQuests(), questID) })
            end)
        end
        if C_GossipInfo.SelectActiveQuest then
            hooksecurefunc(C_GossipInfo, "SelectActiveQuest", function(questID)
                if not rec then return end
                Add({ k = "active", q = questID, title = GossipQuestTitle(C_GossipInfo.GetActiveQuests(), questID) })
            end)
        end
    end
    -- the old quest greeting (several quests, no gossip): by title
    if SelectAvailableQuest then
        hooksecurefunc("SelectAvailableQuest", function(i)
            if rec then Add({ k = "avail", title = Plain(GetAvailableTitle and GetAvailableTitle(i)) }) end
        end)
    end
    if SelectActiveQuest then
        hooksecurefunc("SelectActiveQuest", function(i)
            if rec then Add({ k = "active", title = Plain(GetActiveTitle and GetActiveTitle(i)) }) end
        end)
    end
    if AcceptQuest then
        hooksecurefunc("AcceptQuest", function()
            if rec then Add({ k = "accept", q = Plain(GetQuestID()) }) end
        end)
    end
    if DeclineQuest then
        hooksecurefunc("DeclineQuest", function()
            if rec then Add({ k = "decline", q = Plain(GetQuestID()) }) end
        end)
    end
    if CompleteQuest then
        hooksecurefunc("CompleteQuest", function()
            if rec then Add({ k = "complete", q = Plain(GetQuestID()) }) end
        end)
    end
    if GetQuestReward then
        hooksecurefunc("GetQuestReward", function(choice)
            if rec then Add({ k = "reward", q = Plain(GetQuestID()), i = tonumber(choice) or 0 }) end
        end)
    end
end

---------------------------------------------------------------------------
-- Replay
---------------------------------------------------------------------------
-- the window each step belongs to
local PAGE = { opt = "GOSSIP", avail = "PICK", active = "PICK", accept = "DETAIL", decline = "DETAIL", complete = "PROGRESS", reward = "COMPLETE" }

-- does the step fit the page; if so, do it (returns true when done)
local function Try(step, page)
    local kind = PAGE[step.k]
    if page == "GOSSIP" then
        if step.k == "opt" then
            local opt = step.id and OptionInfo("gossipOptionID", step.id)
            if not opt and step.text then opt = OptionInfo("name", step.text) end
            if not opt then return false end
            C_GossipInfo.SelectOption(opt.gossipOptionID)
            return true
        elseif kind == "PICK" then
            local list = step.k == "avail" and C_GossipInfo.GetAvailableQuests() or C_GossipInfo.GetActiveQuests()
            for _, q in ipairs(list or {}) do
                if (step.q and q.questID == step.q) or (not step.q and step.title and Plain(q.title) == step.title) then
                    if step.k == "avail" then C_GossipInfo.SelectAvailableQuest(q.questID)
                    else C_GossipInfo.SelectActiveQuest(q.questID) end
                    return true
                end
            end
        end
        return false
    elseif page == "GREETING" then
        if kind ~= "PICK" or not step.title then return false end
        local n = step.k == "avail" and (GetNumAvailableQuests() or 0) or (GetNumActiveQuests() or 0)
        for i = 1, n do
            local title = Plain(step.k == "avail" and GetAvailableTitle(i) or GetActiveTitle(i))
            if title == step.title then
                if step.k == "avail" then SelectAvailableQuest(i) else SelectActiveQuest(i) end
                return true
            end
        end
        return false
    end
    if kind ~= page then return false end
    local here = Plain(GetQuestID())
    if step.q and here and step.q ~= here then return false end
    if page == "DETAIL" then
        if step.k == "decline" then DeclineQuest() else AcceptQuest() end
        return true
    elseif page == "PROGRESS" then
        if not IsQuestCompletable() then return false end
        if GetQuestMoneyToGet and (GetQuestMoneyToGet() or 0) > 0 then   -- never hand over gold
            Report("this quest costs money, left to you.")
            return true
        end
        CompleteQuest()
        return true
    elseif page == "COMPLETE" then
        local n = GetNumQuestChoices() or 0
        if n <= 1 then GetQuestReward(n) return true end
        if Cfg().rewards == "same" and step.i and step.i >= 1 and step.i <= n then
            GetQuestReward(step.i)
            return true
        end
        Report("choose your quest reward (recorded: choice %s).", tostring(step.i))
        return true   -- this step is handled (by you)
    end
    return false
end

-- which steps can stand on a page (a step for another page stops the search)
local function OnPage(step, page)
    local kind = PAGE[step.k]
    if page == "GOSSIP" then return step.k == "opt" or kind == "PICK" end
    if page == "GREETING" then return kind == "PICK" end
    return kind == page
end

-- an NPC page opened: the next step that fits it (true when one was done)
local function Replay(page)
    local cfg = Cfg()
    if not (cfg and cfg.enabled) or rec or ns.IsBypassed() then return false end
    local key = CurrentKey()
    local r = key and recs[key]
    if r and GetTime() - r.t > KEEP_FOR then recs[key], r = nil, nil end
    if not r then return false end
    if not play or play.key ~= key then
        play = { key = key, steps = r.steps, pos = 1 }
        stats.replayed = stats.replayed + 1
        Report("replaying %s's talk with %s (%d step%s).", ns.ShownName(r.from), r.name or "the NPC", #r.steps, #r.steps == 1 and "" or "s")
    end
    for j = play.pos, #play.steps do
        local step = play.steps[j]
        if not OnPage(step, page) then break end
        local ok, done = pcall(Try, step, page)
        if ok and done then
            ns.Debug("NPC REPLAY step %d/%d on %s: %s", j, #play.steps, page, step.k)
            play.pos = j + 1
            return true
        end
        if not ok then ns.Debug("NPC REPLAY step %d error: %s", j, tostring(done)) end
        stats.skipped = stats.skipped + 1
        ns.Debug("NPC REPLAY step %d/%d skipped on %s: %s", j, #play.steps, page, step.k)
        play.pos = j + 1
    end
    return false
end

-- a received talk with this NPC still has steps: the Quest Tracker's quest
-- automation leaves the quest pages to the replay
function ns.NPCReplayHas()
    local cfg = Cfg()
    if not (cfg and cfg.enabled) then return false end
    local key = CurrentKey()
    local r = key and recs[key]
    if not r or GetTime() - r.t > KEEP_FOR then return false end
    if play and play.key == key then return play.pos <= #play.steps end
    return true
end

-- gossip: before MMT's own handlers (quests, vendor, dialogs); a page without
-- a fitting step goes on to them
ns.AddGossipHandler(function() return Replay("GOSSIP") end, true)

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    if text:sub(1, 5) ~= "NPCR:" or ns.IsSelf(key) then return end
    local cfg = Cfg()
    if not (cfg and cfg.enabled) then return end
    local ok, data = pcall(ns.Deserialize, text:sub(6))
    if not ok or type(data) ~= "table" or type(data.steps) ~= "table" then return end
    local npcKey = Key(tonumber(data.npc), data.name)
    if not npcKey then return end
    recs[npcKey] = { steps = data.steps, from = key, t = GetTime(), name = data.name }
    stats.received = stats.received + 1
    if play and play.key == npcKey then play = nil end   -- a new recording starts over
    -- that NPC's window is open here: start now
    if NPCWindowOpen() and CurrentKey() == npcKey then
        if Shown("GossipFrame") then Replay("GOSSIP")
        elseif Shown("QuestFrame") then
            local page = (QuestFrameRewardPanel and QuestFrameRewardPanel:IsShown() and "COMPLETE")
                or (QuestFrameProgressPanel and QuestFrameProgressPanel:IsShown() and "PROGRESS")
                or (QuestFrameDetailPanel and QuestFrameDetailPanel:IsShown() and "DETAIL")
                or (QuestFrameGreetingPanel and QuestFrameGreetingPanel:IsShown() and "GREETING")
            if page then Replay(page) end
        end
    else
        Report("%s recorded a talk with %s: talk to it to replay.", ns.ShownName(key), data.name or "an NPC")
    end
end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
ns.On("GOSSIP_SHOW", WindowOpened)   -- (replay: the gossip handler above)
ns.On("QUEST_GREETING", function() WindowOpened() Replay("GREETING") end)
ns.On("QUEST_DETAIL", function() WindowOpened() Replay("DETAIL") end)
ns.On("QUEST_PROGRESS", function() WindowOpened() Replay("PROGRESS") end)
ns.On("QUEST_COMPLETE", function() WindowOpened() Replay("COMPLETE") end)
ns.On("GOSSIP_CLOSED", WindowClosed)
ns.On("QUEST_FINISHED", WindowClosed)

-- the "Rec" button on the gossip and quest windows
local function MakeButton(parentName)
    local parent = _G[parentName]
    if not parent or button[parentName] then return end
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(52, 20)
    b:SetFrameLevel(parent:GetFrameLevel() + 20)
    local close = parent.CloseButton or _G[parentName .. "CloseButton"]
    if close then b:SetPoint("RIGHT", close, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -30, -4) end
    b:SetScript("OnClick", function() ns.NPCReplayToggle() end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("NPC Replay")
        GameTooltip:AddLine(rec and "Stop recording and send the steps to the team."
            or "Record your clicks with this NPC from this page on (dialog lines, quests, rewards). The team replays them when they talk to it. MMT's automation pauses meanwhile.\nTip: the key binding before talking records from the first page.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    button[parentName] = b
end

ns.OnLogin(function()
    if not ns.db.npcReplay then return end
    Hooks()
    MakeButton("GossipFrame")
    MakeButton("QuestFrame")
    UpdateButtons()
end)
ns.OnRefresh(UpdateButtons)

function ns.NPCReplayReport(add)
    local cfg = Cfg() or {}
    local n = 0
    for _ in pairs(recs) do n = n + 1 end
    add(("-- NPC Replay  enabled=%s button=%s pause=%s rewards=%s  recording=%s armed=%s  recorded=%d sent=%d received=%d replays=%d skipped=%d  stored=%d  replaying=%s"):format(
        tostring(cfg.enabled), tostring(cfg.button), tostring(cfg.armSeconds), tostring(cfg.rewards),
        rec and (#rec.steps .. " steps") or "no", tostring(GetTime() < armedUntil),
        stats.recorded, stats.sent, stats.received, stats.replayed, stats.skipped, n,
        play and (play.key .. " step " .. play.pos .. "/" .. #play.steps) or "no"))
end
