-- The frog: a body of ellipsoids painted live (src/tracer.lua's T.paint), and the
-- hops that move it.
--
-- Survive School's lesson, straight across: a pose is *numbers*, not a held
-- picture. The frog has two -- `crouch` (squashed onto the ground before a jump
-- and after a landing) and `stretch` (legs flung out behind it in the air) -- and
-- the picture is asked for its heading to a sixty-fourth of a turn and each
-- number to a few steps, and kept under that key. A frog running in circles
-- mostly costs nothing: it is looking things up.
--
-- What was learned on the whistle holds here too: don't model a face. The eyes
-- are balls because a frog's eyes *are* balls, and the pupil is printed on the
-- ball where it faces forward rather than modelled.

local T = require "src.tracer"
local A = T.Affine

local sqrt, cos, sin, atan2, max, min, abs, floor = math.sqrt, math.cos, math.sin, math.atan2,
    math.max, math.min, math.abs, math.floor
local rad = math.rad

local Frog = {}
Frog.__index = Frog

local HEADINGS = 64
local CROUCH_STEPS, STRETCH_STEPS = 3, 4

local RUN, ACCEL, AIR_ACCEL = 62, 520, 260
local GRAVITY, JUMP = 330, 118 -- a full jump peaks at about 21 units
local STEP = 2.5                -- what it walks up without jumping
local RADIUS = 3.5
local COYOTE, BUFFER = 0.1, 0.12
Frog.TONGUE = 26

--- the model -----------------------------------------------------------------------

-- Front is +x, up is +y, the pivot is the ground under its middle. The units are
-- the tracer's, about a pixel each: a frog fifteen pixels nose to heel.
local skin = T.RAMP.blue
local function spotted(ux, uy, uz, lev)
    if uy < -0.3 then return T.RAMP.grey end -- the pale belly
    if lev == 2 and uy > 0.25 and sin(ux * 7 + 1) * sin(uz * 8) > 0.55 then return T.IDX.b end
end
local function throat(ux, uy, uz)
    if uy < -0.35 then return T.RAMP.grey end
end
local function eye(side)
    local dx, dy, dz = 0.55, 0.3, 0.78 * side
    local l = sqrt(dx * dx + dy * dy + dz * dz)
    dx, dy, dz = dx / l, dy / l, dz / l
    return function(ux, uy, uz, lev)
        if lev == 1 then return end -- keep the glint
        if ux * dx + uy * dy + uz * dz > 0.55 then return T.IDX.o end
    end
end

local function ell(cx, cy, cz, rx, ry, rz, ...)
    -- A unit ball scaled, then turned by whatever rotations follow, then moved.
    local m = A.scale(rx, ry, rz)
    for _, r in ipairs({ ... }) do m = A.mul(r, m) end
    return A.mul(A.move(cx, cy, cz), m)
end

local SKIN, EYE = 1, 2

function Frog.parts(h, crouch, stretch)
    local s, c = stretch, crouch
    local parts = {}
    local function add(id, mat, ramp, at, print)
        parts[#parts + 1] = { id = id, matId = mat, ramp = ramp, at = at, print = print }
    end
    add(1, SKIN, skin, ell(0, 4.2, 0, 6.2, 3.6, 4.8, A.rotZ(rad(12))), spotted)
    add(1, SKIN, skin, ell(5.0, 5.4, 0, 3.8, 2.8, 4.2, A.rotZ(rad(-6))), throat)
    for _, side in ipairs({ -1, 1 }) do
        add(side < 0 and 2 or 3, EYE, T.RAMP.grey, ell(5.4, 7.9, 2.6 * side, 1.9, 1.9, 1.9), eye(side))
        -- Back legs: folded under the haunch at rest, flung out behind in the air.
        add(side < 0 and 4 or 5, SKIN, skin,
            ell(-3.2 - 4 * s, 2.6 + 0.6 * s, (4.2 - 0.8 * s) * side, 3.8 + 0.6 * s, 1.9, 1.7,
                A.rotZ(rad(28 * s)), A.rotY(rad(-20 * side * (1 - s)))))
        add(side < 0 and 6 or 7, SKIN, skin,
            ell(-0.8 - 10 * s, 0.7 + 0.4 * s, (5.6 - 1.8 * s) * side, 3.6 + 0.8 * s, 0.8, 1.8,
                A.rotZ(rad(18 * s)), A.rotY(rad(-15 * side * (1 - s)))))
        -- Front legs: planted, then swept back along the belly.
        add(side < 0 and 8 or 9, SKIN, skin,
            ell(4.0 - 1.5 * s, 1.9, 3.2 * side, 1.1, 2.2, 1.1, A.rotZ(rad(-15 - 45 * s))))
        add(side < 0 and 8 or 9, SKIN, skin,
            ell(5.0 - 3.2 * s, 0.55 + 0.6 * s, 3.6 * side, 1.8, 0.55, 1.4))
    end
    -- The whole body: squashed about the ground when it crouches, pitched nose up
    -- and lifted when it stretches, then turned to its heading.
    local pose = A.mul(
        A.rotY(-h),
        A.move(0, 1.5 * s, 0),
        A.move(0, 4, 0), A.rotZ(rad(14 * s)), A.move(0, -4, 0),
        A.scale(1 + 0.14 * c, 1 - 0.3 * c, 1 + 0.14 * c))
    for _, p in ipairs(parts) do p.at = A.mul(pose, p.at) end
    return parts
end

local cache = {}
local function picture(hs, cs, ss)
    local k = (hs * 8 + cs) * 8 + ss
    local p = cache[k]
    if not p then
        p = T.paint(Frog.parts(hs / HEADINGS * 2 * math.pi, cs / CROUCH_STEPS, ss / STRETCH_STEPS), 2.5)
        cache[k] = p
    end
    return p
end
Frog.pose = picture

--- the hops ------------------------------------------------------------------------

function Frog.new(world)
    local s = world.start
    return setmetatable({
        world = world,
        x = s.x, y = s.y, z = s.z, vx = 0, vy = 0, vz = 0,
        h = math.pi * 0.25, ground = true,
        crouch = 0, stretch = 0, gait = 0,
        coyote = 0, buffer = 0, held = false,
        tongue = 0, tongueT = nil,
        safe = { x = s.x, y = s.y, z = s.z },
        sunk = nil,
    }, Frog)
end

-- Input is a direction on the page (screen right, screen down), whether jump was
-- just pressed, whether it is held, and whether the tongue was flicked.
function Frog:update(dt, mx, mz, jumpPressed, jumpHeld, flick, events)
    local w = self.world
    if self.sunk then
        self.sunk = self.sunk - dt
        if self.sunk <= 0 then
            self.sunk = nil
            self.x, self.y, self.z = self.safe.x, self.safe.y, self.safe.z
            self.vx, self.vy, self.vz = 0, 0, 0
            self.ground = true
        end
        return
    end

    -- Run: towards the stick, turning the body round to face it.
    local len = sqrt(mx * mx + mz * mz)
    if len > 1 then mx, mz, len = mx / len, mz / len, 1 end
    local acc = (self.ground and ACCEL or AIR_ACCEL) * dt
    local tx, tz = mx * RUN, mz * RUN
    local dvx, dvz = tx - self.vx, tz - self.vz
    local dl = sqrt(dvx * dvx + dvz * dvz)
    if dl > acc then dvx, dvz = dvx / dl * acc, dvz / dl * acc end
    self.vx, self.vz = self.vx + dvx, self.vz + dvz
    if len > 0.2 then
        local want = atan2(mz, mx)
        local d = (want - self.h + math.pi) % (2 * math.pi) - math.pi
        local turn = 14 * dt
        self.h = self.h + max(-turn, min(turn, d))
    end

    -- Jump, forgiving both ways: a press just before landing and a press just
    -- after running off an edge both count.
    self.coyote = self.ground and COYOTE or self.coyote - dt
    self.buffer = jumpPressed and BUFFER or self.buffer - dt
    if self.buffer > 0 and self.coyote > 0 then
        self.vy = JUMP
        self.ground, self.coyote, self.buffer = false, 0, 0
        self.crouch = 0
        events.jump = true
    end
    -- Let go early and it comes down sooner: the height is in the thumb.
    local g = GRAVITY
    if self.vy > 0 and not jumpHeld then g = g * 2.6 end
    if not self.ground then self.vy = self.vy - g * dt end

    -- Move a step at a time on each axis, so a wall stops one and slides the other.
    local function blocked(x, z)
        local top = w:topAt(x, z)
        return top and top > self.y + STEP
    end
    local nx = self.x + self.vx * dt
    local sx = self.vx > 0 and RADIUS or -RADIUS
    if self.vx ~= 0 and blocked(nx + sx, self.z) then self.vx = 0 else self.x = nx end
    local nz = self.z + self.vz * dt
    local sz = self.vz > 0 and RADIUS or -RADIUS
    if self.vz ~= 0 and blocked(self.x, nz + sz) then self.vz = 0 else self.z = nz end

    local top, bounce = w:topAt(self.x, self.z)
    if self.ground then
        if not top or top < self.y - 0.5 then
            self.ground = false -- walked off the edge
        elseif top > self.y then
            self.y = top        -- walked up a step
        end
    end
    if not self.ground then
        self.y = self.y + self.vy * dt
        if top and self.y <= top and self.vy <= 0 then
            self.y = top
            if bounce then
                self.vy = JUMP * 1.45 -- the mushroom throws it
                events.bounce = true
            else
                self.ground, self.vy = true, 0
                self.crouch = 1
                events.land = true
            end
        elseif not top and self.y <= -2 then
            self.sunk = 0.7
            events.splash = true
            return
        end
    end
    if self.ground and not bounce then self.safe.x, self.safe.y, self.safe.z = self.x, self.y, self.z end

    -- The tongue: out and back in a quarter of a second, aimed at the nearest fly
    -- in front of it if there is one.
    if flick and not self.tongueT then
        self.tongueT = 0
        self.aim = events.aim
    end
    if self.tongueT then
        self.tongueT = self.tongueT + dt
        local t = self.tongueT
        self.tongue = t < 0.09 and t / 0.09 or max(0, 1 - (t - 0.09) / 0.14)
        if t > 0.23 then self.tongueT, self.tongue = nil, 0 end
    end

    -- Poses: the gait is small hops while it runs; the air is all stretch.
    local speed = sqrt(self.vx * self.vx + self.vz * self.vz)
    self.crouch = max(0, self.crouch - dt * 7)
    if self.ground then
        if speed > 8 then
            self.gait = self.gait + dt * speed * 0.22
        else
            self.gait = 0
        end
        local p = abs(sin(self.gait * math.pi))
        self.bob = p * 3
        self.stretch = p * 0.75
        if p < 0.3 and speed > 8 then self.crouch = max(self.crouch, 0.4 * (1 - p / 0.3)) end
    else
        self.bob = 0
        local target = self.vy > 20 and 1 or 0.55
        self.stretch = self.stretch + (target - self.stretch) * min(1, dt * 12)
    end
end

function Frog:picture()
    local hs = floor(self.h / (2 * math.pi) * HEADINGS + 0.5) % HEADINGS
    local cs = floor(self.crouch * CROUCH_STEPS + 0.5)
    local ss = floor(self.stretch * STRETCH_STEPS + 0.5)
    return picture(hs, cs, ss)
end

-- The mouth and where the tongue's tip is, in the room.
function Frog:tongueEnds()
    local c, s = cos(self.h), sin(self.h)
    local y = self.y + (self.bob or 0)
    local mx, my, mz = self.x + c * 8, y + 4.6 - 1.2 * self.crouch, self.z + s * 8
    local reach = Frog.TONGUE * self.tongue
    local dx, dy, dz = c, -0.05, s
    if self.aim then
        local ax, ay, az = self.aim.x - mx, self.aim.y - my, self.aim.z - mz
        local l = sqrt(ax * ax + ay * ay + az * az)
        dx, dy, dz = ax / l, ay / l, az / l
    end
    return mx, my, mz, mx + dx * reach, my + dy * reach, mz + dz * reach
end

return Frog
