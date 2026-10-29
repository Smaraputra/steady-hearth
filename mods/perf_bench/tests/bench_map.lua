-- Shared map definition for the XL benchmark (scenario xl-v4): the terrain the world generator
-- builds and every coordinate the scenario places things at, so the two always agree. Pure Lua with
-- no game API, so it also runs outside the game. Rectangles are { x0, z0, x1, z1 } in world voxels
-- with the maximum exclusive. Heights are standing heights: the y a hearthling stands at.
local bench_map = {}

bench_map.SCENARIO = 'xl-v4'
bench_map.MIN, bench_map.MAX = -256, 256
bench_map.PLAIN_Y = 10           -- soil to y 9, one layer of grass, so the plain is stood on at y 10
bench_map.EDGE_MARGIN = 4        -- nothing is placed closer than this to the map edge

-- player_1 is created by the autotest environment, while the others are added by the scenario.
bench_map.TOWNS = {
   { id = 'player_1', kingdom = nil, cx = -128, cz = -128 },
   { id = 'player_2', kingdom = 'rayyas_children:kingdoms:rayyas_children', cx = 128, cz = -128 },
   { id = 'player_3', kingdom = 'northern_alliance:kingdoms:northern_alliance', cx = -128, cz = 128 },
   { id = 'player_4', kingdom = 'stonehearth:kingdoms:ascendancy', cx = 128, cz = 128 },
}

-- Two ridges cross at the map centre: 'ns' runs north-south along x = 0, 'ew' runs east-west along
-- z = 0. Across its axis a ridge covers -10 .. 10 in 5 terraces, each 2 voxels high and 1 deep, so
-- nobody can step up a side (the walking step is 1 voxel). The crest (-6 .. 6) is flat at y 20.
local RIDGE_HALF = 10
local RIDGE_STEPS = 5
local RISER = 2
local CREST_HALF = RIDGE_HALF - RIDGE_STEPS + 1
bench_map.CREST_Y = bench_map.PLAIN_Y + RIDGE_STEPS * RISER

-- One pass per ridge arm, halfway between two neighbouring towns: a staircase 5 wide with a 1-voxel
-- rise per 1-voxel tread on each face, from the plain (|across| = 17) up to the crest (|across| = 7).
local PASS_LO, PASS_HI = -2, 3
local STAIR_IN = CREST_HALF + 1
local STAIR_OUT = STAIR_IN + (bench_map.CREST_Y - bench_map.PLAIN_Y) - 1
bench_map.PASSES = {
   { ridge = 'ns', at = -128 },   -- between player_1 and player_2
   { ridge = 'ns', at = 128 },    -- between player_3 and player_4
   { ridge = 'ew', at = -128 },   -- between player_1 and player_3
   { ridge = 'ew', at = 128 },    -- between player_2 and player_4
}

-- One lake per town, 12 x 10, north-east of the town centre. Its floor steps down 1 voxel per ring
-- (9, 8, 7), so anyone in it can climb out. The water fills it to 2.5 above the deepest floor
-- (surface at y 9.5); a non-integer level does not evaporate while it stays unchanged.
local LAKE = { dx0 = 36, dz0 = -36, dx1 = 48, dz1 = -26, rings = 3 }
bench_map.LAKE_HEIGHT = 2.5

local function rect(x0, z0, x1, z1)
   return { x0 = x0, z0 = z0, x1 = x1, z1 = z1 }
end

local function sign(v)
   return v < 0 and -1 or 1
end

function bench_map.intersects(a, b)
   return a.x0 < b.x1 and b.x0 < a.x1 and a.z0 < b.z1 and b.z0 < a.z1
end

function bench_map.grow(r, n)
   return rect(r.x0 - n, r.z0 - n, r.x1 + n, r.z1 + n)
end

-- Standing height of a ridge at a column `across` voxels from its axis, or nil off the ridge.
local function ridge_y(across)
   local d = math.abs(across)
   if d > RIDGE_HALF then
      return nil
   end
   return bench_map.PLAIN_Y + RISER * math.min(RIDGE_STEPS, RIDGE_HALF + 1 - d)
end

local function stair_y(across)
   local d = math.abs(across)
   if d < STAIR_IN or d > STAIR_OUT then
      return nil
   end
   return bench_map.CREST_Y - (d - STAIR_IN)
end

