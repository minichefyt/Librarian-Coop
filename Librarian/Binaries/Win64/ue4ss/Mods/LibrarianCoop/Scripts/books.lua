-- LibrarianCoop book sync.
--
-- Local actions are caught by hooking the game's own functions and written as events to <netDir>\events.out:
--   grab   <bookUid>                         ItemBagComponent:PickUpGameItem (floor, shelf, skills)
--   insert <bookUid> <caseKey> <slot>        BP_BookCase_C:InsertBook (manual and auto shelving)
--   place  <bookUid> x y z pitch yaw roll    a book this player dropped (Cancel / HoldCancel) has settled:
--                                            the game calls SetActorVisible(false) on it, which redraws its
--                                            floor copy (BP_HISM_Manager:UpdateInstance) where its mesh landed
-- The relay delivers the other player's events, in order, to <netDir>\events.in. They are replayed here:
--   grab   -> SetActorVisible(true): the game removes the floor copy and shows the book itself; then
--             DetachActor(): if the book was shelved, the game frees the slot and lowers the counter;
--             main.lua carries it in front of the friend's bean until it is shelved or dropped
--   insert -> the book is picked up and shelved by this player's character through the same ActiveByActor
--             path the game uses, at the same slot, so counters, row checks and saves stay the game's own
--   place  -> the book's mesh is put where it landed for the friend, then SetActorVisible(false) lets the
--             game redraw the floor copy there, exactly as after a local drop
--   tp     -> the host asked everyone to come to them (handled by main.lua)
--
-- Books are keyed by UniqueIDName (identical in every copy). A few bookcases share a UniqueIDName, so cases
-- are keyed by "<uid>@<x>@<y>" with their (static) position.
--
-- Not replayed on purpose: making this player's character pick up a friend's book (ActiveByActor +
-- DropGameItem) caused the game to pick up another book on its own a few seconds later, which echoed back
-- (tested 2026-10-25). DetachActor alone does the un-shelving part without that side effect.

local M = {}

local BOOK_CLASS = "BP_GrabbingBook_C"
local BOOK_BP = "/Game/Librarian/Prop/GrabbingItem/BP_GrabbingBook.BP_GrabbingBook_C"
local CASE_CLASSES = { "BP_BookCase_C", "BP_BookCase_4x5_C", "BP_BookCase_4x16_C", "BP_BookCase_6x16_C" }
local HOOKS = {
    pickup = "/Script/Librarian.ItemBagComponent:PickUpGameItem",
    insert = "/Game/Librarian/Gimmick/G01/Blueprint/BP_BookCase.BP_BookCase_C:InsertBook",
    cancel = BOOK_BP .. ":Cancel",
    holdCancel = BOOK_BP .. ":HoldCancel",
    setVisible = BOOK_BP .. ":SetActorVisible",
}

local log = function(_) end
local outPath, inPath
local outSeq = 0
local inOffset = 0
local lastApplied = 0
local applyingRemote = false
local hooked = false
local nextHookTry = 0
local books, cases = nil, nil       -- uid -> actor, caseKey -> actor
local peerHeld = {}                 -- ordered list of uids the friend carries
local localDropping = {}            -- uid -> true: dropped by this player, waiting to settle
local pendingYield = {}             -- uid -> true: this player picked up a book the host carries; undo next tick
local isHost = false                -- from <netDir>\role.txt (written by the relay); the host wins conflicts
local rolePath
local nextRoleRead = 0
M.stats = { sent = 0, applied = 0, failed = 0, conflicts = 0, lastEvent = "none" }
M.onTp = nil

local function isPooled(actor)
    return actor:GetFullName():find("SL_SpawnActor", 1, true) ~= nil
end

local function caseKey(case)
    local l = case:K2_GetActorLocation()
    return string.format("%s@%d@%d", case.UniqueIDName:ToString(), math.floor(l.X + 0.5), math.floor(l.Y + 0.5))
end

