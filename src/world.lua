-- The pond: everything that does not move, painted once.
--
-- The camera never turns and has no perspective, so a picture of the world is the
-- same picture wherever the camera is: it is traced once at load, a pixel at a
-- time, into one big image the camera slides over -- and into a depth buffer the
-- same size, which is what lets the frog (painted on its own, see src/frog.lua)
-- go behind a tree or under the lip of a ledge without the world being traced
-- again. The buffer also keeps where each pixel is in the room, so a shadow can
-- be laid on whatever surface is under the frog.
--
-- The world is written as an ASCII map, one character per 16-unit tile, in the
-- spirit of Survive School's sprites: the map is the art.

local ffi = require "ffi"
local T = require "src.tracer"

local sqrt, max, min, abs, floor, ceil = math.sqrt, math.max, math.min, math.abs, math.floor, math.ceil
local SP, CP, UNIT = T.SP, T.CP, T.UNIT
local IDX, RAMP = T.IDX, T.RAMP

local World = {}
World.__index = World

local TILE = 16
local BACK = 1000
World.TILE = TILE

-- A ground tile of level L stands L*8-2 above the water: a step a frog has to
-- jump, and never one it can just walk up.
local function level(L) return L * 8 - 2 end

--   ~ water        1 2 3  ground, by level     @ where the frog starts
--   p lily pad     q lily pad with a fly over it
--   t tree         m mushroom (bouncy)         o rock      s stump
--   f a fly over the ground          (t m o s f @ stand on level 1;
--   T F S M        the same on level 2)
local MAP = {
    "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
    "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
    "~~1111111~~~~~~~~~~~~~22222~~~~",
    "~~1t11m11~~p~~q~~p~~p~2T22F~~~~",
    "~~111@111~~~~~~~~~~~~~22222~~~~",
    "~~11111f1~~~~~~~~~~~~~2233M2~~~",
    "~~1o11111~~~~~~~~~~~~~223332~~~",
    "~~~111s1~~~~~~~~~~~~~~22222S~~~",
    "~~~~11~~~~~~~~~~~~~~~~~111~~~~~",
    "~~~~~~p~~~~~~~~~~~~~~~~1o1~~~~~",
    "~~~~~~~~p~111111~~~~~~~111~~~~~",
    "~~~~q~~~~112222m1~~~~~~~~~~~~~~",
    "~~~~~~~~~112T33F1~~p~~q~~p~~~~~",
    "~~~~p~~~~112222211~~~~~~~~~~~~~",
    "~~~~~~~~~~11111s1~~~~~~~1111~~~",
    "~~~~~~~~~~~~~~~~~~~~~~~11t11~~~",
    "~~111111~~p~~~~~~~~~~~11f11o~~~",
    "~~1f1m11~~~~~q~~p~~p~~111111~~~",
    "~~111111~~~~~~~~~~~~~~~~~~~~~~~",
    "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
}

local ON = { -- what stands on which level
    t = { "tree", 1 }, m = { "mushroom", 1 }, o = { "rock", 1 }, s = { "stump", 1 },
    f = { "fly", 1 }, ["@"] = { "start", 1 },
    T = { "tree", 2 }, M = { "mushroom", 2 }, S = { "stump", 2 }, F = { "fly", 2 },
}

--- solids ----------------------------------------------------------------------

-- Each answers the nearest t along the ray from (ox, oy, oz) and the normal
-- there, or nothing. The ray never has an x component, so a box's sides are never
-- seen: the camera looks straight up the page.

local function hitBox(s, ox, oy, oz)
    if ox < s.x0 or ox > s.x1 then return end
    local ty0, ty1 = (oy - s.y1) / SP, (oy - s.y0) / SP
    local tz0, tz1 = (oz - s.z1) / CP, (oz - s.z0) / CP
    local tin, tout = max(ty0, tz0), min(ty1, tz1)
    if tin > tout then return end
    if ty0 > tz0 then return tin, 0, 1, 0 end
    return tin, 0, 0, 1
end

local function hitCyl(s, ox, oy, oz)
    local dx = ox - s.cx
    if abs(dx) > s.r then return end
    local h = sqrt(s.r * s.r - dx * dx)
    local tz0, tz1 = (oz - s.cz - h) / CP, (oz - s.cz + h) / CP
    local ty0, ty1 = (oy - s.y1) / SP, (oy - s.y0) / SP
    local tin, tout = max(ty0, tz0), min(ty1, tz1)
    if tin > tout then return end
    local nx, ny, nz
    if ty0 > tz0 then nx, ny, nz = 0, 1, 0 else nx, ny, nz = dx / s.r, 0, h / s.r end
    if s.notch then
        -- The lily pad's notch: a wedge of the disc that is not there.
        local px, pz = ox - s.cx, oz - CP * tin - s.cz
        local a = math.atan2(pz, px) - s.notch
        a = (a + math.pi) % (2 * math.pi) - math.pi
        if abs(a) < 0.3 then return end
    end
    return tin, nx, ny, nz