-- The pass's footprint: the staircases on both faces and the crest between them.
function bench_map.pass_rect(pass)
   if pass.ridge == 'ns' then
      return rect(-STAIR_OUT, pass.at + PASS_LO, STAIR_OUT + 1, pass.at + PASS_HI)
   end
   return rect(pass.at + PASS_LO, -STAIR_OUT, pass.at + PASS_HI, STAIR_OUT + 1)
end

function bench_map.ridge_rects()
   return {
      rect(-RIDGE_HALF, bench_map.MIN, RIDGE_HALF + 1, bench_map.MAX),
      rect(bench_map.MIN, -RIDGE_HALF, bench_map.MAX, RIDGE_HALF + 1),
   }
end

-- Lake rings from the outside in, each with its floor height.
function bench_map.lake_rings(town)
   local rings = {}
   for i = 0, LAKE.rings - 1 do
      local r = rect(town.cx + LAKE.dx0 + i, town.cz + LAKE.dz0 + i, town.cx + LAKE.dx1 - i, town.cz + LAKE.dz1 - i)
      r.floor_y = bench_map.PLAIN_Y - 1 - i
      table.insert(rings, r)
   end
   return rings
end

function bench_map.lake_rect(town)
   return rect(town.cx + LAKE.dx0, town.cz + LAKE.dz0, town.cx + LAKE.dx1, town.cz + LAKE.dz1)
end

-- Standing height of the terrain at column (x, z).
function bench_map.surface_y(x, z)
   for _, town in ipairs(bench_map.TOWNS) do
      local rings = bench_map.lake_rings(town)
      if bench_map.intersects(rings[1], rect(x, z, x + 1, z + 1)) then
         local y = rings[1].floor_y
         for _, ring in ipairs(rings) do
            if x >= ring.x0 and x < ring.x1 and z >= ring.z0 and z < ring.z1 then
               y = ring.floor_y
            end
         end
         return y
      end
   end
   local y = bench_map.PLAIN_Y
   y = math.max(y, ridge_y(x) or y, ridge_y(z) or y)
   for _, pass in ipairs(bench_map.PASSES) do
      local across, along = x, z
      if pass.ridge == 'ew' then
         across, along = z, x
      end
      if along >= pass.at + PASS_LO and along < pass.at + PASS_HI then
         y = math.max(y, stair_y(across) or y)
      end
   end
   return y
end

-- Solid terrain the world generator adds above the plain, as world-space boxes { x0, y0, z0, x1, y1,
-- z1, block } with block a name from terrain_blocks.json: rock bodies with a grass top on every
-- terrace and stair tread.
function bench_map.terrain_boxes()
   local boxes = {}
   local function box(x0, y0, z0, x1, y1, z1, block)
      table.insert(boxes, { x0 = x0, y0 = y0, z0 = z0, x1 = x1, y1 = y1, z1 = z1, block = block })
   end
   local function across_box(ridge, a0, a1, l0, l1, y0, y1, block)
      if ridge == 'ns' then
         box(a0, y0, l0, a1, y1, l1, block)
      else
         box(l0, y0, a0, l1, y1, a1, block)
      end
   end
   for _, ridge in ipairs({ 'ns', 'ew' }) do
      for k = 0, RIDGE_STEPS - 1 do
         local y0 = bench_map.PLAIN_Y + RISER * k
         local a0, a1 = -RIDGE_HALF + k, RIDGE_HALF + 1 - k
         across_box(ridge, a0, a1, bench_map.MIN, bench_map.MAX, y0, y0 + RISER - 1, 'rock_layer_1')
         across_box(ridge, a0, a1, bench_map.MIN, bench_map.MAX, y0 + RISER - 1, y0 + RISER, 'grass_hills')
      end
   end
   for _, pass in ipairs(bench_map.PASSES) do
      for d = STAIR_IN, STAIR_OUT do
         local top = stair_y(d)
         for _, across in ipairs({ -d, d }) do
            if top - 1 > bench_map.PLAIN_Y then
               across_box(pass.ridge, across, across + 1, pass.at + PASS_LO, pass.at + PASS_HI,
                          bench_map.PLAIN_Y, top - 1, 'rock_layer_1')
            end
            across_box(pass.ridge, across, across + 1, pass.at + PASS_LO, pass.at + PASS_HI,
                       top - 1, top, 'grass_hills')
         end
      end
   end
   return boxes
end

