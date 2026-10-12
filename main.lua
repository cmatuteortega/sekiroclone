-- Frog: a prototype of a 3D world drawn the Survive School way.
--
-- Everything renders into a low-res canvas scaled up by a whole number, in the
-- eight colours of src/palette.lua and nothing else. The world is traced once
-- into one big picture with a depth buffer behind it (src/world.lua); each frame
-- the camera slides over it and the things that move -- the frog, the flies,
-- their shadows, the tongue, splashes -- are laid on top a pixel at a time, each
-- pixel kept only where it is nearer than the world there. So the frog goes
-- behind the trees and under the lips of ledges with nothing traced but itself,
-- and only when its pose or heading changes into one it has not been in yet.

local T = require "src.tracer"
local World = require "src.world"
local Frog = require "src.frog"
local Fly = require "src.fly"
local Font = require "src.font"

local floor, ceil, max, min, abs, sqrt = math.floor, math.ceil, math.max, math.min, math.abs, math.sqrt

local SHORT = 180 -- game pixels across the short edge of the window

local canvas, vw, vh, zoom
local world, painter, progress = nil, nil, 0
local frog, flies, eaten, total
local particles = {}
local camx, camy = 0, 0
local clock = 0
local jumpPressed, flickPressed = false, false
local script -- the --shots run's scripted thumb

--- the screen ----------------------------------------------------------------------

local function fit()
    local w, h = love.graphics.getDimensions()
    zoom = max(1, floor(min(w, h) / SHORT))
    vw, vh = ceil(w / zoom), ceil(h / zoom)
    canvas = love.graphics.newCanvas(vw, vh)
    canvas:setFilter("nearest", "nearest")
end

function love.resize() fit() end

--- points, grouped by colour -------------------------------------------------------

-- Everything laid over the world goes down as single pixels. They are gathered
-- per palette key and drawn as one batch of points per colour, so the only
-- setColor calls are the palette's own.
local batch = {}
local function clearBatch()
    for k = 1, #T.KEYS do batch[k] = batch[k] or {}; batch[k].n = 0 end
end
local function put(k, i, j)
    local b = batch[k]
    b[b.n + 1], b[b.n + 2] = i - floor(camx) + 0.5, j - floor(camy) + 0.5
    b.n = b.n + 2
end
local function flushBatch()
    for k = 1, #T.KEYS do
        local b = batch[k]
        if b.n > 0 then
            for n = b.n + 1, #b do b[n] = nil end
            love.graphics.setColor(T.RGB[k])
            love.graphics.points(b)
        end
    end
end

-- Is room depth d nearer than the world at image pixel (i, j)?
local function visible(i, j, d)
    if i < 0 or j < 0 or i >= world.w or j >= world.h then return true end
    return d >= world.dep[j * world.w + i] - 0.6
end

-- A picture laid down with its pivot at a room point.
local function stamp(pic, x, y, z)
    local si, sj, d = world:toImage(x, y, z)
    local bi, bj = floor(si) - pic.oi, floor(sj) - pic.oj
    local w = pic.w
    for pj = 0, pic.h - 1 do
        for pi = 0, w - 1 do
            local n = pj * w + pi
            local k = pic.key[n]
            if k ~= 0 and visible(bi + pi, bj + pj, d + pic.dep[n]) then put(k, bi + pi, bj + pj) end
        end
    end
end

-- A shadow straight down onto whatever faces up under (x, z) and below y: each
-- pixel there goes one step darker, the way ink stacks on a printed line.
local function shadow(x, y, z, r)
    local wx, wy, wz, up, key = world.wx, world.wy, world.wz, world.up, world.key
    local i0 = floor((x - r) / T.UNIT) - world.i0
    local i1 = ceil((x + r) / T.UNIT) - world.i0
    local _, j0 = world:toImage(x, y + 1, z - r)
    local _, j1 = world:toImage(x, -1, z + r)
    for j = max(0, floor(j0)), min(world.h - 1, ceil(j1)) do
        for i = max(0, i0), min(world.w - 1, i1) do
            local n = j * world.w + i
            if up[n] == 1 and wy[n] <= y + 0.5 and (wx[n] - x) ^ 2 + (wz[n] - z) ^ 2 <= r * r then
                put(T.DARKER[key[n]], i, j)
            end
        end
    end
end

-- A line plotted through the room, a pixel at a time, depth tested along it.
local function line3(x0, y0, z0, x1, y1, z1, k)
    local i0, j0, d0 = world:toImage(x0, y0, z0)
    local i1, j1, d1 = world:toImage(x1, y1, z1)
    local steps = max(1, ceil(max(abs(i1 - i0), abs(j1 - j0))))
    for s = 0, steps do
        local t = s / steps
        local i, j = floor(i0 + (i1 - i0) * t), floor(j0 + (j1 - j0) * t)
        if visible(i, j, d0 + (d1 - d0) * t + 1) then put(k, i, j) end
    end
end

--- the run ---------------------------------------------------------------------------