end

local function hitEll(s, ox, oy, oz)
    local ax, ay, az = (ox - s.cx) / s.rx, (oy - s.cy) / s.ry, (oz - s.cz) / s.rz
    local by, bz = -SP / s.ry, -CP / s.rz
    local qa = by * by + bz * bz
    local qb = ay * by + az * bz
    local qc = ax * ax + ay * ay + az * az - 1
    local d = qb * qb - qa * qc
    if d < 0 then return end
    local t = (-qb - sqrt(d)) / qa
    local ux, uy, uz = ax, ay + t * by, az + t * bz
    local nx, ny, nz = ux / s.rx, uy / s.ry, uz / s.rz
    local l = sqrt(nx * nx + ny * ny + nz * nz)
    s.ux, s.uy, s.uz = ux, uy, uz
    return t, nx / l, ny / l, nz / l
end

--- what things are made of -------------------------------------------------------

-- `print` answers a key index for a pixel that is printed rather than lit (a
-- ruled line, a ring in a stump), or nothing to take the ramp's.
local MAT = {}

MAT.ground = { id = 2, ramp = RAMP.grey, print = function(s, x, y, z, nx, ny, nz, lev)
    if y < 0.9 then return IDX.w end -- where the water laps
    if ny > 0.9 then
        -- The top of the ground is a page of the exercise book: ruled in sky,
        -- with a blush margin.
        if (x % 160) >= 40 and (x % 160) < 41.8 then return IDX.k end
        if z % 8 < 1.1 then return IDX.c end
        if lev == 3 then return IDX.w end -- the page is paper, lit or not
    end
end }
MAT.wood = { id = 3, ramp = RAMP.grey, print = function(s, x, y, z, nx, ny, nz)
    if y < 0.9 then return IDX.w end
    if ny > 0.9 then
        local d = sqrt((x - s.cx) ^ 2 + (z - s.cz) ^ 2)
        if d % 1.8 < 0.6 then return IDX.g end
    end
end }
MAT.blossom = { id = 4, ramp = RAMP.red }
MAT.stone = { id = 5, ramp = RAMP.grey, print = function(s, x, y, z)
    if y < 0.9 then return IDX.w end
end }
local SPOTS = {}
for n = 0, 6 do
    local a, e = n * 2.4, 0.35 + (n % 3) * 0.22
    SPOTS[#SPOTS + 1] = { math.cos(a) * math.cos(e), math.sin(e), math.sin(a) * math.cos(e) }
end
MAT.cap = { id = 6, ramp = RAMP.red, print = function(s)
    for _, d in ipairs(SPOTS) do
        if s.ux * d[1] + s.uy * d[2] + s.uz * d[3] > 0.965 then return IDX.w end
    end
end }
MAT.pad = { id = 7, ramp = RAMP.red, print = function(s, x, y, z, nx, ny, nz, lev)
    if ny > 0.9 and lev == 2 then
        local a = math.atan2(z - s.cz, x - s.cx) - s.notch
        if abs((a + 0.5) % 1.05 - 0.5) < 0.06 and (x - s.cx) ^ 2 + (z - s.cz) ^ 2 > 4 then
            return IDX.r -- veins
        end
    end
end }

local function water(x, z)
    -- Ripples as short dashes, rows a few units apart, staggered: the pond is
    -- sky with blue strokes, the way the page's ruled lines are sky on paper.
    local row = floor(z / 5)
    local h = math.sin(x * 0.21 + row * 1.7) + math.sin(x * 0.047 - row * 0.9)
    if (z % 5) < 1.2 and h > 1.45 then return IDX.b end
    if (z % 5) < 1.2 and h < -1.85 then return IDX.w end
    return IDX.c
end

--- building it -------------------------------------------------------------------

function World.new()
    local self = setmetatable({}, World)
    self.solids, self.colliders, self.flies = {}, {}, {}
    self.rows, self.cols = #MAP, 0
    for _, row in ipairs(MAP) do self.cols = max(self.cols, #row) end

    local function cell(c, r)
        local row = MAP[r + 1]
        if not row then return "~" end
        local ch = row:sub(c + 1, c + 1)
        return ch == "" and "~" or ch
    end
    local function groundLevel(ch)
        if ch:match("%d") then return tonumber(ch) end
        if ON[ch] then return ON[ch][2] end
        return 0
    end

    local nextPart = 10
    local function add(kind, mat, s)
        s.kind, s.mat, s.part = kind, mat, nextPart
        nextPart = nextPart + 1
        self.solids[#self.solids + 1] = s
        return s
    end
    local function collide(c) self.colliders[#self.colliders + 1] = c end

    -- Ground: runs of tiles of one level along a row are one box, so a long
    -- shore is one solid and not twenty.
    for r = 0, self.rows - 1 do
        local c = 0
        while c < self.cols do
            local L = groundLevel(cell(c, r))
            if L > 0 then
                local c1 = c
                while c1 + 1 < self.cols and groundLevel(cell(c1 + 1, r)) == L do c1 = c1 + 1 end
                local b = add("box", MAT.ground, { x0 = c * TILE, x1 = (c1 + 1) * TILE,
                    z0 = r * TILE, z1 = (r + 1) * TILE, y0 = -8, y1 = level(L) })
                collide({ x0 = b.x0, x1 = b.x1, z0 = b.z0, z1 = b.z1, top = b.y1 })
                c = c1 + 1
            else
                c = c + 1
            end
        end
    end

    -- Everything standing on a tile.
    for r = 0, self.rows - 1 do
        for c = 0, self.cols - 1 do
            local ch = cell(c, r)
            local cx, cz = c * TILE + TILE / 2, r * TILE + TILE / 2
            local on = ON[ch]
            local base = on and level(on[2]) or 0
            local what = on and on[1]
            if ch == "p" or ch == "q" then
                local notch = ((c * 7 + r * 13) % 8) * 0.785
                add("cyl", MAT.pad, { cx = cx, cz = cz, r = 6.5, y0 = -0.5, y1 = 0.6, notch = notch })
                collide({ cx = cx, cz = cz, r = 7, top = 0.6 })
                if ch == "q" then self.flies[#self.flies + 1] = { x = cx, y = 9, z = cz } end
            elseif what == "tree" then
                add("cyl", MAT.wood, { cx = cx, cz = cz, r = 1.8, y0 = base - 1, y1 = base + 14 })
                add("ell", MAT.blossom, { cx = cx, cy = base + 17, cz = cz, rx = 9, ry = 6.5, rz = 8 })
                add("ell", MAT.blossom, { cx = cx - 6, cy = base + 15, cz = cz + 3, rx = 5.5, ry = 4.5, rz = 5 })
                add("ell", MAT.blossom, { cx = cx + 5, cy = base + 21, cz = cz - 2, rx = 6, ry = 5, rz = 5.5 })
                collide({ cx = cx, cz = cz, r = 3, top = base + 40 })
            elseif what == "mushroom" then
                add("cyl", MAT.stone, { cx = cx, cz = cz, r = 1.8, y0 = base - 1, y1 = base + 6 })
                add("ell", MAT.cap, { cx = cx, cy = base + 6.5, cz = cz, rx = 6.5, ry = 3.2, rz = 6.5 })
                collide({ cx = cx, cz = cz, r = 6.5, top = base + 9.5, bounce = true })
            elseif what == "rock" then
                add("ell", MAT.stone, { cx = cx, cy = base, cz = cz, rx = 6.5, ry = 5, rz = 5.5 })
                collide({ cx = cx, cz = cz, r = 5, top = base + 4.5 })
            elseif what == "stump" then
                add("cyl", MAT.wood, { cx = cx, cz = cz, r = 5.5, y0 = base - 1, y1 = base + 7 })
                collide({ cx = cx, cz = cz, r = 5.5, top = base + 7 })
            elseif what == "fly" then
                self.flies[#self.flies + 1] = { x = cx, y = base + 10, z = cz }
            elseif what == "start" then
                self.start = { x = cx, y = base, z = cz }
            end
        end
    end

    -- How much of the screen the world covers, with a margin of open water.
    local x0, x1 = -64, self.cols * TILE + 64
    local z0, z1 = -64, self.rows * TILE + 64
    self.i0 = floor(x0 / UNIT)
    self.j0 = floor((z0 * SP - 50 * CP) / UNIT)
    self.w = ceil(x1 / UNIT) - self.i0
    self.h = ceil(z1 * SP / UNIT) - self.j0
    return self
end

-- Where each solid can land on the screen, binned in 16-pixel squares, so a
-- pixel only asks the handful that could be in it.
local BIN = 16

function World:bin()
    local bw, bh = ceil(self.w / BIN), ceil(self.h / BIN)
    local bins = {}
    for n = 1, bw * bh do bins[n] = {} end
    for _, s in ipairs(self.solids) do
        local ax0, ax1, ay0, ay1, az0, az1
        if s.kind == "box" then
            ax0, ax1, ay0, ay1, az0, az1 = s.x0, s.x1, s.y0, s.y1, s.z0, s.z1
        elseif s.kind == "cyl" then
            ax0, ax1, ay0, ay1, az0, az1 = s.cx - s.r, s.cx + s.r, s.y0, s.y1, s.cz - s.r, s.cz + s.r
        else
            ax0, ax1, ay0, ay1 = s.cx - s.rx, s.cx + s.rx, s.cy - s.ry, s.cy + s.ry
            az0, az1 = s.cz - s.rz, s.cz + s.rz
        end
        local i0 = floor(ax0 / UNIT) - self.i0 - 1
        local i1 = ceil(ax1 / UNIT) - self.i0 + 1
        local j0 = floor((az0 * SP - ay1 * CP) / UNIT) - self.j0 - 1
        local j1 = ceil((az1 * SP - ay0 * CP) / UNIT) - self.j0 + 1
        for by = max(0, floor(j0 / BIN)), min(bh - 1, floor(j1 / BIN)) do
            for bx = max(0, floor(i0 / BIN)), min(bw - 1, floor(i1 / BIN)) do
                local list = bins[by * bw + bx + 1]
                list[#list + 1] = s
            end
        end
    end
    return bins, bw
end

local HIT = { box = hitBox, cyl = hitCyl, ell = hitEll }

-- Paints the world. A coroutine body: it yields its progress (0..1) every few
-- rows so the load screen can say how far along it is.
function World:paint()
    local w, h = self.w, self.h
    local b = T.buffer(w, h)
    b.open = true
    self.wx = ffi.new("float[?]", w * h)
    self.wy = ffi.new("float[?]", w * h)
    self.wz = ffi.new("float[?]", w * h)
    self.up = ffi.new("uint8_t[?]", w * h)
    local bins, bw = self:bin()
    local waterRamp = RAMP.blue

    for pj = 0, h - 1 do
        for pi = 0, w - 1 do
            local ox, oy, oz = T.origin(self.i0 + pi + 0.5, self.j0 + pj + 0.5, BACK)
            -- The water is a plane at y = 0 under everything.
            local bt, nx, ny, nz, best = oy / SP, 0, 1, 0, nil
            for _, s in ipairs(bins[floor(pj / BIN) * bw + floor(pi / BIN) + 1]) do
                local t, ax, ay, az = HIT[s.kind](s, ox, oy, oz)
                if t and t < bt then
                    bt, nx, ny, nz, best = t, ax, ay, az, s
                    if s.kind == "ell" then s.bux, s.buy, s.buz = s.ux, s.uy, s.uz end
                end
            end
            local x, y, z = ox, oy - SP * bt, oz - CP * bt
            local n = pj * w + pi
            local key, lev, ramp
            if best then
                local m = best.mat
                ramp = m.ramp
                key, lev = T.shade(ramp, nx, ny, nz)
                if m.print then
                    if best.kind == "ell" then best.ux, best.uy, best.uz = best.bux, best.buy, best.buz end
                    local k = m.print(best, x, y, z, nx, ny, nz, lev)
                    if k then key, lev = k, 0 end
                end
                b.part[n], b.mat[n] = best.part, m.id
            else
                ramp = waterRamp
                key, lev = water(x, z), 0
                b.part[n], b.mat[n] = 1, 1
            end
            b.key[n], b.lev[n], b.shd[n] = key, lev, ramp[4]
            b.dep[n] = BACK - bt
            b.dif[n] = T.diffuse(nx, ny, nz)
            b.nx[n], b.ny[n], b.nz[n] = nx, ny, nz
            self.wx[n], self.wy[n], self.wz[n] = x, y, z
            self.up[n] = ny > 0.7 and 1 or 0
        end
        if pj % 6 == 0 then coroutine.yield(pj / h) end
    end
    T.finish(b, 3)
    self.key, self.dep = b.key, b.dep

    local data = love.image.newImageData(w, h)
    for pj = 0, h - 1 do
        for pi = 0, w - 1 do
            local c = T.RGB[self.key[pj * w + pi]]
            data:setPixel(pi, pj, c[1], c[2], c[3], 1)
        end
    end
    self.image = love.graphics.newImage(data)
    self.image:setFilter("nearest", "nearest")
end

--- standing on it ----------------------------------------------------------------

-- The highest top of anything under (x, z), and whether it bounces; nil over
-- open water.
function World:topAt(x, z)
    local best, bounce
    for _, c in ipairs(self.colliders) do
        local inside
        if c.r then
            inside = (x - c.cx) ^ 2 + (z - c.cz) ^ 2 <= c.r * c.r
        else
            inside = x >= c.x0 and x <= c.x1 and z >= c.z0 and z <= c.z1
        end
        if inside and (not best or c.top > best) then best, bounce = c.top, c.bounce end
    end
    return best, bounce
end

-- Screen pixel (relative to the world image) of a room point, and its depth.
function World:toImage(x, y, z)
    local i, j, d = T.project(x, y, z)
    return i - self.i0, j - self.j0, d
end

return World
