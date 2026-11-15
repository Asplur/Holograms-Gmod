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
    Tex:setTextureURL("$basetexture", BASE .. "SnareFlea.jpg")

    local Holos, Legs, Body = {}, {}, {}
    local loaded, idx, allLoaded = 0, 1, false
    local State = "Idle"

    local root = hologram.create(chip():getPos() + Vector(0, 0, FOOT_DROP * SCALE), Angle(0, chip():getAngles().y, 0),
        "models/hunter/blocks/cube025x025x025.mdl", Vector(1))
    root:setNoDraw(true)

    -- model was made facing -Y; turn it to face +X (Gmod forward)
    local function turn(v)
        return Vector(-v.y, v.x, v.z)
    end

    -- where a part sits along the body: head 0, segments 1-6
    local function bodyIndex(name)
        if name == "SnareFlea_Head" then return 0 end
        local n = string.match(name, "Segment_(%d)")
        return n and tonumber(n) or nil
    end

    local function legInfo(name)
        local side, num = string.match(name, "Leg_(%a)(%d)")
        if not side then return nil end
        return side, tonumber(num)
    end

    -- ---------- snake-style following ----------
    local CRAWL_RATE = 7       -- how fast the hump runs down the body
    local WAVE_GAP = 0.9       -- phase gap between neighbouring segments
    local HUMP = 1.8           -- how high each segment lifts
    local TURN_RATE = 140      -- degrees per second the head can turn
    local WEAVE = 25           -- degrees of side-to-side weave while crawling
    local WEAVE_RATE = 2.2     -- how quickly it weaves
    local TRAIL_STEP = 3       -- distance between trail points

    local path = {}            -- where the head has been, newest first
    local heading = root:getAngles().y
    local headX, maxDist = 0, 0
    local lastTick = timer.curtime()

    local function angDiff(a, b)
        return (a - b + 180) % 360 - 180
    end

    -- point on the trail d units behind the head
    local function pathAt(d)
        local acc = 0
        for i = 1, #path - 1 do
            local a, b = path[i], path[i + 1]
            local len = a:getDistance(b)
            if acc + len >= d then
                return a + (b - a) * ((d - acc) / math.max(len, 0.001))
            end
            acc = acc + len
        end
        local last = path[#path]
        local prev = path[#path - 1] or (last + Angle(0, heading, 0):getForward())
        return last + (last - prev):getNormalized() * (d - acc)
    end

    local function trimPath()
        local acc = 0
        for i = 1, #path - 1 do
            acc = acc + path[i]:getDistance(path[i + 1])
            if acc > maxDist + 20 then
                for j = #path, i + 2, -1 do path[j] = nil end
                return
            end
        end
    end

    local function animate(amount, t)
        for _, part in pairs(Body) do
            local d = headX - part.base.x
            local p = pathAt(d)
            local dir = pathAt(math.max(d - 4, 0)) - pathAt(d + 4)
            local yaw = dir:getLength() > 0.01 and dir:getAngle().y or heading
            local phase = t - part.k * WAVE_GAP
            local bob = math.max(math.sin(phase), 0) * HUMP * amount * SCALE
            local pitch = math.cos(phase) * 6 * amount
            local left = -Angle(0, yaw, 0):getRight()
            part.holo:setPos(p + left * part.base.y + Vector(0, 0, part.base.z + bob))
            part.holo:setAngles(Angle(pitch, yaw, 0))
        end
        for _, leg in pairs(Legs) do
            local k = leg.seg and leg.seg.k or 0
            local s = leg.side == "L" and 1 or -1
            local phase = t - k * WAVE_GAP - leg.num * 0.4 + (leg.side == "R" and math.pi or 0)
            local swing = math.sin(phase) * 24 * amount
            local lift = math.max(math.cos(phase), 0) * 22 * amount
            leg.holo:setLocalAngles(Angle(0, swing * s, -lift * s))
        end
    end

    local function tick()
        local now = timer.curtime()
        local dt = math.min(now - lastTick, 0.1)
        lastTick = now
        local t = timer.systime()

        local head = root:localToWorld(Vector(headX, 0, 0))
        local o = owner():getPos()
        local flat = Vector(o.x - head.x, o.y - head.y, 0)
        local walking = flat:getLength() > FOLLOW_DIST

        if walking then
            local want = flat:getAngle().y
            heading = heading + math.clamp(angDiff(want, heading), -TURN_RATE * dt, TURN_RATE * dt)
            local moveYaw = heading + math.sin(t * WEAVE_RATE) * WEAVE
            root:setAngles(Angle(0, moveYaw, 0))
            root:setPos(root:getPos() + Angle(0, moveYaw, 0):getForward() * WALK_SPEED * dt)
            head = root:localToWorld(Vector(headX, 0, 0))
            if head:getDistance(path[1]) > TRAIL_STEP then
                table.insert(path, 1, head)
                trimPath()
            end
        end

        State = walking and "Walking" or "Idle"
        if walking then
            animate(1, t * CRAWL_RATE)
        else
            animate(0.15, t * 2)
        end
    end

    local function startMovement()
        local h = Body["SnareFlea_Head"]
        headX = h and h.base.x or 0
        for _, part in pairs(Body) do
            maxDist = math.max(maxDist, headX - part.base.x)
        end
        maxDist = maxDist + 8
        -- start with a straight trail behind the head
        local head = root:localToWorld(Vector(headX, 0, 0))
        path = {head, head - Angle(0, heading, 0):getForward() * (maxDist + 10)}

        timer.create("FleaTick", 0.03, 0, tick)
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
        elseif bodyIndex(name) then
            local sum, n = Vector(0, 0, 0), 0
            for _, v in ipairs(verts) do
                sum = sum + v.pos
                n = n + 1
            end
            if n > 0 then pivot = sum / n end
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
            if not bodyIndex(name) then holo:setParent(root) end
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
                        local base = (pivot or Vector(0, 0, 0)) * SCALE
                        local k = bodyIndex(name)
                        if k then
                            Body[name] = {holo = holo, k = k, base = base}
                            holo:setPos(root:localToWorld(base))
                            holo:setAngles(root:getAngles())
                        end
                        if side then
                            -- ride on the body part closest to the hip
                            local seg, best = nil, math.huge
                            for _, part in pairs(Body) do
                                local dist = math.abs(part.base.x - base.x)
                                if part.k > 0 and dist < best then best = dist; seg = part end
                            end
                            Legs[name] = {holo = holo, side = side, num = num, base = base, seg = seg}
                            if seg then
                                holo:setParent(seg.holo)
                                holo:setLocalPos(base - seg.base)
                            else
                                holo:setLocalPos(base)
                            end
                        end
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