-- Grids the scenario places entities on, relative to the town centre (see bench_lib.grid), with the
-- footprint of one entity as offsets from its grid point. Shared so that layout lines and exclusion
-- zones come from the same numbers as the placement.
bench_map.GRIDS = {
   full_chests = { dx = -40, dz = -40, cols = 8, n = 16, spacing = 3, foot = { -1, 1 } },
   empty_chests = { dx = -40, dz = -30, cols = 8, n = 8, spacing = 3, foot = { -1, 1 } },
   food = { dx = -40, dz = -22, cols = 15, n = 60, spacing = 1, foot = { 0, 1 } },
   haul = { dx = 10, dz = -60, cols = 15, n = 150, spacing = 1, foot = { 0, 1 } },
   forest = { dx = -100, dz = -20, cols = 5, n = 40, spacing = 5, foot = { -2, 3 } },
   buildings = { dx = 14, dz = 14, cols = 4, spacing = 26 },
   beds = { dx = -40, dz = 30, cols = 6, spacing = 3, foot = { -1, 2 } },
   seats = { dx = -40, dz = 45, cols = 6, spacing = 2, foot = { 0, 1 } },
}

-- Fixed areas relative to the town centre.
bench_map.AREAS = {
   stockpile_a = { dx = -15, dz = -40, w = 8, l = 8 },
   stockpile_b = { dx = -5, dz = -40, w = 8, l = 8 },
   hill_mine = { dx = -60, dz = -60, w = 12, l = 12, h = 4 },
   pit_mine = { dx = -60, dz = 40, w = 10, l = 10, d = 3 },
   farm = { dx = 20, dz = -85, w = 10, l = 10 },
}

-- Crafter workbenches at (cx + BENCH_DX, cz + 5 + 4 i), the crafter beside each at CRAFTER_DX.
bench_map.BENCH_DX, bench_map.CRAFTER_DX = -20, -16

-- Supply yard of the i-th building under construction: every item it needs, packed in rows of
-- YARD_WIDTH at spacing 1, south of the building grid.
bench_map.YARD_WIDTH, bench_map.YARD_ROWS = 20, 4
function bench_map.supply_yard(town, i)
   local x0, z0 = town.cx + 14 + (i - 1) * 26, town.cz + 86
   return rect(x0, z0, x0 + bench_map.YARD_WIDTH, z0 + bench_map.YARD_ROWS)
end

-- Raid parties appear on open ground north-east of the town centre, outside every building and
-- within sight (64 voxels) of the citizens, so they engage as before without spawning in a house.
function bench_map.raid_spawn(town)
   return town.cx + 50, town.cz - 10
end

-- The whole town, for keeping wild trees and rabbits out of it.
function bench_map.town_envelope(town)
   return rect(town.cx - 102, town.cz - 85, town.cx + 103, town.cz + 90)
end

-- Points for the connectivity check: the town's open ground, the bottom of its lake, and for each
-- pass next to the town the crest on the pass and the foot of the stairs on the far side.
function bench_map.probe_points(town)
   local points = {
      origin = { x = town.cx + 2, y = bench_map.PLAIN_Y, z = town.cz + 2 },
      lake_bottom = { x = town.cx + 42, y = bench_map.PLAIN_Y - LAKE.rings, z = town.cz - 31 },
   }
   for _, pass in ipairs(bench_map.PASSES) do
      if pass.ridge == 'ns' and sign(pass.at) == sign(town.cz) then
         points['crest_ns'] = { x = 0, y = bench_map.CREST_Y, z = pass.at }
         points['far_ns'] = { x = -sign(town.cx) * (STAIR_OUT + 1), y = bench_map.PLAIN_Y, z = pass.at }
      elseif pass.ridge == 'ew' and sign(pass.at) == sign(town.cx) then
         points['crest_ew'] = { x = pass.at, y = bench_map.CREST_Y, z = 0 }
         points['far_ew'] = { x = pass.at, y = bench_map.PLAIN_Y, z = -sign(town.cz) * (STAIR_OUT + 1) }
      end
   end
   return points
end

-- Park-Miller minimal standard generator: every product stays below 2^53, so it is exact in Lua's
-- doubles and gives the same sequence on every run and every runtime.
function bench_map.lcg(seed)
   local state = seed % 2147483647
   if state <= 0 then
      state = state + 2147483646
   end
   return function()
      state = (state * 16807) % 2147483647
      return (state - 1) / 2147483646
   end
end