local function buildIndex()
    books, cases = {}, {}
    local nb, nc = 0, 0
    local skipped = 0
    -- skip objects whose id cannot be read (seen once on 2026-10-25: one object in the list had no readable
    -- UniqueIDName, which failed the whole event)
    for _, b in ipairs(FindAllOf(BOOK_CLASS) or {}) do
        local ok = pcall(function()
            if b:IsValid() and not isPooled(b) then
                books[b.UniqueIDName:ToString()] = b
                nb = nb + 1
            end
        end)
        if not ok then skipped = skipped + 1 end
    end
    for _, cls in ipairs(CASE_CLASSES) do
        for _, c in ipairs(FindAllOf(cls) or {}) do
            local ok = pcall(function()
                if c:IsValid() then
                    cases[caseKey(c)] = c
                    nc = nc + 1
                end
            end)
            if not ok then skipped = skipped + 1 end
        end
    end
    log(string.format("book index: %d books, %d cases, %d unreadable skipped", nb, nc, skipped))
end

local function bookByUid(uid)
    if not books then buildIndex() end
    local b = books[uid]
    if b and b:IsValid() then return b end
    buildIndex()   -- level reload or stale handle
    return books[uid]
end

local function caseByKey(key)
    if not cases then buildIndex() end
    local c = cases[key]
    if c and c:IsValid() then return c end
    buildIndex()
    return cases[key]
end

local function emit(line)
    outSeq = outSeq + 1
    local f = io.open(outPath, "a")
    if not f then return end
    f:write(string.format("%d %s\n", outSeq, line))
    f:close()
    M.stats.sent = M.stats.sent + 1
    M.stats.lastEvent = "out " .. line
end

local function removePeerHeld(uid)
    for i, u in ipairs(peerHeld) do
        if u == uid then table.remove(peerHeld, i) return end
    end
end

local function isPeerHeld(uid)
    for _, u in ipairs(peerHeld) do
        if u == uid then return true end
    end
    return false
end

-- is this book in this player's bag (carried by the local player)?
local function inMyBag(pawn, b)
    local found = false
    pcall(function()
        local items = pawn.ItemBagComponent.Items
        local name = b:GetFullName()
        for i = 1, #items do
            if items[i]:GetFullName() == name then found = true return end
        end
    end)
    return found
end

