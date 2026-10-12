-- The whole palette: eight colours, and nothing may be drawn outside this list.
-- Every module pulls from here rather than writing literal rgb.

local function hex(s)
    return {
        tonumber(s:sub(1, 2), 16) / 255,
        tonumber(s:sub(3, 4), 16) / 255,
        tonumber(s:sub(5, 6), 16) / 255,
    }
end

local Palette = {
    paper    = hex("e6ecef"), -- page background
    graphite = hex("b2b1c0"), -- pencil grain, shadows
    slate    = hex("5b4f6e"), -- mid ink
    ink      = hex("280732"), -- darkest ink, outlines
    -- Red is the other side and blue is yours, in every module. Blush and sky
    -- are their light ends and a matched pair -- blush darkens to red over a
    -- rule exactly as sky darkens to blue -- so light-fill-with-darker-edge art
    -- keeps its shape when recoloured from one side to the other. Red also
    -- means armed/hot/full in the HUD, which is drawn after the overprint pass
    -- and so is never read against a run.
    red      = hex("e15e6e"), -- enemies, their shots and puddles, hit sparks
    blush    = hex("f3a8a8"), -- soft pink fill, the margin line
    blue     = hex("7194f0"), -- the player: pen, shots, rocket, beam
    sky      = hex("abc9f1"), -- ruled lines, light blue fill
}

-- Single-character keys used by the ASCII pixel-art in src/sprites.lua.
Palette.key = {
    w = Palette.paper,
    g = Palette.graphite,
    s = Palette.slate,
    o = Palette.ink,
    r = Palette.red,
    k = Palette.blush,
    b = Palette.blue,
    c = Palette.sky,
}

-- Ink is not paint: a mark over a printed rule stacks with it and comes out one
-- step darker, keeping its hue where the palette has a darker shade of it and
-- falling back to the neutral ramp where it doesn't. Two never move -- ink is
-- already the darkest thing on the page, and paper is an eraser, so it wipes
-- rather than stacks. Eight marks by four surfaces is the whole interaction;
-- src/overprint.lua applies it, and both tables are sized off these lists, so a
-- fifth surface is one more column here and nothing else. "Cut away" is the
-- paper the scissors' last level lifts off (src/scissors.lua); its column
-- deliberately copies the ruled one, spelled out so the shader's nearest-match
-- never has to guess the day graphite is retuned.
Palette.marks = { "paper", "graphite", "slate", "ink", "sky", "blue", "blush", "red" }
Palette.surfaces = { "paper", "sky", "blush", "graphite" }

Palette.overprint = {
    --           blank       ruled line  margin line cut away
    paper    = { "paper",    "paper",    "paper",    "paper" },  -- erases; never stacks
    graphite = { "graphite", "slate",    "slate",    "slate" },
    slate    = { "slate",    "ink",      "ink",      "ink" },
    ink      = { "ink",      "ink",      "ink",      "ink" },    -- already the darkest
    sky      = { "sky",      "blue",     "blue",     "blue" },
    blue     = { "blue",     "slate",    "slate",    "slate" },  -- no darker blue exists
    blush    = { "blush",    "red",      "red",      "red" },
    red      = { "red",      "slate",    "slate",    "slate" },  -- no darker red exists
}

return Palette
