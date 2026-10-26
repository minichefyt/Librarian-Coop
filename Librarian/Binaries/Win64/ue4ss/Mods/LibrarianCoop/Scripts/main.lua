-- LibrarianCoop: shows the other player as a puppet.
--
-- Each game runs its own single-player world. Every tick this mod
--   * writes the local player's position to <netDir>\me.state
--   * reads the other player's position from <netDir>\peer.state and moves a puppet there.
-- A relay process (coop_relay.py) carries me.state to the other PC and writes peer.state.
--
-- netDir: COOP_NETDIR environment variable, else a "net" folder next to this mod.

local TICK_MS = 50
local STALE_TICKS = 60          -- hide the puppet after ~3 s without a new peer update
-- The puppet is a "bean": a capsule (cylinder + two spheres) with a dark visor showing where the friend
-- looks, and a name tag above it. Offsets are from the pawn's capsule centre (unreal units, cm).
local CYLINDER = "/Engine/BasicShapes/Cylinder.Cylinder"
local SPHERE = "/Engine/BasicShapes/Sphere.Sphere"
local BEAN_PARTS = {
    { mesh = CYLINDER, loc = { X = 0, Y = 0, Z = 0 },   scale = { X = 0.6, Y = 0.6, Z = 1.0 },  color = "body" },
    { mesh = SPHERE,   loc = { X = 0, Y = 0, Z = 50 },  scale = { X = 0.6, Y = 0.6, Z = 0.6 },  color = "body" },
    { mesh = SPHERE,   loc = { X = 0, Y = 0, Z = -50 }, scale = { X = 0.6, Y = 0.6, Z = 0.6 },  color = "body" },
    { mesh = SPHERE,   loc = { X = 24, Y = 0, Z = 45 }, scale = { X = 0.2, Y = 0.42, Z = 0.2 }, color = "visor" },
}
local COLORS = {
    body = { R = 0.25, G = 0.55, B = 1.0, A = 1.0 },
    visor = { R = 0.03, G = 0.03, B = 0.05, A = 1.0 },
}
local TAG_HEIGHT = 105
local TAG_SIZE = 22

local function modDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*)[\\/]Scripts[\\/]main%.lua$") or "."
end

local netDir = os.getenv("COOP_NETDIR") or (modDir() .. "\\net")
os.execute('if not exist "' .. netDir .. '" mkdir "' .. netDir .. '"')
-- drop the last session's friend position, so no stale puppet appears before the relay connects
os.remove(netDir .. "\\peer.state")
local mePath = netDir .. "\\me.state"
local meTmp = netDir .. "\\me.tmp"
local peerPath = netDir .. "\\peer.state"
local statusPath = netDir .. "\\mod.status"

local function log(msg)
    print("[LibrarianCoop] " .. msg .. "\n")
end

local books = require("books")
books.init(netDir, log)

local seq = 0
local lastPeerSeq = nil
local peerStaleTicks = 0
local puppet = nil
local puppetHidden = true
local summonPending = 0
local knownActors = nil
local spawnAttempts = 0

local function localPawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil, nil end
    for _, pc in ipairs(pcs) do
        if pc:IsValid() then
            local pawn = pc.Pawn
            if pawn and pawn:IsValid() then return pc, pawn end
        end
    end
    return nil, nil
end

local function writeMe(pawn)
    local loc = pawn:K2_GetActorLocation()
    local pc = pawn.Controller
    local yaw, pitch = 0, 0
    if pc and pc:IsValid() then
        local r = pc.ControlRotation
        yaw, pitch = r.Yaw, r.Pitch
    else
        yaw = pawn:K2_GetActorRotation().Yaw
    end
    seq = seq + 1
    local f = io.open(meTmp, "w")
    if not f then return end
    f:write(string.format("%d %.2f %.2f %.2f %.2f %.2f\n", seq, loc.X, loc.Y, loc.Z, yaw, pitch))
    f:close()
    os.remove(mePath)
    os.rename(meTmp, mePath)
end

local function readPeer()
    local f = io.open(peerPath, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if not line then return nil end
    local s, x, y, z, yaw = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
    if not s then return nil end
    return { seq = tonumber(s), x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw) }
end

local function snapshotActors()
    local set = {}
    for _, a in ipairs(FindAllOf("StaticMeshActor") or {}) do
        if a:IsValid() then set[a:GetFullName()] = true end
    end
    return set
end

local nameTag = nil
local peerName = nil
local nextNameRead = 0
local bodyParts = {}
local peerColor = nil
local peerColorLine = nil

local function loadMesh(path)
    local mesh = StaticFindObject(path)
    if not (mesh and mesh:IsValid()) then mesh = LoadAsset(path) end
    return mesh
end

local function identityTransform(loc, scale)
    return { Translation = loc, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = scale or { X = 1, Y = 1, Z = 1 } }