-- Wild tree footprints as offsets from the entity's position (collision boxes in the entity json).
bench_map.TREE_KINDS = {
   { uri = 'stonehearth:trees:oak:small', foot = { -2, 2 }, weight = 2 },
   { uri = 'stonehearth:trees:oak:medium', foot = { -2, 3 }, weight = 1 },
}

-- Places n wild trees and the rabbits outside the towns: on the ridge crests, the foothills, the
-- corridors between towns and the outer margins. A tree needs level ground under its whole
-- footprint and a free voxel around it. Returns trees { uri, x, z, rect, crest } and rabbits { x, z }.
function bench_map.scatter(num_trees, num_rabbits, seed)
   local rand = bench_map.lcg(seed)
   local blocked = {}
   for _, town in ipairs(bench_map.TOWNS) do
      table.insert(blocked, bench_map.grow(bench_map.town_envelope(town), 4))
   end
   for _, pass in ipairs(bench_map.PASSES) do
      table.insert(blocked, bench_map.grow(bench_map.pass_rect(pass), 3))
   end
   local lo, hi = bench_map.MIN + bench_map.EDGE_MARGIN, bench_map.MAX - bench_map.EDGE_MARGIN
   local total_weight = 0
   for _, kind in ipairs(bench_map.TREE_KINDS) do
      total_weight = total_weight + kind.weight
   end

   local function free(r)
      if r.x0 < lo or r.z0 < lo or r.x1 > hi or r.z1 > hi then
         return false
      end
      for _, b in ipairs(blocked) do
         if bench_map.intersects(r, b) then
            return false
         end
      end
      return true
   end

   local function level(r)
      local y = bench_map.surface_y(r.x0, r.z0)
      for x = r.x0, r.x1 - 1 do
         for z = r.z0, r.z1 - 1 do
            if bench_map.surface_y(x, z) ~= y then
               return nil
            end
         end
      end
      return y
   end

   local trees, attempts = {}, 0
   while #trees < num_trees and attempts < 50000 do
      attempts = attempts + 1
      local pick = rand() * total_weight
      local kind = bench_map.TREE_KINDS[#bench_map.TREE_KINDS]
      for _, k in ipairs(bench_map.TREE_KINDS) do
         if pick < k.weight then
            kind = k
            break
         end
         pick = pick - k.weight
      end
      local x = lo + math.floor(rand() * (hi - lo))
      local z = lo + math.floor(rand() * (hi - lo))
      local r = rect(x + kind.foot[1], z + kind.foot[1], x + kind.foot[2], z + kind.foot[2])
      if free(r) then
         local y = level(r)
         if y and y >= bench_map.PLAIN_Y then
            table.insert(trees, { uri = kind.uri, x = x, z = z, y = y, rect = r, crest = y == bench_map.CREST_Y })
            table.insert(blocked, bench_map.grow(r, 1))
         end
      end
   end

   local rabbits = {}
   attempts = 0
   while #rabbits < num_rabbits and attempts < 50000 do
      attempts = attempts + 1
      local x = lo + math.floor(rand() * (hi - lo))
      local z = lo + math.floor(rand() * (hi - lo))
      local r = rect(x, z, x + 1, z + 1)
      if free(r) and bench_map.surface_y(x, z) == bench_map.PLAIN_Y then
         table.insert(rabbits, { x = x, z = z })
         table.insert(blocked, r)
      end
   end
   return trees, rabbits
end

-- Wild trees on a ridge crest that each town's workers are asked to harvest: the n crest trees
-- nearest to the town centre, each assigned to one town only.
function bench_map.crest_harvests(trees, n)
   local taken, result = {}, {}
   for _, town in ipairs(bench_map.TOWNS) do
      local candidates = {}
      for i, tree in ipairs(trees) do
         if tree.crest and not taken[i] then
            local dx, dz = tree.x - town.cx, tree.z - town.cz
            table.insert(candidates, { index = i, d2 = dx * dx + dz * dz })
         end
      end
      table.sort(candidates, function(a, b)
            if a.d2 ~= b.d2 then
               return a.d2 < b.d2
            end
            return a.index < b.index
         end)
      result[town.id] = {}
      for j = 1, math.min(n, #candidates) do
         taken[candidates[j].index] = true
         table.insert(result[town.id], candidates[j].index)
      end
   end
   return result
end

-- 31-bit string hash (djb2, exact in doubles), for the layout fingerprint.
function bench_map.hash(text, h)
   h = h or 5381
   for i = 1, #text do
      h = (h * 33 + text:byte(i)) % 2147483647
   end
   return h
end

return bench_map
