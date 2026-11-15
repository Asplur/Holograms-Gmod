--@name Snare Flea
--@author Asplur
--@shared

-- Parts are read from garrysmod/data/sf_filedata/snareflea/<name>.txt on the owner's
-- machine, sent to the server in one stream, then passed on to every player.
local FOLDER = "snareflea/"
local Parts = {
    "SnareFlea_Head",
    "SnareFlea_Segment_1", "SnareFlea_Segment_2", "SnareFlea_Segment_3",
    "SnareFlea_Segment_4", "SnareFlea_Segment_5", "SnareFlea_Segment_6_Tail",
    "SnareFlea_Leg_L1", "SnareFlea_Leg_L2", "SnareFlea_Leg_L3", "SnareFlea_Leg_L4", "SnareFlea_Leg_L5",
    "SnareFlea_Leg_R1", "SnareFlea_Leg_R2", "SnareFlea_Leg_R3", "SnareFlea_Leg_R4", "SnareFlea_Leg_R5",
}

if SERVER then
    local blob

    local function sendBlob(target)
        net.start("flea_data")
        net.writeStream(blob)
        net.send(target)
    end

    -- owner uploads the bundle once
    net.receive("flea_up", function(len, ply)
        if ply ~= owner() or blob then return end
        net.readStream(function(data)
            if not data or blob then return end
            blob = data
            print("Snare flea data received (" .. #blob .. " bytes), sending to players")
            sendBlob(nil)
        end)
    end)

    -- players who join (or load) later ask for it
    net.receive("flea_req", function(len, ply)
        if blob then sendBlob(ply) end
    end)
    return
end

if CLIENT then
    local BASE = "https://raw.githubusercontent.com/Asplur/Holograms-Gmod/refs/heads/main/"
    local SCALE = 1          -- 1 = ~92 units long
    local FOOT_DROP = 10.6   -- distance from model origin down to the feet (unscaled)
    local WALK_SPEED = 120
    local FOLLOW_DIST = 200

    local Tex = material.create("VertexLitGeneric")
    Tex:setTextureURL("$basetexture", BASE .. "SnareFlea.png")

    local Holos, Legs = {}, {}
    local loaded, idx, allLoaded = 0, 1, false
    local State = "Idle"
    local moveDirection = Vector(0, 0, 0)

    local root = hologram.create(chip():getPos() + Vector(0, 0, FOOT_DROP * SCALE), Angle(0, chip():getAngles().y, 0),
        "models/hunter/blocks/cube025x025x025.mdl", Vector(1))
    root:setNoDraw(true)

    -- model was made facing -Y; turn it to face +X (Gmod forward)
    local function turn(v)
        return Vector(-v.y, v.x, v.z)
    end

    local function legInfo(name)
        local side, num = string.match(name, "Leg_(%a)(%d)")
        if not side then return nil end
        return side, tonumber(num)
    end

    local function walkingAnimation()
        local t = timer.systime() * 8
        for name, leg in pairs(Legs) do
            local phase = t - leg.num * 0.9 + (leg.side == "R" and math.pi or 0)
            local swing = math.sin(phase) * 22
            local lift = math.max(math.cos(phase), 0) * 18
            local s = leg.side == "L" and 1 or -1
            leg.holo:setLocalAngles(Angle(0, swing * s, -lift * s))
        end
    end

    local function idleAnimation()
        local t = timer.systime() * 2
        for name, leg in pairs(Legs) do
            local s = leg.side == "L" and 1 or -1
            leg.holo:setLocalAngles(Angle(0, math.sin(t + leg.num) * 2 * s, 0))
        end
    end

    local function updateState()
        local ownerPos = owner():getPos()
        local bodyPos = root:getPos()
        local flat = Vector(ownerPos.x - bodyPos.x, ownerPos.y - bodyPos.y, 0)
        if flat:getLength() > FOLLOW_DIST then
            State = "Walking"
            moveDirection = flat:getNormalized()
            root:setAngles(Angle(0, moveDirection:getAngle().y, 0))
            root:setPos(bodyPos + moveDirection * WALK_SPEED * 0.1)
        else
            State = "Idle"
            moveDirection = Vector(0, 0, 0)
        end
    end

    local function startMovement()
        timer.create("FleaAnim", 0.03, 0, function()
            if State == "Walking" then walkingAnimation() else idleAnimation() end
        end)
        timer.create("FleaState", 0.1, 0, updateState)
        timer.create("FleaGround", 0.1, 0, function()
            local p = root:getPos()
            local tr = trace.line(p + Vector(0, 0, 40), p - Vector(0, 0, 9999), {chip(), owner()})
            if tr.Hit then root:setPos(tr.HitPos + Vector(0, 0, FOOT_DROP * SCALE)) end
        end)
    end

    -- rebuilds a part: turns it to face forward and, for legs, moves the pivot to the hip
    local function buildPart(name, objText)
        local parsed = mesh.parseObj(objText, true, true)
        local verts = parsed[name]
        local pivot = Vector(0, 0, 0)
        local side, num = legInfo(name)
        if side then
            -- hip = the vertex closest to the body centreline
            local best = math.huge
            for _, v in ipairs(verts) do
                local d = math.abs(v.pos.x)
                if d < best then best = d; pivot = v.pos end
            end
            pivot = Vector(pivot.x, pivot.y, pivot.z)
        end
        for i, v in ipairs(verts) do
            v.pos = turn(v.pos - pivot)
            if v.normal then v.normal = turn(v.normal) end
            if i % 400 == 0 then coroutine.yield() end
        end
        local m = mesh.createFromTable(verts, true)
        return m, turn(pivot), side, num
    end

    local function loadAll(objs)
        local function loadNext()
            if idx > #Parts then return end
            local name = Parts[idx]
            local d = objs[name]
            idx = idx + 1
            if not d then
                print("Missing part data: " .. name)
                loaded = loaded + 1
                timer.simple(0, loadNext)
                return
            end
            local holo = hologram.create(root:getPos(), root:getAngles(), "models/hunter/blocks/cube025x025x025.mdl", Vector(SCALE))
            holo:setParent(root)
            Holos[name] = holo
            local m, pivot, side, num
            local done = false
            local step = coroutine.wrap(function()
                m, pivot, side, num = buildPart(name, d)
                done = true
                return true
            end)
            hook.add("think", "load" .. name, function()
                while quotaAverage() < quotaMax() / 2 do
                    if not done then step() end
                    if done then
                        holo:setMesh(m)
                        holo:setMeshMaterial(Tex)
                        holo:setRenderBounds(Vector(-70), Vector(70))
                        holo:setLocalPos((pivot or Vector(0, 0, 0)) * SCALE)
                        holo:setLocalAngles(Angle(0, 0, 0))
                        if side then Legs[name] = {holo = holo, side = side, num = num} end
                        loaded = loaded + 1
                        if loaded == #Parts then
                            print("Snare flea loaded!")
                            allLoaded = true
                            startMovement()
                        end
                        hook.remove("think", "load" .. name)
                        timer.simple(0, loadNext)
                        return
                    end
                end
            end)
        end
        loadNext()
    end

    -- bundle format: name \0 objtext \0 name \0 objtext \0 ...
    local function unpackBlob(blob)
        local objs, pos = {}, 1
        while pos <= #blob do
            local a = string.find(blob, "\0", pos, true)
            if not a then break end
            local b = string.find(blob, "\0", a + 1, true) or (#blob + 1)
            objs[string.sub(blob, pos, a - 1)] = string.sub(blob, a + 1, b - 1)
            pos = b + 1
        end
        return objs
    end

    local started = false
    net.receive("flea_data", function()
        net.readStream(function(blob)
            if started or not blob then return end
            started = true
            loadAll(unpackBlob(blob))
        end)
    end)

    -- owner reads the parts from disk and uploads them
    if player() == owner() then
        local chunks = {}
        for _, name in ipairs(Parts) do
            local d = file.read(FOLDER .. name .. ".txt")
            if d then
                chunks[#chunks + 1] = name .. "\0" .. d
            else
                print("Couldn't read data/sf_filedata/" .. FOLDER .. name .. ".txt")
            end
        end
        if #chunks == 0 then
            print("No snare flea parts found, nothing to send")
        else
            net.start("flea_up")
            net.writeStream(table.concat(chunks, "\0"))
            net.send()
        end
    else
        net.start("flea_req")
        net.send()
    end
end