local function start()
    frog = Frog.new(world)
    flies, eaten = {}, 0
    for n, f in ipairs(world.flies) do flies[n] = Fly.new(f.x, f.y, f.z, n) end
    total = #flies
    particles = {}
    clock = 0
    local si, sj = world:toImage(frog.x, frog.y, frog.z)
    camx, camy = si - vw / 2, sj - vh / 2
end

local function burst(x, y, z, n, keys, speed)
    for _ = 1, n do
        local a, u = love.math.random() * 2 * math.pi, love.math.random()
        particles[#particles + 1] = {
            x = x, y = y, z = z,
            vx = math.cos(a) * speed * u, vy = speed * (0.6 + love.math.random()), vz = math.sin(a) * speed * u,
            life = 0.4 + love.math.random() * 0.3, k = T.IDX[keys[love.math.random(#keys)]],
        }
    end
end

local function nearestFly(mx, my, mz)
    local best, bd
    local c, s = math.cos(frog.h), math.sin(frog.h)
    for _, f in ipairs(flies) do
        local dx, dy, dz = f.x - mx, f.y - my, f.z - mz
        local d = sqrt(dx * dx + dy * dy + dz * dz)
        if d < Frog.TONGUE + 4 and (dx * c + dz * s) > 0.45 * d and (not bd or d < bd) then best, bd = f, d end
    end
    return best
end

local function thumb()
    local k = love.keyboard.isDown
    local mx = (k("right", "d") and 1 or 0) - (k("left", "a") and 1 or 0)
    local mz = (k("down", "s") and 1 or 0) - (k("up", "w") and 1 or 0)
    local held = k("space", "z", "k")
    if love.joystick then
        for _, j in ipairs(love.joystick.getJoysticks()) do
            if j:isGamepad() then
                local ax, ay = j:getGamepadAxis("leftx"), j:getGamepadAxis("lefty")
                if abs(ax) > 0.25 or abs(ay) > 0.25 then mx, mz = ax, ay end
                held = held or j:isGamepadDown("a")
            end
        end
    end
    return mx, mz, held
end

function love.load(args)
    love.graphics.setDefaultFilter("nearest", "nearest")
    love.graphics.setLineStyle("rough")
    love.graphics.setPointSize(1)
    fit()
    world = World.new()
    painter = coroutine.create(function() world:paint() end)
    for _, a in ipairs(args or {}) do
        if a == "--shots" then script = require("src.script") end
    end
end

function love.keypressed(key)
    if key == "escape" then love.event.quit() end
    if key == "f11" or (key == "return" and love.keyboard.isDown("lalt", "ralt")) then
        love.window.setFullscreen(not love.window.getFullscreen())
        fit()
    end
    if key == "space" or key == "z" or key == "k" then jumpPressed = true end
    if key == "x" or key == "j" or key == "lshift" then flickPressed = true end
    if key == "r" and frog then start() end
end

function love.gamepadpressed(_, b)
    if b == "a" then jumpPressed = true end
    if b == "x" or b == "b" then flickPressed = true end
end

function love.update(dt)
    if painter then
        local t0 = love.timer.getTime()
        -- Paint in slices, so the window keeps answering while the pond goes down.
        while coroutine.status(painter) ~= "dead" and love.timer.getTime() - t0 < 1 / 30 do
            local ok, p = coroutine.resume(painter)
            if not ok then error(p) end
            progress = p or 1
        end
        if coroutine.status(painter) == "dead" then
            painter = nil
            start()
        end
        return
    end
    dt = min(dt, 1 / 30)
    if script then dt = 1 / 30 end
    clock = clock + dt

    local mx, mz, held = thumb()
    if script then
        local s = script.at(clock)
        mx, mz, held = s.mx or 0, s.mz or 0, s.held
        jumpPressed = jumpPressed or s.jump
        flickPressed = flickPressed or s.flick
    end

    local events = {}
    if flickPressed then
        local m1, m2, m3 = frog:tongueEnds()
        events.aim = nearestFly(m1, m2, m3)
    end
    frog:update(dt, mx, mz, jumpPressed, held, flickPressed, events)
    jumpPressed, flickPressed = false, false
    if events.splash then burst(frog.x, 0.5, frog.z, 22, { "w", "c", "b" }, 40) end
    if events.land then burst(frog.x, frog.y + 0.5, frog.z, 5, { "g", "w" }, 14) end
    if events.bounce then burst(frog.x, frog.y + 1, frog.z, 10, { "k", "w" }, 30) end

    for n = #flies, 1, -1 do
        local f = flies[n]
        f:update(dt)
        if frog.tongue > 0.2 then
            local _, _, _, tx, ty, tz = frog:tongueEnds()
            if (f.x - tx) ^ 2 + (f.y - ty) ^ 2 + (f.z - tz) ^ 2 < 25 then
                table.remove(flies, n)
                eaten = eaten + 1
                burst(f.x, f.y, f.z, 12, { "r", "k", "w" }, 26)
            end
        end
    end

    for n = #particles, 1, -1 do
        local p = particles[n]
        p.life = p.life - dt
        p.vy = p.vy - 220 * dt
        p.x, p.y, p.z = p.x + p.vx * dt, p.y + p.vy * dt, p.z + p.vz * dt
        if p.life <= 0 or p.y < -1 then table.remove(particles, n) end
    end

    -- The camera follows the frog's feet, and stays over the painted pond.
    local si, sj = world:toImage(frog.x, frog.y, frog.z)
    local tx, ty = si - vw / 2, sj - vh / 2
    local f = min(1, dt * 6)
    camx, camy = camx + (tx - camx) * f, camy + (ty - camy) * f
    camx = max(0, min(world.w - vw, camx))
    camy = max(0, min(world.h - vh, camy))

    if script then script.after(clock, canvas) end
end

--- drawing -------------------------------------------------------------------------

local function box(x, y, w, h)
    love.graphics.setColor(T.RGB[T.IDX.o])
    love.graphics.rectangle("fill", x - 1, y - 1, w + 2, h + 2)
    love.graphics.setColor(T.RGB[T.IDX.w])
    love.graphics.rectangle("fill", x, y, w, h)
end

local function label(text, x, y)
    box(x - 2, y - 2, Font.width(text) + 4, 9)
    love.graphics.setColor(T.RGB[T.IDX.o])
    Font.print(text, x, y)
end

local function drawLoading()
    love.graphics.clear(unpack(T.RGB[T.IDX.w]))
    local text = "PAINTING THE POND"
    local w = 80
    local x, y = floor((vw - w) / 2), floor(vh / 2)
    love.graphics.setColor(T.RGB[T.IDX.o])
    Font.print(text, floor((vw - Font.width(text)) / 2), y - 10)
    love.graphics.rectangle("fill", x - 1, y - 1, w + 2, 6)
    love.graphics.setColor(T.RGB[T.IDX.w])
    love.graphics.rectangle("fill", x, y, w, 4)
    love.graphics.setColor(T.RGB[T.IDX.b])
    love.graphics.rectangle("fill", x, y, floor(w * progress), 4)
end

local function drawWorld()
    love.graphics.clear(unpack(T.RGB[T.IDX.c]))
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(world.image, -floor(camx), -floor(camy))

    clearBatch()
    -- Shadows first: they are on the world, under everything that moves.
    if not frog.sunk then
        local g = world:topAt(frog.x, frog.z) or 0
        local r = max(2.5, 5.5 - (frog.y - g) * 0.08)
        shadow(frog.x, frog.y + 1, frog.z, r)
    end
    for _, f in ipairs(flies) do shadow(f.x, f.y - 2, f.z, 1.6) end

    -- Then the movers, furthest first.
    local movers = {}
    for _, f in ipairs(flies) do
        local _, _, d = T.project(f.x, f.y, f.z)
        movers[#movers + 1] = { d = d, draw = function() stamp(f:picture(), f.x, f.y, f.z) end }
    end
    if not frog.sunk then
        local _, _, d = T.project(frog.x, frog.y, frog.z)
        movers[#movers + 1] = { d = d, draw = function()
            local y = frog.y + (frog.bob or 0)
            local behind = math.sin(frog.h) < 0
            local function tongue()
                if frog.tongue > 0 then
                    local x0, y0, z0, x1, y1, z1 = frog:tongueEnds()
                    line3(x0, y0, z0, x1, y1, z1, T.IDX.r)
                    line3(x0, y0 - 0.6, z0, x1, y1 - 0.6, z1, T.IDX.r)
                    local i, j = world:toImage(x1, y1, z1)
                    for dj = -1, 0 do for di = -1, 0 do put(T.IDX.k, floor(i) + di, floor(j) + dj) end end
                end
            end
            -- Painter's order for the one thin thing: facing away, the body
            -- covers the tongue; otherwise the tongue is laid over the body.
            if behind then tongue() end
            stamp(frog:picture(), frog.x, y, frog.z)
            if not behind then tongue() end
        end }
    end
    table.sort(movers, function(a, b) return a.d < b.d end)
    for _, m in ipairs(movers) do m.draw() end

    for _, p in ipairs(particles) do
        local i, j, d = world:toImage(p.x, p.y, p.z)
        i, j = floor(i), floor(j)
        if visible(i, j, d + 1) then put(p.k, i, j) end
    end
    flushBatch()

    -- The page's lettering.
    label("FLIES " .. eaten .. "/" .. total, 4 + 2, 4 + 2)
    if clock < 8 and not script then
        local hint = "ARROWS RUN  SPACE JUMP  X TONGUE"
        label(hint, floor((vw - Font.width(hint)) / 2), vh - 12)
    end
    if eaten == total and total > 0 then
        local text = "EVERY FLY EATEN!  R TO PLAY AGAIN"
        label(text, floor((vw - Font.width(text)) / 2), floor(vh / 2) - 30)
    end
end

function love.draw()
    love.graphics.setCanvas(canvas)
    if painter then drawLoading() else drawWorld() end
    love.graphics.setCanvas()
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(canvas, 0, 0, 0, zoom, zoom)
end