-- give a carried book up: out of the bag, off the hand, shown as an actor (main.lua then carries it on the
-- friend's bean). Tested 2026-10-25 right after a pick-up (50 ms) and after it finished (2 s): bag empties,
-- no spontaneous pick-ups afterwards.
local function yieldBook(pawn, b)
    pawn.ItemBagComponent:DropGameItem(b)
    b:DetachActor()
    b:SetActorVisible(true)
    localDropping[b.UniqueIDName:ToString()] = nil
    M.stats.conflicts = M.stats.conflicts + 1
end

local function isBook(obj)
    return obj and obj:IsValid() and obj:GetClass():GetFName():ToString() == BOOK_CLASS
end

local function hook(name, path, fn)
    local ok, err = pcall(function()
        RegisterHook(path, function(...)
            if applyingRemote then return end
            local okc, errc = pcall(fn, ...)
            if not okc then log(name .. " hook error: " .. tostring(errc)) end
        end)
    end)
    if not ok then log("hook " .. name .. " failed: " .. tostring(err)) end
    return ok
end

local function tryHook()
    local all = true
    all = hook("pickup", HOOKS.pickup, function(_, item)
        local b = item:get()
        if isBook(b) then
            local uid = b.UniqueIDName:ToString()
            localDropping[uid] = nil
            if not isHost and isPeerHeld(uid) then
                -- the host already carries this book: it stays theirs; undo the pick-up next tick, send nothing
                pendingYield[uid] = true
                return
            end
            -- (the host taking a book the friend carries: it is ours now, stop drawing it on their bean;
            --  the friend gives it up when this grab arrives)
            removePeerHeld(uid)
            emit("grab " .. uid)
        end
    end) and all
    all = hook("insert", HOOKS.insert, function(case, slot, item)
        local c, b = case:get(), item:get()
        local uid = b.UniqueIDName:ToString()
        localDropping[uid] = nil
        emit(string.format("insert %s %s %d", uid, caseKey(c), slot:get()))
    end) and all
    local markDrop = function(self)
        if not self then return end   -- seen once on the title screen: the hook fired without an object
        local b = self:get()
        if isBook(b) then localDropping[b.UniqueIDName:ToString()] = true end
    end
    all = hook("cancel", HOOKS.cancel, markDrop) and all
    all = hook("holdCancel", HOOKS.holdCancel, markDrop) and all
    all = hook("setVisible", HOOKS.setVisible, function(self, visible)
        if visible:get() then return end
        local b = self:get()
        if not isBook(b) then return end
        local uid = b.UniqueIDName:ToString()
        if not localDropping[uid] then return end
        localDropping[uid] = nil
        local m = b.SM_Book_1
        local l, r = m:K2_GetComponentLocation(), m:K2_GetComponentRotation()
        emit(string.format("place %s %.1f %.1f %.1f %.1f %.1f %.1f", uid, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll))
    end) and all
    log("hooks registered: " .. tostring(all))
    return all
end

local function applyGrab(pawn, uid)
    local b = bookByUid(uid)
    if not b then return false, "unknown book" end
    if inMyBag(pawn, b) then
        -- both players grabbed it: the host keeps it, the other player gives it up
        if isHost then
            M.stats.conflicts = M.stats.conflicts + 1
            return true, "host keeps it"
        end
        yieldBook(pawn, b)
    end
    pendingYield[uid] = nil
    removePeerHeld(uid)
    table.insert(peerHeld, uid)
    -- the game's own switch from "floor copy" to "book actor"; main.lua moves the mesh to the friend's bean
    b:SetActorHiddenInGame(false)
    b:SetActorVisible(true)
    -- the game's own un-shelve step: for a shelved book it calls GameManager.BookTaken (counter down) and the
    -- shelf's BookDetached (slot freed); for a floor book it is part of the normal pick-up too. It does not touch
    -- this player's bag or character (tested 2026-10-25), unlike replaying the whole pick-up.
    b:DetachActor()
    b:SetActorEnableCollision(false)
    pcall(function() b.SM_Book_1:SetSimulatePhysics(false) end)
    return true
end

-- a friend's insert/place for a book this player holds: only possible after a simultaneous grab.
-- The host keeps the book (the friend's world follows the host's grab); the friend gives it up.
local function resolveHeld(pawn, b)
    if not inMyBag(pawn, b) then return true end
    if isHost then
        M.stats.conflicts = M.stats.conflicts + 1
        return false
    end
    yieldBook(pawn, b)
    return true
end

local function applyPlace(pawn, uid, x, y, z, pitch, yaw, roll)
    local b = bookByUid(uid)
    if not b then return false, "unknown book" end
    if not resolveHeld(pawn, b) then return true, "host keeps it" end
    removePeerHeld(uid)
    b:SetActorHiddenInGame(false)
    b:SetActorEnableCollision(true)
    local m = b.SM_Book_1
    pcall(function() m:SetSimulatePhysics(false) end)
    b:SetActorVisible(true)
    m:K2_SetWorldLocationAndRotation({ X = x, Y = y, Z = z }, { Pitch = pitch, Yaw = yaw, Roll = roll }, false, {}, true)
    b:SetActorVisible(false)    -- the game redraws the floor copy at the mesh's transform
    return true
end

local function applyInsert(pawn, uid, key, slot)
    local b = bookByUid(uid)
    local c = caseByKey(key)
    if not b then return false, "unknown book" end
    if not c then return false, "unknown case " .. key end
    if not resolveHeld(pawn, b) then return true, "host keeps it" end
    removePeerHeld(uid)
    b:SetActorHiddenInGame(false)
    b:SetActorEnableCollision(true)
    -- the game's own path: pick the book up (also takes it off a shelf), then shelve the top bag item at slot
    pawn:ActiveByActor(b)
    c.LookingIdx = slot
    c.InteractIdx = slot
    pawn:ActiveByActor(c)
    return true
end

---------------------------------------------------------------------------------------------------------------
-- Joining mid-game: the joiner asks ("syncreq"); the host sends its whole library ("snapbegin n", n rows,
-- "snapend"); the joiner changes only books whose state differs, a few per tick, using the same game calls as
-- live sync. Rows:  sshelf <uid> <shelfKey> <slot> | sfloor <uid> x y z pitch yaw roll | shost <uid>
-- A floor book's state is its mesh transform (see floorTransform); there is no stored "start position" to
-- compare against, so the host sends every book and the joiner changes only those that differ.
---------------------------------------------------------------------------------------------------------------
local OPS_PER_TICK = 25
local FLOOR_EPS = 2.0      -- cm and degrees: closer than this counts as "same place"
local inbox = {}           -- incoming lines not processed yet
local snap = nil           -- snapshot being received
local syncOps = nil        -- planned changes, run a few per tick
local syncDone = 0
local needSync = true      -- a joiner should ask for the library (at game start, and after a connection reset)
local roleKnown = false
M.stats.sync = "none"

-- uid -> { key = shelfKey, slot = n } for every shelved book in this world, read from the BOOK side:
-- a shelved book's AttachedActor is its bookcase (cleared when taken off, dropped or detached) and its
-- TargetTransform is its slot position; the bookcase's SpawnPoints are the slot positions in slot order
-- (checked 2026-10-25: nearest spawn point index == slot, distance 0).
-- Shelves' PlacingBookInfo lists are NOT read: their empty slots hold invalid pointers, and touching them
-- crashed the game inside UE4SS (GetFullName, twice) and once corrupted the heap (GetAddress scan).
local spawnPoints = {}   -- shelfKey -> { {x, y, z}, ... } (static, cached)

local function slotOf(case, key, target)
    local sp = spawnPoints[key]
    if not sp then
        sp = {}
        local arr = case.SpawnPoints
        for i = 1, #arr do
            local l = arr[i]:K2_GetComponentLocation()
            sp[i] = { l.X, l.Y, l.Z }
        end
        spawnPoints[key] = sp
    end
    local best, bestD = nil, 1e18
    for i, p in ipairs(sp) do
        local d = (p[1] - target.X)^2 + (p[2] - target.Y)^2 + (p[3] - target.Z)^2
        if d < bestD then best, bestD = i - 1, d end
    end
    return best
end

local function shelfMap()
    if not books then buildIndex() end
    local map = {}
    for uid, b in pairs(books) do
        pcall(function()
            local c = b.AttachedActor
            if c and c:IsValid() then
                local key = caseKey(c)
                local slot = slotOf(c, key, b.TargetTransform.Translation)
                if slot then map[uid] = { key = key, slot = slot } end
            end
        end)
    end
    return map
end

local function bagUids(pawn)
    local set = {}
    pcall(function()
        local items = pawn.ItemBagComponent.Items
        for i = 1, #items do set[items[i].UniqueIDName:ToString()] = true end
    end)
    return set
end

local function emitMany(lines)
    local f = io.open(outPath, "a")
    if not f then return end
    for _, line in ipairs(lines) do
        outSeq = outSeq + 1
        f:write(string.format("%d %s\n", outSeq, line))
    end
    f:close()
    M.stats.sent = M.stats.sent + #lines
end

-- Where a floor book lies: its mesh. For untouched books and after a real landing the actor sits on the mesh
-- too, but a book placed for a friend (mesh set directly, no physics) keeps its old actor transform, while the
-- mesh and the floor copy drawn from it are right (checked 2026-10-25).
local function floorTransform(b)
    local m = b.SM_Book_1
    return m:K2_GetComponentLocation(), m:K2_GetComponentRotation()
end

-- host: describe every book
local function sendSnapshot(pawn)
    if not books then buildIndex() end
    local shelved, held = shelfMap(), bagUids(pawn)
    local rows = {}
    for uid, b in pairs(books) do
        if b:IsValid() then
            if held[uid] then
                table.insert(rows, "shost " .. uid)
            elseif shelved[uid] then
                table.insert(rows, string.format("sshelf %s %s %d", uid, shelved[uid].key, shelved[uid].slot))
            else
                local l, r = floorTransform(b)
                table.insert(rows, string.format("sfloor %s %.1f %.1f %.1f %.1f %.1f %.1f", uid, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll))
            end
        end
    end
    local out = { "snapbegin " .. #rows }
    for _, row in ipairs(rows) do table.insert(out, row) end
    table.insert(out, "snapend")
    emitMany(out)
    log(string.format("sent library snapshot: %d books", #rows))
    return true
end

local function angleDiff(a, b)
    local d = (a - b) % 360
    if d > 180 then d = 360 - d end
    return d
end

-- joiner: compare the snapshot with this world and plan only the changes
local function planSync(pawn, rows)
    local shelved, held = shelfMap(), bagUids(pawn)
    local ops, giveUp, unshelve, floor, shelve, hostHeld = {}, {}, {}, {}, {}, {}
    local same = 0
    for uid in pairs(held) do table.insert(giveUp, uid) end
    for _, row in ipairs(rows) do
        local kind, rest = row[1], row[2]
        local uid = rest:match("^(%S+)")
        local b = bookByUid(uid)
        if b then
            local cur = shelved[uid]
            if kind == "sshelf" then
                local key, slot = rest:match("^%S+%s+(%S+)%s+(%d+)$")
                slot = tonumber(slot)
                if cur and cur.key == key and cur.slot == slot and not held[uid] then
                    same = same + 1
                else
                    if cur then table.insert(unshelve, uid) end
                    table.insert(shelve, { uid, key, slot })
                end
            elseif kind == "sfloor" then
                local x, y, z, p, yw, r = rest:match("^%S+%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)$")
                x, y, z, p, yw, r = tonumber(x), tonumber(y), tonumber(z), tonumber(p), tonumber(yw), tonumber(r)
                local l, rot = floorTransform(b)
                local near = math.sqrt((l.X - x)^2 + (l.Y - y)^2 + (l.Z - z)^2) < FLOOR_EPS
                    and angleDiff(rot.Pitch, p) < FLOOR_EPS and angleDiff(rot.Yaw, yw) < FLOOR_EPS
                    and angleDiff(rot.Roll, r) < FLOOR_EPS
                if near and not cur and not held[uid] then
                    same = same + 1
                else
                    if cur then table.insert(unshelve, uid) end
                    table.insert(floor, { uid, x, y, z, p, yw, r })
                end
            elseif kind == "shost" then
                if cur then table.insert(unshelve, uid) end
                table.insert(hostHeld, uid)
            end
        end
    end
    -- order matters: empty the hands and free shelf slots before anything is put on a shelf
    for _, uid in ipairs(giveUp) do
        table.insert(ops, function() local b = bookByUid(uid); if b then yieldBook(pawn, b) end return true end)
    end
    for _, uid in ipairs(unshelve) do
        table.insert(ops, function()
            local b = bookByUid(uid)
            if b then b:SetActorVisible(true); b:DetachActor() end
            return true
        end)
    end
    for _, f in ipairs(floor) do
        table.insert(ops, function() return applyPlace(pawn, f[1], f[2], f[3], f[4], f[5], f[6], f[7]) end)
    end
    for _, s in ipairs(shelve) do
        table.insert(ops, function() return applyInsert(pawn, s[1], s[2], s[3]) end)
    end
    for _, uid in ipairs(hostHeld) do
        table.insert(ops, function() return applyGrab(pawn, uid) end)
    end
    log(string.format("library sync plan: %d books already right, give up %d, un-shelve %d, floor %d, shelve %d, host carries %d",
        same, #giveUp, #unshelve, #floor, #shelve, #hostHeld))
    M.stats.sync = string.format("plan same=%d giveUp=%d unshelve=%d floor=%d shelve=%d hostHeld=%d",
        same, #giveUp, #unshelve, #floor, #shelve, #hostHeld)
    return ops
end

local function runSyncOps()
    local n = 0
    while #syncOps > 0 and n < OPS_PER_TICK do
        local op = table.remove(syncOps, 1)
        applyingRemote = true
        local ok, res, err = pcall(op)
        applyingRemote = false
        if not (ok and res) then
            M.stats.failed = M.stats.failed + 1
            log("sync op failed: " .. tostring(err or res))
        end
        syncDone = syncDone + 1
        n = n + 1
    end
    if #syncOps == 0 then
        syncOps = nil
        M.stats.sync = M.stats.sync .. string.format(" -> done (%d changes)", syncDone)
        log("library sync done: " .. syncDone .. " changes")
    end
end

local function readNewLines()
    local f = io.open(inPath, "rb")
    if not f then return {} end
    f:seek("set", inOffset)
    local data = f:read("*a") or ""
    f:close()
    local lines = {}
    local consumed = 0
    for line in data:gmatch("([^\n]*)\n") do
        consumed = consumed + #line + 1
        table.insert(lines, (line:gsub("\r$", "")))
    end
    inOffset = inOffset + consumed   -- a trailing partial line is read again next tick
    return lines
end

function M.init(netDir, logFn)
    log = logFn
    outPath = netDir .. "\\events.out"
    inPath = netDir .. "\\events.in"
    rolePath = netDir .. "\\role.txt"
    -- new game session: start both logs empty
    local f = io.open(outPath, "w"); if f then f:close() end
    os.remove(inPath)
end

-- book actors the friend carries, bottom of the stack first (for main.lua to draw on the bean)
function M.peerHeldBooks()
    local list = {}
    for _, uid in ipairs(peerHeld) do
        local b = books and books[uid]
        if b and b:IsValid() then table.insert(list, b) end
    end
    return list
end

-- one incoming event; returns "wait" when a library sync starts (later events wait until it is applied)
local function handleEvent(pawn, kind, rest)
    -- snapshot rows are collected, then planned as a whole
    if kind == "snapbegin" then
        snap = {}
        M.stats.sync = "receiving " .. rest
        return
    elseif kind == "sshelf" or kind == "sfloor" or kind == "shost" then
        if snap then table.insert(snap, { kind, rest }) end
        return
    elseif kind == "snapend" then
        if not snap then return end
        local okP, ops = pcall(planSync, pawn, snap)
        snap = nil
        if not okP then
            log("library sync plan failed: " .. tostring(ops))
            M.stats.failed = M.stats.failed + 1
            return
        end
        if #ops == 0 then
            M.stats.sync = M.stats.sync .. " -> nothing to change"
            return
        end
        syncOps, syncDone = ops, 0
        return "wait"
    end
    applyingRemote = true
    local ok, res, err = pcall(function()
        if kind == "syncreq" then
            if isHost then return sendSnapshot(pawn) end
            return true, "only the host answers"
        elseif kind == "grab" then
            return applyGrab(pawn, rest)
        elseif kind == "insert" then
            local uid, key, slot = rest:match("^(%S+)%s+(%S+)%s+(%d+)$")
            return applyInsert(pawn, uid, key, tonumber(slot))
        elseif kind == "place" then
            local uid, x, y, z, p, yw, r = rest:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)$")
            return applyPlace(pawn, uid, tonumber(x), tonumber(y), tonumber(z), tonumber(p), tonumber(yw), tonumber(r))
        elseif kind == "tp" then
            if M.onTp then return M.onTp() end
            return false, "no tp handler"
        end
        return false, "unknown event"
    end)
    applyingRemote = false
    if ok and res then
        M.stats.applied = M.stats.applied + 1
    else
        M.stats.failed = M.stats.failed + 1
    end
    M.stats.lastEvent = string.format("in %s %s -> %s %s", kind, rest, tostring(ok and res), tostring(err or res or ""))
    log("event " .. M.stats.lastEvent)
end

-- called every tick on the game thread; peerLive = positions from the friend are arriving
function M.tick(pawn, peerLive)
    if not hooked then
        if os.clock() >= nextHookTry and FindFirstOf("GameManager") then
            hooked = tryHook()
            nextHookTry = os.clock() + 5
        end
    end
    if os.clock() >= nextRoleRead then
        nextRoleRead = os.clock() + 2
        local f = io.open(rolePath, "r")
        if f then
            local r = f:read("*l"); f:close()
            local host = (r == "host")
            if host ~= isHost or not roleKnown then log("role: " .. tostring(r)) end
            isHost = host
            roleKnown = (r == "host" or r == "client")
        end
    end
    -- undo pick-ups of books the host carries (from the pick-up hook)
    for uid in pairs(pendingYield) do
        pendingYield[uid] = nil
        local b = bookByUid(uid)
        if b and inMyBag(pawn, b) and isPeerHeld(uid) then
            applyingRemote = true
            pcall(yieldBook, pawn, b)
            applyingRemote = false
            log("gave back " .. uid .. ": the host carries it")
        end
    end
    for _, line in ipairs(readNewLines()) do
        if line:match("^0 reset") then
            -- the relay started talking to a new (or restarted) friend: numbering starts again at 1,
            -- lines from the old connection that were not applied yet are dropped, a joiner asks again.
            -- (handled here, before the request below: the relay writes this line before the first position)
            inbox, snap, lastApplied = {}, nil, 0
            needSync = true
            log("connection (re)started: event numbering reset")
        else
            table.insert(inbox, line)
        end
    end

    -- a joiner asks the host for the library when its game starts and each time the connection (re)starts
    -- (relay reset). Not when positions merely pause: a brief stall on either side is not a reconnect.
    if needSync and roleKnown and peerLive and hooked and not isHost and not syncOps then
        emit("syncreq")
        needSync = false
        M.stats.sync = "requested"
        log("asked the host for the library")
    end

    if syncOps then
        runSyncOps()
        if syncOps then return end   -- live events wait until the library matches the host's
    end
    while #inbox > 0 do
        local line = table.remove(inbox, 1)
        local seq, kind, rest = line:match("^(%d+)%s+(%S+)%s*(.*)$")
        seq = tonumber(seq)
        if seq and seq > lastApplied then
            lastApplied = seq
            if handleEvent(pawn, kind, rest) == "wait" then return end
        end
    end
end

return M