end

-- The packaged game draws engine shapes with the grey grid material, so assign BasicShapeMaterial
-- (which has a "Color" parameter) before tinting.
local SHAPE_MATERIAL = "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"
local function tint(comp, color)
    local ok, err = pcall(function()
        local mat = StaticFindObject(SHAPE_MATERIAL)
        if not (mat and mat:IsValid()) then mat = LoadAsset(SHAPE_MATERIAL) end
        comp:SetMaterial(0, mat)
        local mid = comp:CreateDynamicMaterialInstance(0, mat, FName("None"))
        mid:SetVectorParameterValue(FName("Color"), color)
    end)
    if not ok then log("tint failed: " .. tostring(err)) end
end

local function configurePuppet(actor)
    local root = actor.StaticMeshComponent
    if not (root and root:IsValid()) then
        log("puppet has no StaticMeshComponent")
        return false
    end
    root:SetMobility(2)              -- EComponentMobility::Movable, so attached parts can move
    root:SetCollisionEnabled(0)      -- ECollisionEnabled::NoCollision
    actor:SetActorEnableCollision(false)
    local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
    bodyParts = {}
    for _, part in ipairs(BEAN_PARTS) do
        local ok, err = pcall(function()
            local comp = actor:AddComponentByClass(smcClass, false, identityTransform(part.loc, part.scale), false)
            comp:SetMobility(2)
            comp:SetStaticMesh(loadMesh(part.mesh))
            comp:SetCollisionEnabled(0)
            comp:SetCastShadow(true)
            tint(comp, part.color == "body" and (peerColor or COLORS.body) or COLORS[part.color])
            if part.color == "body" then table.insert(bodyParts, comp) end
        end)
        if not ok then log("bean part failed: " .. tostring(err)) end
    end
    local okT, errT = pcall(function()
        local trcClass = StaticFindObject("/Script/Engine.TextRenderComponent")
        nameTag = actor:AddComponentByClass(trcClass, false, identityTransform({ X = 0, Y = 0, Z = TAG_HEIGHT }), false)
        nameTag:SetMobility(2)
        nameTag:SetHorizontalAlignment(1)    -- EHTA_Center
        nameTag:SetVerticalAlignment(1)      -- EVRTA_TextCenter
        nameTag:SetWorldSize(TAG_SIZE)
        nameTag:SetTextRenderColor({ R = 255, G = 255, B = 255, A = 255 })
        nameTag:K2_SetText(FText(peerName or "Friend"))
    end)
    if not okT then log("name tag failed: " .. tostring(errT)) nameTag = nil end
    actor:SetActorHiddenInGame(true)
    puppetHidden = true
    log("puppet ready: " .. actor:GetFullName())
    return true
end

local function readPeerName()
    local f = io.open(netDir .. "\\peername.txt", "r")
    if not f then return end
    local n = f:read("*l")
    f:close()
    if n and n ~= "" and n ~= peerName then
        peerName = n:sub(1, 16)
        if nameTag and nameTag:IsValid() then
            pcall(function() nameTag:K2_SetText(FText(peerName)) end)
        end
        log("peer name: " .. peerName)
    end
end

-- the friend's bean colour, chosen in their launcher ("r g b", 0-255)
local function readPeerColor()
    local f = io.open(netDir .. "\\peercolor.txt", "r")
    if not f then return end
    local line = f:read("*l")
    f:close()
    if not line or line == peerColorLine then return end
    local r, g, b = line:match("^(%d+)%s+(%d+)%s+(%d+)$")
    if not r then return end
    peerColorLine = line
    peerColor = { R = tonumber(r) / 255, G = tonumber(g) / 255, B = tonumber(b) / 255, A = 1.0 }
    for _, comp in ipairs(bodyParts) do
        if comp:IsValid() then tint(comp, peerColor) end
    end
    log("peer colour: " .. line)
end

-- books the friend carries: a small stack in front of the bean, at chest height
local function carryPeerBooks()
    if not (puppet and puppet:IsValid()) then return end
    local base = puppet:K2_GetActorLocation()
    local rot = puppet:K2_GetActorRotation()
    local yaw = math.rad(rot.Yaw)
    local fx, fy = math.cos(yaw), math.sin(yaw)
    for i, b in ipairs(books.peerHeldBooks()) do
        pcall(function()
            local loc = { X = base.X + fx * 42, Y = base.Y + fy * 42, Z = base.Z + 5 + (i - 1) * 6 }
            b.SM_Book_1:K2_SetWorldLocationAndRotation(loc, { Pitch = 0, Yaw = rot.Yaw + 90, Roll = 0 }, false, {}, true)
        end)
    end
end

