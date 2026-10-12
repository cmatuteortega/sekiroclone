-- The flies: what the frog is after. Too small to need turning -- a fly is a dot
-- with wings at this size -- so a fly's picture is kept by wing beat alone, two of
-- them, and every fly shares them.

local T = require "src.tracer"
local A = T.Affine

local sin, cos = math.sin, math.cos

local Fly = {}
Fly.__index = Fly

-- Half as big again as a fly is: the size it has to be to be seen.
local SIZE = 1.5
local function ell(cx, cy, cz, rx, ry, rz, r)
    local m = A.scale(rx, ry, rz)
    if r then m = A.mul(r, m) end
    return A.mul(A.scale(SIZE, SIZE, SIZE), A.move(cx, cy, cz), m)
end

local pictures = {}
local function picture(beat)
    if not pictures[beat] then
        local lift = beat == 0 and 0.25 or 0.95
        local parts = {
            { id = 1, ramp = T.RAMP.ink, at = ell(0, 0, 0, 1.7, 1.4, 1.4) },
            { id = 4, matId = 2, ramp = T.RAMP.red, at = ell(1.3, 0.3, 0, 0.9, 0.9, 1.3) },
        }
        for _, side in ipairs({ -1, 1 }) do
            parts[#parts + 1] = { id = side < 0 and 2 or 3, matId = 3, ramp = T.RAMP.grey,
                at = ell(-0.4, 1.2, 1.5 * side, 1.8, 0.25, 1.2, A.rotX(lift * side)) }
        end
        pictures[beat] = T.paint(parts, 1.5)
    end
    return pictures[beat]
end

function Fly.new(x, y, z, seed)
    return setmetatable({ hx = x, hy = y, hz = z, x = x, y = y, z = z, t = seed * 1.7 }, Fly)
end

function Fly:update(dt)
    self.t = self.t + dt
    local t = self.t
    -- A lazy loop round where it lives, and a bob.
    self.x = self.hx + cos(t * 1.3) * 4
    self.z = self.hz + sin(t * 1.9) * 3
    self.y = self.hy + sin(t * 3.1) * 1.5
end

function Fly:picture()
    return picture(math.floor(self.t * 24) % 2)
end

return Fly
