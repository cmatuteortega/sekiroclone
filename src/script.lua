-- Dev only: `love . --shots` plays a scripted thumb on a fixed 30fps clock and
-- writes screenshots, plus a sheet of every frog heading in three poses -- the
-- "look at it before the game does" step from Survive School's 3dmethod.md.

local T = require "src.tracer"
local Frog = require "src.frog"

local S = {}

local PLAN = {
    { 0.0, 0.4, { mx = 1, mz = 0.6 } },
    { 0.4, 0.45, { flick = true } },
    { 0.45, 1.0, { mx = 1 } },
    { 1.0, 1.05, { mx = 1, jump = true, held = true } },
    { 1.05, 1.5, { mx = 1, held = true } },
    { 1.5, 2.6, { mz = 1 } },
    { 2.6, 2.7, { flick = true } },
    { 2.7, 3.6, { mx = -1, mz = -1 } },
    { 3.6, 3.65, { mx = 1, jump = true, held = true } },
    { 3.65, 4.4, { mx = 1, held = true } },
    { 4.4, 6.0, { mx = 1 } },
}
local SHOTS = { 0.5, 0.95, 1.3, 2.65, 3.9, 4.6, 5.9 }

function S.at(t)
    for _, p in ipairs(PLAN) do
        if t >= p[1] and t < p[2] then return p[3] end
    end
    return {}
end

local taken = 0
function S.after(t, canvas)
    if taken < #SHOTS and t >= SHOTS[taken + 1] then
        taken = taken + 1
        canvas:newImageData():encode("png", ("shot%d.png"):format(taken))
        print("shot", taken, t)
    end
    if t > 6.1 then
        S.sheet()
        love.event.quit()
    end
end

function S.sheet()
    local t0 = love.timer.getTime()
    local cell, cols = 32, 16
    local rows = { { 0, 0 }, { 3, 0 }, { 0, 4 } }
    local data = love.image.newImageData(cell * cols, cell * #rows * 4)
    data:mapPixel(function() return T.RGB[1][1], T.RGB[1][2], T.RGB[1][3], 1 end)
    local n = 0
    for r, pose in ipairs(rows) do
        for hs = 0, 63 do
            local p = Frog.pose(hs, pose[1], pose[2])
            n = n + 1
            local cx = (hs % cols) * cell + cell / 2
            local cy = ((r - 1) * 4 + math.floor(hs / cols)) * cell + cell * 0.7
            for j = 0, p.h - 1 do
                for i = 0, p.w - 1 do
                    local k = p.key[j * p.w + i]
                    local x, y = cx - p.oi + i, cy - p.oj + j
                    if k ~= 0 and x >= 0 and y >= 0 and x < data:getWidth() and y < data:getHeight() then
                        local c = T.RGB[k]
                        data:setPixel(x, y, c[1], c[2], c[3], 1)
                    end
                end
            end
        end
    end
    print(("painted %d frog pictures in %.1f ms each"):format(n, (love.timer.getTime() - t0) * 1000 / n))
    data:encode("png", "sheet.png")
end

return S