-- the host pressed "Teleport everyone to me": stand next to the host's position
books.onTp = function()
    local _, pawn = localPawn()
    local p = readPeer()
    if not (pawn and p) then return false, "no pawn or no host position yet" end
    local yaw = math.rad(p.yaw)
    -- one metre in front of the host, so the bean is in view and nobody spawns inside it
    pawn:K2_SetActorLocation({ X = p.x + math.cos(yaw) * 100, Y = p.y + math.sin(yaw) * 100, Z = p.z + 10 }, false, {}, true)
    log("teleported to host")
    return true
end

-- keep the name tag readable: turn it toward the local camera
local function faceTagToCamera(pc)
    if not (nameTag and nameTag:IsValid()) then return end
    local cam = pc.PlayerCameraManager
    if not (cam and cam:IsValid()) then return end
    local c = cam:GetCameraLocation()
    local t = nameTag:K2_GetComponentLocation()
    local yaw = math.deg(math.atan(c.Y - t.Y, c.X - t.X))
    nameTag:K2_SetWorldRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
end

-- Spawn through the cheat manager's summon (the path that worked for UE4SS on Poppy Playtime),
-- then find the new actor on later ticks.
local function requestPuppet(pc)
    if summonPending > 0 then return end
    if spawnAttempts >= 5 then return end
    spawnAttempts = spawnAttempts + 1
    knownActors = snapshotActors()
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    ksl:ExecuteConsoleCommand(pc, "summon StaticMeshActor", pc)
    summonPending = 20
    log("summon requested (attempt " .. spawnAttempts .. ")")
end

local function adoptPuppet()
    for _, a in ipairs(FindAllOf("StaticMeshActor") or {}) do
        if a:IsValid() and not knownActors[a:GetFullName()] then
            if configurePuppet(a) then
                puppet = a
                summonPending = 0
                return
            end
        end
    end
end

local function movePuppet(p)
    local loc = { X = p.x, Y = p.y, Z = p.z }
    local rot = { Pitch = 0, Yaw = p.yaw, Roll = 0 }
    puppet:K2_SetActorLocationAndRotation(loc, rot, false, {}, true)
    if puppetHidden then
        puppet:SetActorHiddenInGame(false)
        puppetHidden = false
    end
end

local function writeStatus(state, peer)
    local f = io.open(statusPath, "w")
    if not f then return end
    local ploc = "none"
    if puppet and puppet:IsValid() then
        local l = puppet:K2_GetActorLocation()
        ploc = string.format("%.1f %.1f %.1f", l.X, l.Y, l.Z)
    end
    f:write(string.format("time=%d\nstate=%s\nmeSeq=%d\npeerSeq=%s\npeer=%s\npuppet=%s\npuppetHidden=%s\nspawnAttempts=%d\n",
        os.time(), state, seq, tostring(lastPeerSeq),
        peer and string.format("%.1f %.1f %.1f", peer.x, peer.y, peer.z) or "none",
        ploc, tostring(puppetHidden), spawnAttempts))
    f:write(string.format("bookEventsSent=%d\nbookEventsApplied=%d\nbookEventsFailed=%d\nbookConflicts=%d\npeerCarrying=%d\nlibrarySync=%s\nlastBookEvent=%s\n",
        books.stats.sent, books.stats.applied, books.stats.failed, books.stats.conflicts, #books.peerHeldBooks(),
        books.stats.sync, books.stats.lastEvent))
    f:close()
end

local tickCount = 0
local function tick()
    tickCount = tickCount + 1
    local pc, pawn = localPawn()
    if not pawn then
        writeStatus("no-pawn", nil)
        return
    end
    writeMe(pawn)

    if puppet and not puppet:IsValid() then
        log("puppet lost (level change?)")
        puppet = nil
        nameTag = nil
        spawnAttempts = 0
    end

    local peer = readPeer()
    if peer and peer.seq ~= lastPeerSeq then
        lastPeerSeq = peer.seq
        peerStaleTicks = 0
    else
        peerStaleTicks = peerStaleTicks + 1
    end
    local peerLive = peer ~= nil and peerStaleTicks < STALE_TICKS
    books.tick(pawn, peerLive)

    if peerLive and not puppet then
        if summonPending > 0 then
            summonPending = summonPending - 1
            adoptPuppet()
        else
            requestPuppet(pc)
        end
    end

    if os.clock() >= nextNameRead then
        readPeerName()
        readPeerColor()
        nextNameRead = os.clock() + 2
    end

    if puppet then
        if peerLive then
            movePuppet(peer)
            faceTagToCamera(pc)
            carryPeerBooks()
        elseif not puppetHidden then
            puppet:SetActorHiddenInGame(true)
            puppetHidden = true
        end
    end

    if tickCount % 10 == 0 then
        writeStatus(peerLive and "peer-live" or "waiting-for-peer", peer)
    end
end

log("loaded, netDir=" .. netDir)

LoopAsync(TICK_MS, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(tick)
        if not ok then log("error: " .. tostring(err)) end
    end)
    return false
end)
