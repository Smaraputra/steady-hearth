-- Large world (512 x 512) for the 4-player XL benchmark: bedrock, 9 layers of soil and one layer of
-- grass, two crossing ridges with a stepped pass on each arm, and a lake beside every town. All
-- coordinates come from bench_map, which the scenario shares.
local Point3 = _radiant.csg.Point3
local Cube3 = _radiant.csg.Cube3
local Region3 = _radiant.csg.Region3
local bench_map = require 'perf_bench.tests.bench_map'

function create_world(environment)
   stonehearth.world_generation:create_empty_world()
   local block_types = radiant.terrain.get_block_types()
   local lo, hi = bench_map.MIN, bench_map.MAX

   -- built in world coordinates
   local region3 = Region3()
   region3:add_cube(Cube3(Point3(lo, -2, lo), Point3(hi, 0, hi), block_types.bedrock))
   region3:add_cube(Cube3(Point3(lo, 0, lo), Point3(hi, bench_map.PLAIN_Y - 1, hi), block_types.soil_dark))
   region3:add_cube(Cube3(Point3(lo, bench_map.PLAIN_Y - 1, lo), Point3(hi, bench_map.PLAIN_Y, hi), block_types.grass))
   for _, b in ipairs(bench_map.terrain_boxes()) do
      region3:add_cube(Cube3(Point3(b.x0, b.y0, b.z0), Point3(b.x1, b.y1, b.z1), block_types[b.block]))
   end

   -- lake basins: each ring is dug from its floor up to the plain
   local lakes = {}
   for _, town in ipairs(bench_map.TOWNS) do
      local water = Region3()
      for _, ring in ipairs(bench_map.lake_rings(town)) do
         local cube = Cube3(Point3(ring.x0, ring.floor_y, ring.z0), Point3(ring.x1, bench_map.PLAIN_Y, ring.z1))
         region3:subtract_cube(cube)
         water:add_cube(cube)
      end
      table.insert(lakes, water)
   end

   local terrain = radiant._root_entity:add_component('terrain')
   terrain:add_tile(region3)

   -- filled before hydrology starts, as world generation does for its own lakes
   for _, water in ipairs(lakes) do
      stonehearth.hydrology:create_water_body_with_region(water, bench_map.LAKE_HEIGHT)
   end
end

return create_world
