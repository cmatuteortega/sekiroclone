-- The tracer: Survive School's 3D method (its 3dmethod.md / src/solid.lua),
-- cut down to what a frog in a pond needs and stretched to cover a world.
--
-- The camera is the bake's camera: the room is looked at from 34 degrees above
-- the floor, orthographic. Survive School draws 0.92 model units to a pixel; a
-- world wants its hero bigger on the screen than a boss on a page wants, so
-- here it is 0.6 -- the same models come out half as big again. Room space
-- is x right, y up, z towards the viewer (down the screen). Orthographic matters
-- more here than it did there: with no perspective a picture of something is the
-- same picture wherever it stands, which is what lets the whole world be painted
-- once and slid about under the camera, and the frog be painted once per heading
-- and pose and kept.
--
-- Every pixel is traced once at its centre and its colour is *chosen* off a ramp
-- of palette keys, never blended, so no ninth colour can turn up. Then the two
-- passes that make it read as drawn rather than rendered: creases (a step down to
-- the ramp's shadow where neighbouring normals of one material disagree) and ink
-- (round the silhouette, and along any step in depth onto another part).

local ffi = require "ffi"
local Palette = require "src.palette"

local sqrt, cos, sin, max, min, abs = math.sqrt, math.cos, math.sin, math.max, math.min, math.abs

local T = {}

local PITCH = math.rad(34)
local CP, SP = cos(PITCH), sin(PITCH)
local UNIT = 0.6
T.CP, T.SP, T.UNIT = CP, SP, UNIT

-- The room's lamp: up, to the left and towards you. The glint is the half-way
-- vector between it and the eye.
local LX, LY, LZ = -0.5, 0.75, 0.45
do
    local n = sqrt(LX * LX + LY * LY + LZ * LZ)
    LX, LY, LZ = LX / n, LY / n, LZ / n
end
local HX, HY, HZ = LX, LY + SP, LZ + CP
do
    local n = sqrt(HX * HX + HY * HY + HZ * HZ)
    HX, HY, HZ = HX / n, HY / n, HZ / n
end
-- Every ray of every picture goes the same way: down the camera's -z.
local DX, DY, DZ = 0, -SP, -CP
T.DX, T.DY, T.DZ = DX, DY, DZ

local CREASE = 0.55

--- palette keys as small numbers ------------------------------------------------

-- 0 is "nothing here". Buffers hold these rather than strings so they can live in
-- ffi arrays the size of the world.
T.KEYS = { "w", "g", "s", "o", "r", "k", "b", "c" }
T.IDX = {}
for i, k in ipairs(T.KEYS) do T.IDX[k] = i end
local IDX = T.IDX

local NAMES = { w = "paper", g = "graphite", s = "slate", o = "ink",
    r = "red", k = "blush", b = "blue", c = "sky" }

-- RGB per key index, and the key one step darker -- the overprint table's ruled
-- column: a shadow on the page is ink stacked on whatever is printed there.
T.RGB, T.DARKER = {}, {}
for i, k in ipairs(T.KEYS) do
    T.RGB[i] = Palette.key[k]
    T.DARKER[i] = IDX[({ paper = "w", graphite = "g", slate = "s", ink = "o", red = "r",
        blush = "k", blue = "b", sky = "c" })[Palette.overprint[NAMES[k]][2]]]
end

--- projection ------------------------------------------------------------------

-- Room point to screen pixel (i right, j down) and depth (bigger is nearer).
function T.project(x, y, z)
    return x / UNIT, (z * SP - y * CP) / UNIT, y * SP + z * CP
end

-- Where the ray through screen point (i, j) starts, on the plane `back` deep.
function T.origin(i, j, back)
    return i * UNIT, -j * UNIT * CP + back * SP, j * UNIT * SP + back * CP
end

--- light and ramps -------------------------------------------------------------

-- A ramp is glint, lit, middle, shadow (as key indices). The table is the
-- one in 3dmethod.md, bounce-light row included: without it the underside is one
-- slate shape and reads as a hole.
local function ramp(g, l, m, s) return { IDX[g], IDX[l], IDX[m], IDX[s] } end
T.RAMP = {
    red = ramp("w", "k", "r", "s"),
    blue = ramp("w", "c", "b", "s"),
    grey = ramp("w", "w", "g", "s"),
    ink = ramp("g", "s", "o", "o"),
}

function T.diffuse(nx, ny, nz)
    return nx * LX + ny * LY + nz * LZ
end

-- Answers key index and the ramp level it came off (1 glint .. 4 shadow).
function T.shade(r, nx, ny, nz)
    local d = nx * LX + ny * LY + nz * LZ
    local h = nx * HX + ny * HY + nz * HZ
    if h > 0 and h ^ 40 > 0.6 then return r[1], 1 end
    if d > 0.78 then return r[2], 2 end
    if d > 0.2 then return r[3], 3 end
    if ny < 0 and d > 0.02 then return r[3], 3 end
    return r[4], 4
end

--- buffers ---------------------------------------------------------------------

-- One pixel's worth of everything the two passes need. `lev` 0 marks a printed
-- pixel (a ruled line, a pupil) that a crease must not touch.
function T.buffer(w, h)
    local n = w * h
    return {
        w = w, h = h,
        key = ffi.new("uint8_t[?]", n),
        lev = ffi.new("uint8_t[?]", n),
        shd = ffi.new("uint8_t[?]", n), -- the ramp's shadow key, for creases
        part = ffi.new("int16_t[?]", n),
        mat = ffi.new("int16_t[?]", n),
        dep = ffi.new("float[?]", n),
        dif = ffi.new("float[?]", n),
        nx = ffi.new("float[?]", n),
        ny = ffi.new("float[?]", n),
        nz = ffi.new("float[?]", n),
    }
end

-- Creases, then ink, both decided off the untouched picture.
function T.finish(b, edge)
    local w, h = b.w, b.h
    local key, lev, shd, part, mat, dep, dif = b.key, b.lev, b.shd, b.part, b.mat, b.dep, b.dif
    local nx, ny, nz = b.nx, b.ny, b.nz
    local n = w * h
    local out = ffi.new("uint8_t[?]", n)
    ffi.copy(out, key, n)

    local function crease(p, q)
        if key[q] == 0 or mat[p] ~= mat[q] then return end
        if nx[p] * nx[q] + ny[p] * ny[q] + nz[p] * nz[q] >= CREASE then return end
        local r = dif[p] < dif[q] and p or q
        if lev[r] == 2 or lev[r] == 3 then out[r] = shd[r] end
    end
    for j = 0, h - 1 do
        for i = 0, w - 1 do
            local p = j * w + i
            if key[p] ~= 0 then
                if i < w - 1 then crease(p, p + 1) end
                if j < h - 1 then crease(p, p + w) end
            end
        end
    end

    local INK = IDX.o
    local function inked(p, q)
        if key[q] == 0 then return true end
        return part[q] ~= part[p] and dep[p] - dep[q] > edge
    end
    for j = 0, h - 1 do
        for i = 0, w - 1 do
            local p = j * w + i
            if key[p] ~= 0 then
                if i == 0 or i == w - 1 or j == 0 or j == h - 1
                    or inked(p, p - 1) or inked(p, p + 1) or inked(p, p - w) or inked(p, p + w) then
                    -- The world has no edge to ink: its border is just where the
                    -- painting stopped.
                    if not (b.open and (i == 0 or i == w - 1 or j == 0 or j == h - 1)) then
                        out[p] = INK
                    end
                end
            end
        end
    end
    b.key = out
end

--- affine maps -----------------------------------------------------------------

-- Twelve numbers, row-major: the 3x3 and then the shift, per row.
local A = {}
T.Affine = A

function A.id() return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 } end
function A.move(x, y, z) return { 1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z } end
function A.scale(x, y, z) return { x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0 } end
function A.rotY(a)
    local c, s = cos(a), sin(a)
    return { c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0 }
