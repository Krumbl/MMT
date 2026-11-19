-- MMT: Team Invite - invites the team into one group (idea and first version:
-- Phobix, MMT_AutoInvite).
--
-- One invite routine for everything (ns.InviteTeam): the automatic invite
-- after login, a team member coming online, the key binding, "/mmt invite"
-- and middle-click on the Info window.
--
-- Automatic (Team > Team Invite, "Auto-Invite team after X seconds"):
--   1. X seconds after login every client asks who is there: INVQ:<canLead>
--      to the team (guild channel or whisper, as all team messages), and
--      everybody answers INVA:<canLead>. canLead: 1 = not in a group, or its
--      leader / an assistant.
--   2. 3 seconds later each client works out the same inviter from the answers
--      (and the heartbeats: a member who logged in during the delay counts too):
--      the FTL leader when present and able to lead, else the first present
--      member in team order who can lead. Only that client invites.
--   3. The inviter invites the missing online members in team order, then
--      tries again "Invite-Retry count" times, every 10 seconds, for whoever
--      hasn't joined.
-- A member who comes online later runs step 1 itself, so the inviter of that
-- moment invites them.
-- Manual (key binding, /mmt invite, middle-click): the client you press it on
-- invites at once, with the same retries.
-- Only members MMT knows to be online are invited (heartbeat or INVQ / INVA),
-- and never into a full party unless MMT made it a raid.
-- Raid: only with "Allow creation of raid" and more than 5 team members, the
-- full party becomes a raid so the rest can join.

local _, ns = ...

local ASK_WAIT    = 3     -- seconds to collect the answers
local RETRY_GAP   = 10    -- seconds between two passes
local INVITE_GAP  = 0.5   -- seconds between two invites
local PENDING_TTL = 9     -- an invite counts as pending this long
local SEEN_FOR    = 8     -- an INVQ / INVA counts as "present" this long

local stats = { asks = 0, answers = 0, passes = 0, invites = 0, raids = 0, lastInviter = nil }
local seen = {}        -- [key] = { t = GetTime(), lead = true/false }
local invitedAt = {}   -- [key] = GetTime() of our last invite
local generation = 0   -- a new run cancels the passes of the old one
local lastAnswer = 0
local fullNoted = -1   -- the run that already said "the party is full"

local function Cfg() return ns.db and ns.db.invites end

local function CanLead()
    return not IsInGroup() or UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

local function InGroup(key)
    return ns.IsSelf(key) or ns.UnitForMember(key) ~= nil
end

local function TeamSize()
    local n = 0
    for _ in pairs(ns.db.team) do n = n + 1 end
    return n
end

---------------------------------------------------------------------------
-- Inviting
---------------------------------------------------------------------------
-- a full party becomes a raid: only with the option on and more than 5 team members
local function MaybeRaid()
    local cfg = Cfg()
    if not (cfg and cfg.raid) or TeamSize() <= 5 then return end
    if not IsInGroup() or IsInRaid() or not UnitIsGroupLeader("player") then return end
    if (GetNumGroupMembers() or 0) < 5 then return end
    -- only when someone who is really online still has to join (an offline
    -- 6th member must not turn the party into a raid)
    local waiting = false
    for _, key in ipairs(ns.SortedMembers()) do
        if not InGroup(key) and (ns.IsOnline(key) or (seen[key] and GetTime() - seen[key].t < SEEN_FOR)) then
            waiting = true
            break
        end
    end
    if not waiting then return end
    ns.Debug("TEAM INVITE party full, converting to a raid")
    local convert = (C_PartyInfo and C_PartyInfo.ConvertToRaid) or ConvertToRaid
    if convert and pcall(convert) then
        stats.raids = stats.raids + 1
        ns.Print("Team Invite: the party is full, converted to a raid.")
    end
end

local function Online(key)
    return ns.IsOnline(key) or (seen[key] and GetTime() - seen[key].t < SEEN_FOR) and true or false
end

