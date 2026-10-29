-- Fixed-work benchmark scenarios. Each test builds a deterministic colony, then measures how long
-- (real and game time) the colony takes to finish a fixed workload. Results are written as
-- machine-parseable log lines at level 0:
--   PERF_BENCH|<event>|key=value|key=value...
-- tools/parse_bench.py turns them into JSON.
local Point3 = _radiant.csg.Point3
local Cube3 = _radiant.csg.Cube3
local Region3 = _radiant.csg.Region3

local SAMPLE_EVERY_TICKS = 100
local CHECK_EVERY_TICKS = 20      -- milestone resolution, about 1 s real at the default tick

-- Workload ladder. Every count is fixed so every run of a size does the same work.
local SIZES = {
   s = {
      workers = 8,
      haul_logs = 60,       -- loose oak logs to store
      haul_stone = 60,      -- loose stone to store
      chests = 6,
      trees = 12,
      mine = { w = 8, l = 8, h = 3 },
      craft_target = 3,     -- items of each maintained recipe
      food_baskets = 30,
      timeout_s = 1500,
   },
   m = {
      workers = 24,
      haul_logs = 300,
      haul_stone = 300,
      chests = 24,
      trees = 40,
      mine = { w = 16, l = 12, h = 3 },
      craft_target = 5,
      food_baskets = 90,
      timeout_s = 3600,
   },
}

local CARPENTER_RECIPES = {
   'file(stonehearth/jobs/carpenter/recipes/table_for_one_recipe.json)',
   'file(stonehearth/jobs/carpenter/recipes/simple_wooden_chair_recipe.json)',
}
local MASON_RECIPES = {
   'file(stonehearth/jobs/mason/recipes/stone_chair_recipe.json)',
}

local bench_lib = require 'perf_bench.tests.bench_lib'
local emit = bench_lib.emit
local now_real_s = bench_lib.now_real_s
local now_game_s = bench_lib.now_game_s
local maintain = bench_lib.maintain
local grid = bench_lib.grid