end
function A.rotZ(a)
    local c, s = cos(a), sin(a)
    return { c, -s, 0, 0, s, c, 0, 0, 0, 0, 1, 0 }
end
function A.rotX(a)
    local c, s = cos(a), sin(a)
    return { 1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0 }
end

function A.mul(a, b, ...)
    local r = {}
    for row = 0, 2 do
        local a1, a2, a3, a4 = a[row * 4 + 1], a[row * 4 + 2], a[row * 4 + 3], a[row * 4 + 4]
        for col = 1, 4 do
            r[row * 4 + col] = a1 * b[col] + a2 * b[4 + col] + a3 * b[8 + col]
        end
        r[row * 4 + 4] = r[row * 4 + 4] + a4
    end
    if ... then return A.mul(r, ...) end
    return r
end

function A.inv(m)
    local a, b, c, d, e, f, g, h, i = m[1], m[2], m[3], m[5], m[6], m[7], m[9], m[10], m[11]
    local A1, B1, C1 = e * i - f * h, -(d * i - f * g), d * h - e * g
    local det = a * A1 + b * B1 + c * C1
    local r = {
        A1 / det, -(b * i - c * h) / det, (b * f - c * e) / det, 0,
        B1 / det, (a * i - c * g) / det, -(a * f - c * d) / det, 0,
        C1 / det, -(a * h - b * g) / det, (a * e - b * d) / det, 0,
    }
    for row = 0, 2 do
        r[row * 4 + 4] = -(r[row * 4 + 1] * m[4] + r[row * 4 + 2] * m[8] + r[row * 4 + 3] * m[12])
    end
    return r
end

function A.apply(m, x, y, z)
    return m[1] * x + m[2] * y + m[3] * z + m[4],
        m[5] * x + m[6] * y + m[7] * z + m[8],
        m[9] * x + m[10] * y + m[11] * z + m[12]