-- the online team members not in the group (and not invited a moment ago), team
-- order; offline ones are never invited (the second list: for the note)
local function Missing()
    local list, offline = {}, {}
    for _, key in ipairs(ns.SortedMembers()) do
        if not InGroup(key) then
            if not Online(key) then
                offline[#offline + 1] = key
            elseif not (invitedAt[key] and GetTime() - invitedAt[key] < PENDING_TTL) then
                list[#list + 1] = key
            end
        end
    end
    return list, offline
end

-- room in the group for one more invite (members + invites still pending)
local function HasRoom()
    if IsInRaid() then return true end
    local n = IsInGroup() and (GetNumGroupMembers() or 1) or 1
    for key, t in pairs(invitedAt) do
        if GetTime() - t < PENDING_TTL and not InGroup(key) then n = n + 1 end
    end
    return n < 5
end

-- one pass, then the retries: left = passes still to come after this one
local function Pass(gen, left, manual)
    if gen ~= generation then return end
    if InCombatLockdown() then
        C_Timer.After(RETRY_GAP, function() Pass(gen, left, manual) end)
        return
    end
    if not CanLead() then
        ns.Print("Team Invite: only the group leader or an assistant can invite.")
        return
    end
    stats.passes = stats.passes + 1
    MaybeRaid()
    local todo, offline = Missing()
    local first = left == math.max(0, math.floor(tonumber(Cfg().retries) or 0))
    if manual and first and #offline > 0 then
        local names = {}
        for _, key in ipairs(offline) do names[#names + 1] = ns.ShownName(key) end
        ns.Print("Team Invite: not inviting %s (offline).", ns.AndList(names))
    end
    if #todo == 0 then
        if manual and first and #offline == 0 then ns.Print("Team Invite: the whole team is in your group already.") end
        ns.Debug("TEAM INVITE pass: nobody online missing (%d retries left)", left)
        return
    end
    local sent = {}
    local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    for i, key in ipairs(todo) do
        C_Timer.After((i - 1) * INVITE_GAP, function()
            if gen ~= generation or InGroup(key) then return end
            -- never invite into a full party (the game may turn it into a raid):
            -- only after MMT made it a raid (option on, more than 5 team members)
            if not HasRoom() then MaybeRaid() end
            if not HasRoom() then
                if fullNoted ~= gen then
                    fullNoted = gen
                    ns.Print("Team Invite: the party is full; %s not invited (\"Allow creation of raid\" is off or the team has 5 members or fewer).", ns.ShownName(key))
                end
                return
            end
            local ok, err = pcall(invite, ns.WhisperTarget(key))
            invitedAt[key] = GetTime()
            stats.invites = stats.invites + 1
            ns.Debug("TEAM INVITE %s -> %s %s", ns.Repr(ns.WhisperTarget(key)), tostring(ok), tostring(err or ""))
            if ok then sent[#sent + 1] = ns.ShownName(key) end
        end)
    end
    C_Timer.After(#todo * INVITE_GAP, function()
        if gen == generation and #sent > 0 then ns.Print("Team Invite: invited %s.", ns.AndList(sent)) end
    end)
    if left > 0 then
        C_Timer.After(#todo * INVITE_GAP + RETRY_GAP, function() Pass(gen, left - 1, manual) end)
    end
end

-- invite the team now from this client (key binding, /mmt invite, middle-click,
-- and the inviter of an automatic run)
function ns.InviteTeam(manual)
    generation = generation + 1
    if manual then wipe(invitedAt) end
    stats.lastInviter = ns.PlayerFull()
    Pass(generation, math.max(0, math.floor(tonumber(Cfg().retries) or 0)), manual)
end
function MMT_InviteTeam() ns.InviteTeam(true) end
BINDING_NAME_MMT_INVITE_TEAM = "Invite the team"

---------------------------------------------------------------------------
-- Automatic: who invites
---------------------------------------------------------------------------
local function Present(key)
    if ns.IsSelf(key) then return true, CanLead() end
    local s = seen[key]
    if s and GetTime() - s.t < SEEN_FOR then return true, s.lead end
    -- online by heartbeat but not asked yet (logged in during the delay): it runs
    -- its own question in a moment; it can lead unless it is in our group as a member
    if ns.IsOnline(key) then
        local unit = ns.UnitForMember(key)
        return true, not unit or (UnitIsGroupLeader(unit) and true or false)
    end
    return false
end

-- the FTL leader when present and able to lead, else the first present member in
-- team order who can lead
function ns.TeamInviter()
    local ftl = ns.db.ftl and ns.db.ftl.enabled and ns.FTLLeader and ns.FTLLeader()
    local ftlKey = ftl and ns.Resolve(ftl)
    if ftlKey then
        local here, lead = Present(ftlKey)
        if here and lead then return ftlKey end
    end
    for _, key in ipairs(ns.SortedMembers()) do
        local here, lead = Present(key)
        if here and lead then return key end
    end
end

local function Decide(gen)
    if gen ~= generation then return end
    local inviter = ns.TeamInviter()
    stats.lastInviter = inviter
    ns.Debug("TEAM INVITE inviter: %s", ns.Repr(inviter))
    if inviter and ns.IsSelf(inviter) then
        generation = generation + 1
        Pass(generation, math.max(0, math.floor(tonumber(Cfg().retries) or 0)), false)
    end
end

-- step 1: ask who is there, decide after ASK_WAIT
local function AutoRun()
    local cfg = Cfg()
    if not (cfg and cfg.auto) or TeamSize() < 2 then return end
    generation = generation + 1
    local gen = generation
    stats.asks = stats.asks + 1
    ns.SendToTeam("INVQ:" .. (CanLead() and "1" or "0"), false, "ALERT")
    C_Timer.After(ASK_WAIT, function() Decide(gen) end)
end
ns.TeamInviteAutoRun = AutoRun   -- (tests)

ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    local q, lead = text:match("^INV([QA]):([01])")
    if not q then return end
    seen[key] = { t = GetTime(), lead = lead == "1" }
    if q == "Q" then
        -- answer once per question round (everybody asks at about the same time)
        if GetTime() - lastAnswer > 1 then
            lastAnswer = GetTime()
            stats.answers = stats.answers + 1
            ns.SendToTeam("INVA:" .. (CanLead() and "1" or "0"), false, "ALERT")
        end
        -- someone came online / logged in: decide again with them (no new question)
        local cfg = Cfg()
        if cfg and cfg.auto then
            generation = generation + 1
            local gen = generation
            C_Timer.After(ASK_WAIT, function() Decide(gen) end)
        end
    end
end)

ns.OnLogin(function()
    local cfg = Cfg()
    -- 1.2.10 had it on with 3 retries: once to the new defaults (off, 1 retry)
    if cfg and not cfg.defaults1211 then
        cfg.defaults1211 = true
        cfg.auto, cfg.retries = false, 1
    end
    if not (cfg and cfg.auto) then return end
    local delay = math.max(0, math.min(120, tonumber(cfg.autoDelay) or 8))
    C_Timer.After(delay, AutoRun)
end)

-- joined: no more pending invite; a party that just became full may need to be a raid
ns.On("GROUP_ROSTER_UPDATE", function()
    for key in pairs(invitedAt) do
        if ns.UnitForMember(key) then invitedAt[key] = nil end
    end
    if stats.lastInviter and ns.IsSelf(stats.lastInviter) and #(Missing()) > 0 then MaybeRaid() end
end)

function ns.TeamInviteReport(add)
    local cfg = Cfg() or {}
    local here = {}
    for key, s in pairs(seen) do
        if GetTime() - s.t < 60 then here[#here + 1] = ("%s%s %ds ago"):format(ns.Repr(key), s.lead and "" or " (can't lead)", math.floor(GetTime() - s.t)) end
    end
    add(("-- Team Invite  auto=%s delay=%s retries=%s raid=%s  asks=%d answers=%d passes=%d invites=%d raids=%d  inviter=%s"):format(
        tostring(cfg.auto), tostring(cfg.autoDelay), tostring(cfg.retries), tostring(cfg.raid),
        stats.asks, stats.answers, stats.passes, stats.invites, stats.raids, ns.Repr(stats.lastInviter)))
    add("  heard from (last minute): " .. (#here > 0 and table.concat(here, ", ") or "-"))
end