local function run_scenario(autotest, size_name)
   local size = SIZES[size_name]
   local env = autotest.env
   local player_id = env:get_player_id()
   local inventory = stonehearth.inventory:get_inventory(player_id)

   local banner = env:create_entity(Point3(0, 1, 0), 'stonehearth:camp_standard',
                                    { owner = player_id, force_iconic = false })
   stonehearth.town:get_town(player_id):set_banner(banner)

   -- Storage: empty chests that the haulers fill, plus food in a separate chest area.
   for _, p in ipairs(grid(-30, -30, 6, size.chests, 3)) do
      env:create_entity(p[1], p[2], 'stonehearth:containers:stone_chest', { owner = player_id, force_iconic = false })
   end
   for _, p in ipairs(grid(-30, 10, 10, size.food_baskets, 1)) do
      env:create_entity(p[1], p[2], 'stonehearth:food:corn:corn_basket', { owner = player_id })
   end

   -- Haul workload: loose resources on the ground away from the chests.
   local haul_items = {}
   for _, p in ipairs(grid(20, -40, 15, size.haul_logs, 1)) do
      table.insert(haul_items, env:create_entity(p[1], p[2], 'stonehearth:resources:wood:oak_log', { owner = player_id }))
   end
   for _, p in ipairs(grid(20, -20, 15, size.haul_stone, 1)) do
      table.insert(haul_items, env:create_entity(p[1], p[2], 'stonehearth:resources:stone:hunk_of_stone', { owner = player_id }))
   end

   -- Harvest workload: small oaks, each requested for harvest.
   local trees_left = 0
   for _, p in ipairs(grid(40, 20, 6, size.trees, 4)) do
      local tree = env:create_entity(p[1], p[2], 'stonehearth:trees:oak:small')
      tree:get_component('stonehearth:resource_node'):request_harvest(player_id)
      trees_left = trees_left + 1
      autotest.util:listen_once(tree, 'radiant:entity:pre_destroy', function()
            trees_left = trees_left - 1
         end)
   end

   -- Mining workload: a raised block of terrain, fully designated.
   local m = size.mine
   env:add_cube_to_terrain(-60, 30, m.w, m.l, m.h, radiant.terrain.get_block_types().soil_dark)
   local mine_region = Region3(Cube3(Point3(-60, 10, 30), Point3(-60 + m.w, 10 + m.h, 30 + m.l)))
   local mine = stonehearth.mining:dig_region(player_id, mine_region)
   local mined = false
   autotest.util:listen_once(mine, 'radiant:entity:pre_destroy', function()
         mined = true
      end)

   -- Crafting workload: one carpenter and one mason with maintain orders.
   env:create_entity(-10, -10, 'stonehearth:carpenter:workbench', { force_iconic = false })
   env:create_entity(-10, 0, 'stonehearth:mason:workbench', { force_iconic = false })
   local carpenter = env:create_person(-8, -6, { job = 'carpenter', level = 2 })
   local mason = env:create_person(-8, 2, { job = 'mason', level = 2 })
   local craft_outputs = {}
   for _, r in ipairs(CARPENTER_RECIPES) do
      table.insert(craft_outputs, maintain(carpenter, r, player_id, size.craft_target))
   end
   for _, r in ipairs(MASON_RECIPES) do
      table.insert(craft_outputs, maintain(mason, r, player_id, size.craft_target))
   end

   for i = 1, size.workers do
      env:create_person(2 + (i % 8) * 2, 2 + math.floor(i / 8) * 2, { job = 'worker' })
   end

   -- Crafted outputs are counted as they are created, independent of how the inventory indexes them.
   local crafted_counts = {}
   for _, uri in ipairs(craft_outputs) do
      crafted_counts[uri] = 0
   end
   autotest.util:listen(radiant, 'radiant:entity:post_create', function(e)
         local uri = e.entity:get_uri()
         if crafted_counts[uri] then
            crafted_counts[uri] = crafted_counts[uri] + 1
         end
      end)

   local start_real, start_game = now_real_s(), now_game_s()
   emit('start', {
      size = size_name, workers = size.workers + 2, haul_items = #haul_items, trees = size.trees,
      mine_blocks = m.w * m.l * m.h, crafts = #craft_outputs * size.craft_target,
      lua_kb = math.floor(collectgarbage('count')),
   })

   local milestones = {}
   local function milestone(name)
      if not milestones[name] then
         milestones[name] = true
         emit('milestone', { name = name, real_s = string.format('%.3f', now_real_s() - start_real),
                             game_s = string.format('%.1f', now_game_s() - start_game) })
      end
   end

   local function check_milestones()
      if not milestones.stored then
         local unstored = 0
         for _, item in ipairs(haul_items) do
            if item:is_valid() and not inventory:container_for(item) then
               unstored = unstored + 1
            end
         end
         if unstored == 0 then
            milestone('stored')
         end
      end
      if trees_left == 0 then
         milestone('harvested')
      end
      if mined then
         milestone('mined')
      end
      if not milestones.crafted then
         local done = true
         for _, uri in ipairs(craft_outputs) do
            if crafted_counts[uri] < size.craft_target then
               done = false
               break
            end
         end
         if done then
            milestone('crafted')
         end
      end
      return milestones.stored and milestones.harvested and milestones.mined and milestones.crafted
   end

   local ticks = 0
   local last_real, last_game = start_real, start_game
   local finished = false
   autotest.util:listen(radiant, 'radiant:gameloop', function()
         ticks = ticks + 1
         if finished or ticks % CHECK_EVERY_TICKS ~= 0 then
            return
         end
         local r, g = now_real_s(), now_game_s()
         if check_milestones() then
            finished = true
            emit('done', {
               size = size_name,
               makespan_real_s = string.format('%.3f', r - start_real),
               makespan_game_s = string.format('%.1f', g - start_game),
               ticks = ticks,
               lua_kb = math.floor(collectgarbage('count')),
            })
            autotest:success()
            return
         end
         if ticks % SAMPLE_EVERY_TICKS ~= 0 then
            return
         end
         emit('sample', {
            tick = ticks,
            real_s = string.format('%.3f', r - start_real),
            game_s = string.format('%.1f', g - start_game),
            speed = string.format('%.3f', (g - last_game) / math.max(r - last_real, 1e-6)),
            lua_kb = math.floor(collectgarbage('count')),
         })
         last_real, last_game = r, g
      end)

   autotest.util:fail_if_expired(size.timeout_s * 1000)
end

local bench = {}

function bench.bench_s(autotest)
   run_scenario(autotest, 's')
end

function bench.bench_m(autotest)
   run_scenario(autotest, 'm')
end

return bench