end

--- pictures of bodies made of ellipsoids ---------------------------------------

-- A body is a list of parts, each an ellipsoid: a unit ball put through `at`, a
-- map into the room relative to the body's pivot. A part answers its `mat`
-- (a function of the point on its own unit ball, giving a key index or nothing
-- for its ramp) and its `id` (what the ink pass tells parts apart by).
--
-- The ray is taken back through each part's inverse into the ball's own space,
-- where the question is a quadratic; the normal comes back out through the
-- transpose of the same inverse. Each part only asks the pixels inside the
-- circle its bounding sphere lands in.
local BACK = 60

function T.paint(parts, edge)
    local i0, j0, i1, j1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(parts) do
        local m = p.at
        p.inv = A.inv(m)
        local cx, cy, cz = m[4], m[8], m[12]
        local r = 0
        for col = 1, 3 do
            r = max(r, sqrt(m[col] ^ 2 + m[4 + col] ^ 2 + m[8 + col] ^ 2))
        end
        local ci, cj = T.project(cx, cy, cz)
        p.ci, p.cj, p.cr = ci, cj, r / UNIT + 1
        i0, i1 = min(i0, ci - p.cr), max(i1, ci + p.cr)
        j0, j1 = min(j0, cj - p.cr), max(j1, cj + p.cr)
    end
    i0, j0 = math.floor(i0) - 1, math.floor(j0) - 1
    i1, j1 = math.ceil(i1) + 1, math.ceil(j1) + 1
    local w, h = i1 - i0 + 1, j1 - j0 + 1
    local b = T.buffer(w, h)
    local best = ffi.new("float[?]", w * h)
    for n = 0, w * h - 1 do best[n] = 1e9 end

    for _, p in ipairs(parts) do
        local v = p.inv
        -- The ray's way, in the ball's space; the same for every pixel.
        local bx = v[2] * DY + v[3] * DZ
        local by = v[6] * DY + v[7] * DZ
        local bz = v[10] * DY + v[11] * DZ
        local qa = bx * bx + by * by + bz * bz
        local pi0, pi1 = math.floor(p.ci - p.cr) - i0, math.ceil(p.ci + p.cr) - i0
        local pj0, pj1 = math.floor(p.cj - p.cr) - j0, math.ceil(p.cj + p.cr) - j0
        local rr = p.cr * p.cr
        for pj = max(0, pj0), min(h - 1, pj1) do
            for pi = max(0, pi0), min(w - 1, pi1) do
                local si, sj = i0 + pi + 0.5, j0 + pj + 0.5
                if (si - p.ci) ^ 2 + (sj - p.cj) ^ 2 <= rr then
                    local ox, oy, oz = T.origin(si, sj, BACK)
                    local ax = v[1] * ox + v[2] * oy + v[3] * oz + v[4]
                    local ay = v[5] * ox + v[6] * oy + v[7] * oz + v[8]
                    local az = v[9] * ox + v[10] * oy + v[11] * oz + v[12]
                    local qb = ax * bx + ay * by + az * bz
                    local qc = ax * ax + ay * ay + az * az - 1
                    local disc = qb * qb - qa * qc
                    if disc >= 0 then
                        local t = (-qb - sqrt(disc)) / qa
                        local n = pj * w + pi
                        if t < best[n] then
                            best[n] = t
                            local ux, uy, uz = ax + t * bx, ay + t * by, az + t * bz
                            -- Normal: transpose of the inverse's linear part.
                            local nx = v[1] * ux + v[5] * uy + v[9] * uz
                            local ny = v[2] * ux + v[6] * uy + v[10] * uz
                            local nz = v[3] * ux + v[7] * uy + v[11] * uz
                            local l = sqrt(nx * nx + ny * ny + nz * nz)
                            nx, ny, nz = nx / l, ny / l, nz / l
                            local r = p.ramp
                            local k, lev = T.shade(r, nx, ny, nz)
                            local printed = p.print and p.print(ux, uy, uz, lev)
                            if type(printed) == "table" then
                                r = printed
                                k, lev = T.shade(r, nx, ny, nz)
                            elseif printed then
                                k, lev = printed, 0
                            end
                            b.key[n], b.lev[n], b.shd[n] = k, lev, r[4]
                            b.part[n], b.mat[n] = p.id, p.matId or p.id
                            b.dep[n] = BACK - t
                            b.dif[n] = T.diffuse(nx, ny, nz)
                            b.nx[n], b.ny[n], b.nz[n] = nx, ny, nz
                        end
                    end
                end
            end
        end
    end
    T.finish(b, edge)
    -- `oi, oj`: the pixel of the picture the pivot falls on.
    return { w = w, h = h, oi = -i0, oj = -j0, key = b.key, dep = b.dep }
end

return T
