# Frog

A LÖVE prototype: a frog hopping round a pond in a 3D world, drawn with Survive
School's 3D method (`3dmethod.md` and `src/solid.lua` there). It uses the same
eight colours, whole pixels, ray-traced closed-form solids, shading ramps,
creases and ink.

```sh
love .                 # LÖVE 11.x
love . --shots         # dev: scripted run, writes screenshots + a frog turntable
                       # sheet to the save directory, then quits
```

**Controls:** arrows / WASD to run, Space (or Z) to jump (hold it for a higher
jump), X (or J) to flick the tongue, R to restart, F11 for fullscreen, Esc to
quit. A gamepad works too: left stick, A to jump, X/B for the tongue.

Eat all nine flies. They hover over the islands and the lily pads. Landing on a
mushroom throws you up high. If you fall in the water you go back to the last
place you stood.

## How it is drawn

What carries over from Survive School unchanged:

- **The camera** is the bake's camera: orthographic, looking down at the floor
  from 34°, with a fixed lamp up, to the left and towards you. Room space is
  x right, y up, z towards the viewer.
- **One ray per pixel, at its centre.** Each pixel's colour is *chosen* from a
  palette ramp (glint, lit, middle, shadow, plus the bounce-light row), never
  blended, so no ninth colour can appear. There is no alpha anywhere.
- **Creases**: where two neighbouring pixels of the same material have normals
  that disagree (dot below 0.55), the darker one steps down to the ramp's shadow.
- **Ink** goes round the silhouette and along any step in depth where the nearer
  pixel belongs to another part.
- **Print, not geometry**, for anything that has to read: the ruled lines and
  margin on the ground, the frog's pupils, the mushroom's spots, the stump's
  rings and the pad's veins are all tested at the hit point and painted in.
- **Poses are numbers.** The frog has `crouch` and `stretch`. Its picture is kept
  by heading (1/64 of a turn) and by each pose number to a few steps, and shared.
  A picture costs about 1 ms to paint and is painted in the frame it is first
  needed.

What is new, because this is a world and not a boss on a page:

- **The world is painted once.** The camera never turns and has no perspective,
  so a picture of the world is the same picture wherever the camera is. At load
  the whole pond is traced into one image (~50 ms with LuaJIT) together with a
  **depth buffer** and the room position of every pixel. The camera slides over
  that image.
- **Movers are depth-tested against it.** Every pixel of the frog, the flies,
  the tongue and the splashes is placed only where it is nearer than the world
  at that pixel. That is how the frog goes behind the blossom trees and drops
  behind ledges without the world being traced again.
- **Shadows are overprint.** Under anything that moves, the world pixels that face
  up and lie below it, inside its footprint, go one step darker by the palette's
  overprint table, the same way ink stacks on a ruled line. That works on water,
  pads and paper alike.
- **The tongue is plotted, not traced**, the way the metronome's pendulum is: a
  line through the room drawn through the same projection, depth-tested along its
  length, with painter's order by heading against the body.
- **The world is an ASCII map** (`MAP` in `src/world.lua`), one character per
  16-unit tile, so the map itself is the art.

The one number that differs is `UNIT`: 0.6 model units to a pixel instead of
0.92, so the hero is half as big again on a 320×180 canvas.

## Files

| file | what it is |
| --- | --- |
| `main.lua` | canvas fit (whole-number zoom off the short edge), load screen, camera, compositing, HUD |
| `src/tracer.lua` | camera, lamp, ramps, crease and ink passes, affine maps, the ellipsoid-body painter |
| `src/world.lua` | the map, its solids (boxes, vertical cylinders, ellipsoids, the water plane), the one-time paint, collision tops |
| `src/frog.lua` | the frog model, its pose numbers and picture cache, run / jump / tongue physics |
| `src/fly.lua` | the flies: two wing-beat pictures shared by all of them |
| `src/palette.lua` | Survive School's eight colours and overprint table, unchanged |
| `src/font.lua` | Survive School's 3x5 face (caps, digits, punctuation) |
| `src/script.lua` | dev only: the `--shots` run |

## Extending

- **A new prop**: add a map character to `ON` in `src/world.lua` and a branch
  that `add`s its solids (`box`, `cyl`, `ell`) with a material and `collide`s
  its top. A new material is a row in `MAT`: a ramp and an optional `print`.
- **A new creature**: a `parts` function returning ellipsoids (`at` map, `ramp`,
  `id`, optional `print`) handed to `T.paint`, kept by whatever its picture
  depends on, and laid down with `stamp` in `main.lua`. Before you put it in
  the game, paint every heading into one sheet and look at it (see
  `src/script.lua`'s `S.sheet`).
- **A turning camera** would cost the one-time world paint, because the world
  would need repainting whenever the camera turns. Keeping the camera fixed is
  what makes this cheap.
