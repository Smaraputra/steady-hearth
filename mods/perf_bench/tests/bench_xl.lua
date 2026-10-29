-- Fixed-time late-game benchmark: a 512 x 512 map with 4 player towns (104 hearthlings),
-- 40 template buildings (32 finished, 8 under construction), 8 mining zones, about 5,000 items,
-- forests, critters and recurring goblin raids. After a warm-up the run simulates one game day
-- and reports how much real time that day took (primary metric) and how much work each town
-- completed (behaviour KPIs). Output lines use the PERF_BENCH format from bench_lib.
local Point3 = _radiant.csg.Point3
local Cube3 = _radiant.csg.Cube3
local Region3 = _radiant.csg.Region3
local bench_lib = require 'perf_bench.tests.bench_lib'
local template_utils = require 'stonehearth.lib.building.template_utils'

local emit = bench_lib.emit
local now_real_s = bench_lib.now_real_s
local now_game_s = bench_lib.now_game_s
local grid = bench_lib.grid

-- player_1 is created by the autotest environment, while the others are added here.
local PLAYERS = {
   { id = 'player_1', kingdom = nil, cx = -128, cz = -128 },
   { id = 'player_2', kingdom = 'rayyas_children:kingdoms:rayyas_children', cx = 128, cz = -128 },
   { id = 'player_3', kingdom = 'northern_alliance:kingdoms:northern_alliance', cx = -128, cz = 128 },
   { id = 'player_4', kingdom = 'stonehearth:kingdoms:ascendancy', cx = 128, cz = 128 },
}

local TOWN = {
   workers = 20,
   soldiers = 4,
   full_chests = 16,           -- 64 items each
   loose_items = 150,          -- hauling work
   food_baskets = 60,
   -- Housing-first layout: 23 beds, a dining hall (10 chairs, 4 tables) and workshops are finished,
   -- two more houses are left for the builders. Missing beds and seats are topped up afterwards.
   buildings_done = { 'shared_sleeping_quarters_new', 'shared_sleeping_quarters_new',
                      'shared_sleeping_quarters_new', 'shared_sleeping_quarters_new',
                      'cottage_for_two_new', 'cottage_for_two_new', 'herbalist_house_new',
                      'dining_hall_new', 'carpenter_house_new' },
   buildings_live = { 'blacksmith_house_new', 'tiny_cottage_new' },
   forest_trees = 40,
   harvest_trees = 20,
   hill_mine = { w = 12, l = 12, h = 4 },
   pit_mine = { w = 10, l = 10, d = 3 },
   farm = { x = 10, y = 10 },
   craft_target = 4,
}

local CHEST_CONTENTS = {
   'stonehearth:resources:wood:oak_log',
   'stonehearth:resources:stone:hunk_of_stone',
   'stonehearth:resources:copper:ore',
   'stonehearth:resources:fiber:silkweed_bundle',
}

local CRAFTERS = {
   { job = 'carpenter', bench = 'stonehearth:carpenter:workbench', recipes = {
      'file(stonehearth/jobs/carpenter/recipes/table_for_one_recipe.json)',
      'file(stonehearth/jobs/carpenter/recipes/simple_wooden_chair_recipe.json)' } },
   { job = 'mason', bench = 'stonehearth:mason:workbench', recipes = {
      'file(stonehearth/jobs/mason/recipes/stone_chair_recipe.json)' } },
   { job = 'blacksmith', bench = 'stonehearth:blacksmith:forge', recipes = {
      'file(stonehearth/jobs/blacksmith/recipes/copper_ingot_recipe.json)' } },
   { job = 'weaver', bench = 'stonehearth:weaver:workbench', recipes = {
      'file(stonehearth/jobs/weaver/recipes/thread_recipe.json)' } },
}

-- Resource item that satisfies each building material, and the voxels one item covers (its stacks).
-- The game's own resource constants (merged with ACE's, which adds planks, stone blocks and thatch)
-- are used first, and this table is only the fallback for vanilla's three building materials.
local MATERIAL_ITEMS = {
   ['wood resource'] = { uri = 'stonehearth:resources:wood:oak_log', voxels = 60 },
   ['stone resource'] = { uri = 'stonehearth:resources:stone:hunk_of_stone', voxels = 60 },
   ['clay_brick resource'] = { uri = 'stonehearth:construction:clay_bricks', voxels = 120 },
}

local function material_supply(material)
   local constants = radiant.resources.load_json('stonehearth:data:resource_constants')
   local entry = constants and constants.resources and constants.resources[material]
   if entry and entry.default_resource and tonumber(entry.stacks) then
      return { uri = entry.default_resource, voxels = tonumber(entry.stacks) }
   end
   return MATERIAL_ITEMS[material]
end

local TEMPLATE_PREFIX = '/r/mods/stonehearth/data/saved_objects/building_templates/'

local WILD_TREES = 300
local CRITTERS = 40
-- One town per raid in rotation, so each town is raided about every 36 game hours by a small party.
-- The vanilla goblin and ambient threat campaigns wait a day or more between encounters and send
-- parties of 1 to 3 per unit type.
local RAID_EVERY = _host:get_config('mods.perf_bench.raid_every') or '9h'
local RAID_SIZE = tonumber(_host:get_config('mods.perf_bench.raid_size')) or 2
local WARMUP_GAME_S = 3600
-- Timing runs use the defaults. Diagnostic runs (census, retention curves) may lengthen the window.
local WINDOW_GAME_S = tonumber(_host:get_config('mods.perf_bench.window_game_s')) or 86400
local TIMEOUT_S = tonumber(_host:get_config('mods.perf_bench.timeout_s')) or 5400
local STUCK_CHECK_EVERY = '30m'
local STUCK_CHECKS_TO_RESCUE = 6     -- 3 game hours: time for the AI to build a ladder or dig out first
local STRANDED_CHECKS_TO_RESCUE = 4  -- 2 game hours stranded above ground with no path to the town
local SAMPLE_EVERY_TICKS = 100
local KPI_EVERY_TICKS = 1000
-- Diagnostic runs only (never timing runs): mods.perf_bench.profile = 'warmup' or 'window'
-- records a Lua CPU profile of that phase. Needs lua.enable_cpu_profiler=true.
local PROFILE_PHASE = _host:get_config('mods.perf_bench.profile')
local PROFILE_FLUSH_MS = 15000
-- Diagnostic runs only: mods.perf_bench.churn_workers = N switches N workers per town between
-- the worker and footman jobs every CHURN_EVERY, to exercise task group membership changes.
-- mods.perf_bench.churn_mode picks how:
--   'player' (default): the way a player promotes, through Town:change_job. The citizen's own AI
--     runs the change_job task (fetching a footman talisman, which the driver supplies when the
--     town has too few), so promote_to runs inside that action.
--   'direct': promote_to straight from the calendar timer, in the middle of whatever the citizen is
--     doing. The base game as released does this only for new citizens and in two campaign scripts, and it is
--     kept to reproduce the 2026-10-28 census results.
local CHURN_WORKERS = tonumber(_host:get_config('mods.perf_bench.churn_workers')) or 0
local CHURN_MODE = _host:get_config('mods.perf_bench.churn_mode') or 'player'
local CHURN_EVERY = '2h'
local FOOTMAN_TALISMAN = 'stonehearth:footman:wooden_sword_talisman'
-- Diagnostic bisect only: mods.perf_bench.live_buildings=false skips the buildings left for the
-- builders, so no building plan jobs run.
local live_config = _host:get_config('mods.perf_bench.live_buildings')
local LIVE_BUILDINGS = not (live_config == false or live_config == 'false')

local function ground_y(x, z)
   return radiant.terrain.get_point_on_terrain(Point3(x, 0, z)).y
end

-- Places a building template the way the in-game placement tool does: centred on the target
-- with its lowest structure at ground level, plus a one-voxel sink for sunk templates so the
-- foundation sits in the ground. Templates keep the world coordinates they were authored at
-- (room floors at y = 9 to 39 depending on the template), so the offset is computed from the
-- top-level pieces (rooms, roofs, walls, blocks, roads, stairs) the same way TempBuilding:finish
-- does on the client. Fixtures are skipped because their origins are relative to their owner.
local template_offsets = {}

local function template_offset(template_id)
   local cached = template_offsets[template_id]
   if cached then
      return cached.offset, cached.sunk
   end
   local template = template_utils.load_template_data(template_id)
   local min_y, min_x, max_x, min_z, max_z
   local function include(x0, y0, z0, x1, z1)
      min_y = math.min(min_y or y0, y0)
      min_x, max_x = math.min(min_x or x0, x0), math.max(max_x or x1, x1)
      min_z, max_z = math.min(min_z or z0, z0), math.max(max_z or z1, z1)
   end
   for _, piece in pairs(template.data) do
      local o = piece.origin
      if o and piece.owner_bid == nil then
         local shapes = piece.floor_shape or (type(piece.blocks) == 'table' and piece.blocks) or nil
         if shapes and #shapes > 0 then
            for _, c in ipairs(shapes) do
               include(o.x + c.min.x, o.y + c.min.y, o.z + c.min.z, o.x + c.max.x, o.z + c.max.z)
            end
         else
            include(o.x, o.y, o.z, o.x, o.z)
         end
      end
   end
   local offset = Point3(-math.floor((min_x + max_x) / 2), -min_y, -math.floor((min_z + max_z) / 2))
   template_offsets[template_id] = { offset = offset, sunk = template.header.sunk }
   return offset, template.header.sunk
end

local function place_template(pid, template_name, x, z)
   local template_id = TEMPLATE_PREFIX .. template_name
   local offset, sunk = template_offset(template_id)
   local pos = Point3(x, ground_y(x, z), z)
   local sink = sunk and Point3(0, -1, 0) or Point3(0, 0, 0)
   return stonehearth.building:load_building(pid, template_id, pos + offset + sink, pos + sink, 0)
end

local FURNITURE_KINDS = { bed = '_bed', chair = 'chair', table = 'table' }

local function count_furniture(pid)
   local counts = { bed = 0, chair = 0, table = 0 }
   for _, entity in pairs(_radiant.sim.get_all_entities()) do
      if entity:get_player_id() == pid then
         local uri = entity:get_uri()
         if uri:find('stonehearth:furniture:', 1, true) == 1 and not uri:find(':iconic', 1, true)
               and not uri:find(':ghost', 1, true) then
            for kind, pattern in pairs(FURNITURE_KINDS) do
               if uri:find(pattern, 1, true) and not uri:find('_pet', 1, true) then
                  counts[kind] = counts[kind] + 1
               end
            end
         end
      end
   end
   return counts
end

local function fill_container(container, item_uri, inventory)
   local sc = container:get_component('stonehearth:storage')
   local num = sc:get_capacity() - sc:get_num_items()
   for i = 1, num do
      local item = radiant.entities.create_entity(item_uri, { owner = container })
      inventory:add_item(item, container, true)
      sc:add_item(item, true)
   end
end

local function setup_town(autotest, p, kpi)
   local env = autotest.env
   local pid, cx, cz = p.id, p.cx, p.cz
   local session = { player_id = pid }
   local inventory = stonehearth.inventory:get_inventory(pid)
   local town = stonehearth.town:get_town(pid)

   local banner = env:create_entity(Point3(cx, 1, cz), 'stonehearth:camp_standard', { owner = pid, force_iconic = false })
   town:set_banner(banner)

   -- Stored goods: full chests rotating through the raw materials crafters and builders use.
   for i, pt in ipairs(grid(cx - 40, cz - 40, 8, TOWN.full_chests, 3)) do
      local chest = env:create_entity(pt[1], pt[2], 'stonehearth:containers:stone_chest', { owner = pid, force_iconic = false })
      fill_container(chest, CHEST_CONTENTS[(i - 1) % #CHEST_CONTENTS + 1], inventory)
   end
   -- Empty chests for the haulers, food, and two stockpiles.
   for _, pt in ipairs(grid(cx - 40, cz - 30, 8, 8, 3)) do
      env:create_entity(pt[1], pt[2], 'stonehearth:containers:stone_chest', { owner = pid, force_iconic = false })
   end
   for _, pt in ipairs(grid(cx - 40, cz - 22, 15, TOWN.food_baskets, 1)) do
      env:create_entity(pt[1], pt[2], 'stonehearth:food:corn:corn_basket', { owner = pid })
   end
   inventory:create_stockpile(Point3(cx - 15, 1, cz - 40), { x = 8, y = 8 })
   inventory:create_stockpile(Point3(cx - 5, 1, cz - 40), { x = 8, y = 8 })

   -- Hauling work: loose resources on the ground.
   kpi.haul_items = {}
   for i, pt in ipairs(grid(cx + 10, cz - 60, 15, TOWN.loose_items, 1)) do
      local uri = (i % 2 == 0) and 'stonehearth:resources:wood:oak_log' or 'stonehearth:resources:stone:hunk_of_stone'
      table.insert(kpi.haul_items, env:create_entity(pt[1], pt[2], uri, { owner = pid }))
   end

   -- Forest: some trees requested for harvest, the rest left standing.
   kpi.trees_cut = 0
   for i, pt in ipairs(grid(cx - 100, cz - 20, 5, TOWN.forest_trees, 5)) do
      local tree = env:create_entity(pt[1], pt[2], (i % 3 == 0) and 'stonehearth:trees:oak:medium' or 'stonehearth:trees:oak:small')
      if i <= TOWN.harvest_trees then
         tree:get_component('stonehearth:resource_node'):request_harvest(pid)
         radiant.events.listen_once(tree, 'radiant:entity:pre_destroy', function()
               kpi.trees_cut = kpi.trees_cut + 1
            end)
      end
   end

   -- Two dig sites: a raised hill and a pit.
   local soil = radiant.terrain.get_block_types().soil_dark
   local hx, hz = cx - 60, cz - 60
   local hill = TOWN.hill_mine
   local hill_y = ground_y(hx, hz)
   env:add_cube_to_terrain(hx, hz, hill.w, hill.l, hill.h, soil)
   local px, pz = cx - 60, cz + 40
   local pit = TOWN.pit_mine
   local pit_y = ground_y(px, pz)
   kpi.mines = {
      stonehearth.mining:dig_region(pid, Region3(Cube3(Point3(hx, hill_y, hz), Point3(hx + hill.w, hill_y + hill.h, hz + hill.l)))),
      stonehearth.mining:dig_region(pid, Region3(Cube3(Point3(px, pit_y - pit.d, pz), Point3(px + pit.w, pit_y, pz + pit.l)))),
   }
   kpi.mine_blocks = hill.w * hill.l * hill.h + pit.w * pit.l * pit.d

   -- Farm.
   local field = stonehearth.farming:create_new_field(session, Point3(cx + 20, 1, cz - 85), TOWN.farm, nil, 0)
   field:get_component('stonehearth:farmer_field'):set_crop(nil, nil, 'stonehearth:crops:carrot_crop')

   -- Buildings: finished ones laid out on a grid, plus live construction funded with materials.
   kpi.buildings = { done = 0, live = 0, failed = 0 }
   local plan = {}
   for _, t in ipairs(TOWN.buildings_done) do
      table.insert(plan, { template = t, instant = true })
   end
   for _, t in ipairs(LIVE_BUILDINGS and TOWN.buildings_live or {}) do
      table.insert(plan, { template = t, instant = false })
   end
   for i, pt in ipairs(grid(cx + 14, cz + 14, 4, #plan, 26)) do
      local entry = plan[i]
      local ok, building_id = pcall(place_template, pid, entry.template, pt[1], pt[2])
      local building = ok and building_id and radiant.entities.get_entity(building_id)
      if not building then
         kpi.buildings.failed = kpi.buildings.failed + 1
         emit('warning', { player = pid, what = 'template_failed', template = entry.template, err = tostring(building_id) })
      elseif entry.instant then
         local bc = building:get('stonehearth:build2:building')
         bc:instabuild()
         kpi.buildings.done = kpi.buildings.done + 1
         if pid == 'player_1' then
            local bounds = bc:get_bounds()
            emit('building', { template = entry.template, ground_y = ground_y(pt[1], pt[2]),
                               min_y = bounds.min.y, max_y = bounds.max.y })
         end
      else
         -- Supply each building left for the builders with its own materials, as a player would
         -- stock them: resource costs are voxels per building material, item costs are fixtures and
         -- furniture keyed 'uri+quality' (for example 'stonehearth:furniture:not_much_of_a_bed+-1').
         local resource_costs, item_costs = building:get('stonehearth:build2:building'):get_costs()
         -- one band of piles per building south of the building grid, inside the map and clear of
         -- the wild trees along the centre line, 15 items wide and at most 10 deep per pile
         local fx, fz = cx + 14, cz + 92 + kpi.buildings.live * 11
         local needed, supplied = {}, {}
         for material, voxels in pairs(resource_costs or {}) do
            table.insert(needed, material .. ':' .. voxels)
            local supply = material_supply(material)
            if supply then
               local n = math.ceil(voxels * 1.1 / supply.voxels) + 2
               for _, spot in ipairs(grid(fx, fz, 15, math.min(n, 150), 1)) do
                  env:create_entity(spot[1], spot[2], supply.uri, { owner = pid })
               end
               table.insert(supplied, supply.uri .. ':' .. math.min(n, 150))
               fx = fx + 16
            else
               emit('warning', { player = pid, what = 'unknown_building_material', material = material, voxels = voxels })
            end
         end
         for cost_key, count in pairs(item_costs or {}) do
            table.insert(needed, cost_key .. ':' .. count)
            local uri = cost_key:match('^([^+]+)')
            for _, spot in ipairs(grid(fx, fz, 15, math.min(count, 150), 1)) do
               env:create_entity(spot[1], spot[2], uri, { owner = pid })
            end
            table.insert(supplied, uri .. ':' .. math.min(count, 150))
            fx = fx + 16
         end
         emit('costs', { player = pid, template = entry.template, needed = table.concat(needed, ';'),
                         supplied = table.concat(supplied, ';') })
         stonehearth.building:build(building_id)
         kpi.buildings.live = kpi.buildings.live + 1
         kpi.live_buildings = kpi.live_buildings or {}
         table.insert(kpi.live_buildings, { entity = building, template = entry.template })
      end
   end

   -- Crafters with maintain orders.
   kpi.craft_outputs = {}
   for i, c in ipairs(CRAFTERS) do
      env:create_entity(cx - 20, cz + 5 + i * 4, c.bench, { owner = pid, force_iconic = false })
      local crafter = env:create_person(cx - 16, cz + 5 + i * 4, { owner = pid, job = c.job, level = 2 })
      for _, r in ipairs(c.recipes) do
         kpi.craft_outputs[bench_lib.maintain(crafter, r, pid, TOWN.craft_target)] = true
      end
   end

   kpi.workers = {}
   for i = 1, TOWN.workers do
      table.insert(kpi.workers,
         env:create_person(cx + (i % 10) * 2, cz + math.floor(i / 10) * 2 + 2, { owner = pid, job = 'worker' }))
   end
   for i = 1, TOWN.soldiers do
      env:create_person(cx + 4 + i * 2, cz - 6, { owner = pid, job = 'footman' })
   end

   -- Every hearthling needs a bed and somewhere to eat: top up what the templates provide.
   local citizens = TOWN.workers + TOWN.soldiers + #CRAFTERS
   local furniture = count_furniture(pid)
   local missing_beds = math.max(0, citizens - furniture.bed)
   for _, pt in ipairs(grid(cx - 40, cz + 30, 6, missing_beds, 3)) do
      env:create_entity(pt[1], pt[2], 'stonehearth:furniture:comfy_bed', { owner = pid, force_iconic = false })
   end
   local missing_seats = math.max(0, math.ceil(citizens / 2) - furniture.chair)
   for i, pt in ipairs(grid(cx - 40, cz + 45, 6, missing_seats, 2)) do
      env:create_entity(pt[1], pt[2], 'stonehearth:furniture:simple_wooden_chair', { owner = pid, force_iconic = false })
      if i % 4 == 1 then
         env:create_entity(pt[1], pt[2] + 1, 'stonehearth:furniture:dining_table', { owner = pid, force_iconic = false })
      end
   end
   kpi.furniture = count_furniture(pid)
   kpi.citizens_start = citizens
   kpi.rescued, kpi.unstuck = 0, 0
end

-- Live (under construction) buildings that finished, and each one's plan job status.
local function count_built(kpi)
   local built = 0
   for _, rec in ipairs(kpi.live_buildings or {}) do
      if rec.entity:is_valid() and rec.entity:get('stonehearth:build2:building'):completed() then
         built = built + 1
      end
   end
   return built
end

-- Per building under construction: plan nodes done out of the total, 'planning' before the plan
-- exists, 'done' once finished.
local function build_progress(kpi)
   local parts = {}
   for _, rec in ipairs(kpi.live_buildings or {}) do
      local text = 'gone'
      if rec.entity:is_valid() then
         local bc = rec.entity:get('stonehearth:build2:building')
         local plan = bc._sv._plan
         if bc:completed() then
            text = 'done'
         elseif plan and plan._sv and plan._sv._nodes then
            text = string.format('%d/%d', math.max(plan._sv._current_active_node_id - 1, 0), #plan._sv._nodes)
            -- a fixture step lists the items it is still waiting to see placed
            local node = plan._sv._nodes[plan._sv._current_active_node_id]
            if node and type(node._fixtures) == 'table' and next(node._fixtures) then
               local uris = {}
               for _, f in pairs(node._fixtures) do
                  local fc = f:is_valid() and f:get('stonehearth:build2:fixture')
                  table.insert(uris, fc and (fc:get_uri():gsub('^[%w_]+:', '')) or '?')
               end
               text = text .. ' waiting ' .. table.concat(uris, '+')
            end
         else
            text = 'planning'
         end
      end
      table.insert(parts, text)
   end
   return table.concat(parts, ',')
end

-- Per building under construction: building status, whether it is currently building, outstanding
-- resource cost and (ACE) banked resources, to see whether construction waits on material delivery.
local function material_states(kpi)
   local parts = {}
   for _, rec in ipairs(kpi.live_buildings or {}) do
      local text = 'gone'
      if rec.entity:is_valid() then
         local bc = rec.entity:get('stonehearth:build2:building')
         local function short(map, field)
            local items = {}
            for material, v in pairs(map or {}) do
               local n = type(v) == 'table' and (v[field] or 0) or v
               table.insert(items, material:gsub(' resource$', '') .. '=' .. tostring(n))
            end
            table.sort(items)
            return table.concat(items, '+')
         end
         local building = bc.currently_building and tostring(bc:currently_building()) or '?'
         text = string.format('s%s/%s rem[%s] bank[%s]', tostring(bc._sv.building_status), building,
                              short(bc._sv.resource_cost), short(bc._sv._banked_resources, 'count'))
      end
      table.insert(parts, text)
   end
   return table.concat(parts, ',')
end

-- Per building under construction, the chunks of the active chunk step: count, blocks remaining,
-- paused, waiting for a structure update, work permits held / allowed, and chunks with no place to
-- stand (empty adjacency), to see why idle workers do not take up construction.
local function chunk_states(kpi, p)
   -- reachability is tested from open ground at the town centre (where the citizens spawn), not
   -- from a citizen, who may be asleep in a bed or at a workshop and give false negatives
   local origin = Point3(p.cx + 2, ground_y(p.cx + 2, p.cz + 2), p.cz + 2)
   local parts = {}
   for _, rec in ipairs(kpi.live_buildings or {}) do
      local text = '-'
      local bc = rec.entity:is_valid() and rec.entity:get('stonehearth:build2:building')
      local plan = bc and bc._sv._plan
      local node = plan and plan._sv and plan._sv._nodes and plan._sv._nodes[plan._sv._current_active_node_id]
      if node and type(node._chunks) == 'table' then
         local n, remaining, paused, waiting, permits, max_workers, no_adjacent, missing = 0, 0, 0, 0, 0, 0, 0, 0
         local unreachable = 0
         local needed = {}
         for _, chunk in pairs(node._chunks) do
            n = n + 1
            local e = chunk.chunk_entity
            local c = e and e:is_valid() and e:get('stonehearth:build2:chunk')
            if c then
               remaining = remaining + c._sv._remaining_l:get_area()
               for material, count in pairs(c._material_counts or {}) do
                  needed[material] = (needed[material] or 0) + count
               end
               if c._sv._paused then paused = paused + 1 end
               if c._sv._waiting_for_update then waiting = waiting + 1 end
               if c._permits then
                  permits = permits + radiant.size(c._permits._workers or {})
                  max_workers = max_workers + (c._permits._max_workers or 0)
               end
               local dest = e:get('destination')
               local adjacent = dest and dest:get_adjacent()
               if not adjacent or adjacent:get():get_area() == 0 then
                  no_adjacent = no_adjacent + 1
               elseif origin then
                  local adjacent_w = radiant.entities.get_world_adjacency_region(e)
                  local ok, connected = pcall(_radiant.sim.topology.are_connected, origin, adjacent_w, 0)
                  if ok and not connected then
                     unreachable = unreachable + 1
                  end
               end
            else
               missing = missing + 1
            end
         end
         -- materials the active chunks still need, against the building's bank (ACE). '!' marks a
         -- material with nothing banked, which ACE builders wait for
         local banked = bc._sv._banked_resources
         local mats = {}
         for material, count in pairs(needed) do
            local bank = banked and banked[material] and banked[material].count or 0
            table.insert(mats, string.format('%s=%d(bank%d)%s', tostring(material):gsub(' resource$', ''), count, bank,
                                             (banked and bank <= 0) and '!' or ''))
         end
         table.sort(mats)
         text = string.format('n%d rem%d paused%d wait%d permits%d/%d noadj%d unreach%d missing%d need[%s]', n,
                              remaining, paused, waiting, permits, max_workers, no_adjacent, unreachable, missing,
                              table.concat(mats, '+'))
      end
      table.insert(parts, text)
   end
   return table.concat(parts, ',')
end

local function plan_states(kpi)
   local states = {}
   for _, rec in ipairs(kpi.live_buildings or {}) do
      table.insert(states, rec.entity:is_valid() and tostring(rec.entity:get('stonehearth:build2:building')._sv.plan_job_status) or 'gone')
   end
   return table.concat(states, ',')
end

-- Shape of a finished building plan, to compare plans between arms of an experiment: node kinds in
-- order, chunk count, chunks needing scaffolding and their scaffolding volume, ladders, root point.
local function plan_fingerprint(bc)
   local plan = bc._sv._plan
   local nodes = plan and plan._sv and plan._sv._nodes or {}
   local kinds, chunks, scaffolded, scaffold_area, ladders = {}, 0, 0, 0, 0
   for _, node in ipairs(nodes) do
      local name = tostring(node.__classname or '?'):gsub('^[%w_]+:', '')
      table.insert(kinds, name)
      if type(node._chunks) == 'table' and name:find('ChunkNode') then
         for _, c in pairs(node._chunks) do
            chunks = chunks + 1
            if c.scaffolding_region_w then
               scaffolded = scaffolded + 1
               scaffold_area = scaffold_area + c.scaffolding_region_w:get_area()
            end
         end
      end
      if type(node._ladders) == 'table' then
         ladders = ladders + radiant.size(node._ladders)
      end
   end
   local root = bc._sv._root_point
   return {
      nodes = #kinds, kinds = table.concat(kinds, ','), chunks = chunks, scaffolded = scaffolded,
      scaffold_area = scaffold_area, ladders = ladders,
      root = root and string.format('%d,%d,%d', root.x, root.y, root.z) or 'nil',
   }
end

-- Logs each building under construction once when its plan completes or fails and once when it is
-- finished, with the game time since setup.
local function track_live_buildings(players, kpis, game_s)
   local statuses = stonehearth.constants.building.plan_job_status
   local COMPLETE, WORKING = statuses.COMPLETE, statuses.WORKING
   for _, p in ipairs(players) do
      for i, rec in ipairs(kpis[p.id].live_buildings or {}) do
         if rec.entity:is_valid() then
            local bc = rec.entity:get('stonehearth:build2:building')
            local status = bc._sv.plan_job_status
            if not rec.planned and status ~= nil and status ~= WORKING then
               rec.planned = true
               local fields = status == COMPLETE and plan_fingerprint(bc) or {}
               fields.player, fields.index, fields.template = p.id, i, rec.template
               fields.status, fields.game_s = status, string.format('%.0f', game_s)
               emit('plan', fields)
            end
            if not rec.built and bc:completed() then
               rec.built = true
               emit('built', { player = p.id, index = i, template = rec.template, game_s = string.format('%.0f', game_s) })
            end
         end
      end
   end
end

local function count_stored(kpi, inventory)
   local stored = 0
   for _, item in ipairs(kpi.haul_items) do
      if item:is_valid() and inventory:container_for(item) then
         stored = stored + 1
      end
   end
   return stored
end

local function count_mined(kpi)
   local remaining = 0
   for _, zone in ipairs(kpi.mines) do
      if zone:is_valid() then
         local ok, area = pcall(function()
               return zone:get_component('stonehearth:mining_zone'):get_region():get():get_area()
            end)
         remaining = remaining + (ok and area or 0)
      end
   end
   return kpi.mine_blocks - remaining
end

local bench = {}

function bench.bench_xl(autotest)
   local setup_start = now_real_s()
   local kpis = {}
   for _, p in ipairs(PLAYERS) do
      if p.kingdom then
         stonehearth.player:add_player(p.id, p.kingdom)
      end
      kpis[p.id] = { crafted = 0, deaths = 0 }
   end

   for _, p in ipairs(PLAYERS) do
      setup_town(autotest, p, kpis[p.id])
   end

   -- Wild trees along the map's central cross and critters between the towns.
   for _, pt in ipairs(grid(-240, -12, 60, WILD_TREES / 2, 8)) do
      autotest.env:create_entity(pt[1], pt[2], 'stonehearth:trees:oak:small')
   end
   for _, pt in ipairs(grid(-12, -240, 2, WILD_TREES / 2, 8)) do
      autotest.env:create_entity(pt[1], pt[2], 'stonehearth:trees:oak:small')
   end
   for _, pt in ipairs(grid(-60, -60, 8, CRITTERS, 15)) do
      autotest.env:create_entity(pt[1], pt[2], 'stonehearth:rabbit')
   end

   -- Crafted outputs and combat outcomes are counted as they happen.
   local craft_owner = {}
   for pid, kpi in pairs(kpis) do
      for uri in pairs(kpi.craft_outputs) do
         craft_owner[uri] = true
      end
   end
   autotest.util:listen(radiant, 'radiant:entity:post_create', function(e)
         if craft_owner[e.entity:get_uri()] then
            local pid = e.entity:get_player_id()
            if kpis[pid] then
               kpis[pid].crafted = kpis[pid].crafted + 1
            end
         end
      end)
   -- The kill event carries the victim's player only, so goblin deaths are counted map-wide.
   local goblins_killed = 0
   autotest.util:listen(radiant.entities, 'stonehearth:entity_killed', function(e)
         if kpis[e.player_id] and e.sentient then
            kpis[e.player_id].deaths = kpis[e.player_id].deaths + 1
         elseif e.player_id == 'goblins' then
            goblins_killed = goblins_killed + 1
         end
      end)

   -- Goblin raids, one town at a time in rotation, timed in game time so every run sees the same
   -- pressure.
   local raids = 0
   stonehearth.calendar:set_interval('perf bench goblin raids', RAID_EVERY, function()
         raids = raids + 1
         local p = PLAYERS[(raids - 1) % #PLAYERS + 1]
         for i = 1, RAID_SIZE do
            autotest.env:create_person(p.cx + 45 + i * 2, p.cz + 45, {
                  owner = 'goblins', weapon = 'stonehearth:weapons:wooden_sword' })
         end
         emit('raid', { player = p.id, size = RAID_SIZE, raid = raids })
      end)

   if CHURN_WORKERS > 0 then
      local churns, refused, talismans = 0, 0, 0
      stonehearth.calendar:set_interval('perf bench job churn', CHURN_EVERY, function()
            for _, p in ipairs(PLAYERS) do
               local town = stonehearth.town:get_town(p.id)
               local inventory = stonehearth.inventory:get_inventory(p.id)
               local in_stock = inventory:get_items_of_type(FOOTMAN_TALISMAN)
               local spare = in_stock and in_stock.count or 0
               for i = 1, math.min(CHURN_WORKERS, #kpis[p.id].workers) do
                  local citizen = kpis[p.id].workers[i]
                  if citizen:is_valid() then
                     local job = citizen:get_component('stonehearth:job')
                     local to_footman = job:get_job_uri() == 'stonehearth:jobs:worker'
                     local target = to_footman and 'stonehearth:jobs:footman' or 'stonehearth:jobs:worker'
                     if CHURN_MODE == 'direct' then
                        job:promote_to(target)
                        churns = churns + 1
                     else
                        if to_footman then
                           if spare > 0 then
                              spare = spare - 1
                           else
                              -- a player would craft one, so place it beside the citizen
                              local location = radiant.entities.get_world_grid_location(citizen)
                              if location then
                                 local items = radiant.entities.spawn_items({ [FOOTMAN_TALISMAN] = 1 }, location, 1, 3, { owner = p.id })
                                 for _, item in pairs(items) do
                                    inventory:add_item(item)
                                    talismans = talismans + 1
                                 end
                              end
                           end
                        end
                        if town:change_job(citizen, target) == false then
                           refused = refused + 1
                        else
                           churns = churns + 1
                        end
                     end
                  end
               end
            end
            emit('churn', { mode = CHURN_MODE, changes = churns, refused = refused, talismans = talismans })
         end)
   end

   -- Stuck watchdog, as a last resort the way a player would act: unstick hearthlings caught inside
   -- geometry, and bring home an idle citizen that has not moved for STUCK_CHECKS_TO_RESCUE checks
   -- (3 game hours), which leaves the AI time to build a ladder or dig its own way out. Sleeping,
   -- seated, incapacitated and fighting citizens are never moved. Topology reachability to the banner
   -- was tried first, but it reports false negatives for citizens in beds and at workshops.
   -- A citizen standing more than 2 voxels above the terrain with no path to open ground at the town
   -- centre is stranded (typically on a roof after ladders and scaffolding were taken down). Stranded
   -- citizens may keep moving, so the stillness rule above misses them. They are brought home after
   -- STRANDED_CHECKS_TO_RESCUE consecutive checks, the same way.
   local last_positions = {}
   local stranded_checks = {}
   local town_ground = {}
   for _, p in ipairs(PLAYERS) do
      local gy = ground_y(p.cx + 2, p.cz + 2)
      town_ground[p.id] = Region3(Cube3(Point3(p.cx - 2, gy, p.cz - 2), Point3(p.cx + 7, gy + 1, p.cz + 7)))
   end
   stonehearth.calendar:set_interval('perf bench stuck watchdog', STUCK_CHECK_EVERY, function()
         for _, p in ipairs(PLAYERS) do
            local kpi = kpis[p.id]
            local pop = stonehearth.population:get_population(p.id)
            kpi.stranded_now = 0
            for id, citizen in pop:get_citizens():each() do
               local location = citizen:is_valid() and radiant.entities.get_world_grid_location(citizen)
               if location then
                  if stonehearth.physics:is_stuck(citizen) then
                     stonehearth.physics:unstick_entity(citizen)
                     kpi.unstuck = kpi.unstuck + 1
                     last_positions[id] = nil
                  else
                     local posture = radiant.entities.get_posture(citizen)
                     local resting = posture == 'stonehearth:sleeping' or posture == 'stonehearth:sitting'
                     local incap = citizen:get_component('stonehearth:incapacitation')
                     -- knocked-out hearthlings wait for a friend to carry them to bed, so never teleport them
                     resting = resting or (incap ~= nil and incap:is_incapacitated())
                     local fighting = stonehearth.combat:get_primary_target(citizen) ~= nil
                     -- Only an idle citizen counts: busy ones (crafting, building) can stand still for a while.
                     local ai = citizen:get_component('stonehearth:ai')
                     local idle = ai and ai:get_status_text_key() == 'stonehearth:ai.actions.status_text.idle'
                     local status = ai and tostring(ai:get_status_text_key()) or ''
                     local at_workshop = status:find('workshop') ~= nil or status:find('craft') ~= nil
                     local elevated = location.y > ground_y(location.x, location.z) + 2
                     local stranded = elevated and not resting and not fighting and not at_workshop
                        and not _radiant.sim.topology.are_connected(location, town_ground[p.id], 0)
                     if stranded then
                        stranded_checks[id] = (stranded_checks[id] or 0) + 1
                        kpi.stranded_now = kpi.stranded_now + 1
                     else
                        stranded_checks[id] = nil
                     end
                     local last = last_positions[id]
                     if stranded and stranded_checks[id] >= STRANDED_CHECKS_TO_RESCUE then
                        emit('rescue', { player = p.id, id = id, x = location.x, y = location.y, z = location.z,
                                         reason = 'stranded', status = status })
                        radiant.terrain.place_entity(citizen, Point3(p.cx + 2, 1, p.cz + 2))
                        kpi.rescued = kpi.rescued + 1
                        kpi.stranded_rescued = (kpi.stranded_rescued or 0) + 1
                        stranded_checks[id] = nil
                        last_positions[id] = nil
                     elseif resting or fighting or not idle or not last or last.location ~= location then
                        last_positions[id] = { location = location, still = 0 }
                     else
                        last.still = last.still + 1
                        if last.still >= STUCK_CHECKS_TO_RESCUE then
                           emit('rescue', { player = p.id, id = id, x = location.x, y = location.y, z = location.z,
                                            posture = tostring(posture),
                                            status = tostring(ai:get_status_text_key()) })
                           radiant.terrain.place_entity(citizen, Point3(p.cx + 2, 1, p.cz + 2))
                           kpi.rescued = kpi.rescued + 1
                           last_positions[id] = nil
                        end
                     end
                  end
               end
            end
         end
      end)

   local entity_count = 0
   for _ in pairs(_radiant.sim.get_all_entities()) do
      entity_count = entity_count + 1
   end
   local building_summary = { done = 0, live = 0, failed = 0 }
   for _, kpi in pairs(kpis) do
      if kpi.buildings then
         for k, v in pairs(kpi.buildings) do
            building_summary[k] = building_summary[k] + v
         end
      end
   end
   emit('setup', {
      real_s = string.format('%.3f', now_real_s() - setup_start),
      players = #PLAYERS, entities = entity_count,
      buildings_done = building_summary.done, buildings_live = building_summary.live,
      buildings_failed = building_summary.failed,
      lua_kb = math.floor(collectgarbage('count')),
   })

   -- What every citizen is doing ('job/activity' counts) and how many may build, to see why
   -- construction stalls.
   local function activities(pop)
      local counts, builders = {}, 0
      for _, citizen in pop:get_citizens():each() do
         if citizen:is_valid() then
            local job = citizen:get_component('stonehearth:job')
            local job_name = job and tostring(job:get_job_uri()):gsub('^.*:jobs:', '') or '?'
            local ai = citizen:get_component('stonehearth:ai')
            local activity = ai and tostring(ai:get_status_text_key() or 'none'):gsub('^.*status_text%.', '') or '?'
            local key = job_name .. '/' .. activity
            counts[key] = (counts[key] or 0) + 1
            local orders = citizen:get_component('stonehearth:work_order')
            if orders and orders:is_work_order_enabled('build') then
               builders = builders + 1
            end
         end
      end
      local parts = {}
      for key, n in pairs(counts) do
         table.insert(parts, key .. ':' .. n)
      end
      table.sort(parts)
      return table.concat(parts, ';'), builders
   end

   local function emit_kpis(phase)
      for _, p in ipairs(PLAYERS) do
         local kpi = kpis[p.id]
         local pop = stonehearth.population:get_population(p.id)
         local doing, builders = '', -1
         if pop then
            doing, builders = activities(pop)
         end
         emit('kpi', {
            phase = phase, player = p.id,
            citizens = pop and pop:get_citizen_count() or -1,
            doing = doing, builders = builders, stranded = kpi.stranded_now or 0,
            stranded_rescued = kpi.stranded_rescued or 0,
            stored = count_stored(kpi, stonehearth.inventory:get_inventory(p.id)),
            haul_total = #kpi.haul_items,
            trees_cut = kpi.trees_cut, mined = count_mined(kpi), mine_total = kpi.mine_blocks,
            crafted = kpi.crafted, deaths = kpi.deaths,
            rescued = kpi.rescued, unstuck = kpi.unstuck,
            beds = kpi.furniture.bed, chairs = kpi.furniture.chair, tables = kpi.furniture.table,
            built = count_built(kpi), plan = plan_states(kpi), progress = build_progress(kpi),
            materials = material_states(kpi), chunks = chunk_states(kpi, p),
         })
      end
      emit('kpi_global', { phase = phase, raids = raids, goblins_killed = goblins_killed })
   end

   local start_game = now_game_s()
   local window_start_real, window_start_game = nil, nil
   local last_real, last_game = now_real_s(), start_game
   local ticks, finished = 0, false

   -- Toggled from the game loop, like the debugtools call handler does. The profile is
   -- written when it is toggled off.
   local function toggle_profiler(at)
      _radiant.call('radiant:toggle_cpu_profile')
      emit('profiler', { phase = PROFILE_PHASE, at = at, tick = ticks })
   end

   autotest.util:listen(radiant, 'radiant:gameloop', function()
         if finished then
            return
         end
         ticks = ticks + 1
         if ticks == 1 and PROFILE_PHASE == 'warmup' then
            toggle_profiler('warmup_start')
         end
         local g = now_game_s()
         if not window_start_real and g - start_game >= WARMUP_GAME_S then
            if PROFILE_PHASE == 'warmup' or PROFILE_PHASE == 'window' then
               toggle_profiler('window_start')
            end
            window_start_real, window_start_game = now_real_s(), g
            emit('window_start', { game_s = string.format('%.1f', g - start_game), tick = ticks,
                                   lua_kb = math.floor(collectgarbage('count')) })
            emit_kpis('start')
         end
         if window_start_real and g - window_start_game >= WINDOW_GAME_S then
            finished = true
            local r = now_real_s()
            emit_kpis('end')
            emit('done', {
               size = 'xl',
               window_real_s = string.format('%.3f', r - window_start_real),
               window_game_s = string.format('%.1f', g - window_start_game),
               speed = string.format('%.3f', (g - window_start_game) / (r - window_start_real)),
               ticks = ticks,
               lua_kb = math.floor(collectgarbage('count')),
            })
            if PROFILE_PHASE == 'window' then
               toggle_profiler('done')
               radiant.set_realtime_timer('perf_bench profile flush', PROFILE_FLUSH_MS, function()
                     autotest:success()
                  end)
            else
               autotest:success()
            end
            return
         end
         if ticks % SAMPLE_EVERY_TICKS == 0 then
            local r = now_real_s()
            emit('sample', {
               tick = ticks,
               game_s = string.format('%.1f', g - start_game),
               speed = string.format('%.3f', (g - last_game) / math.max(r - last_real, 1e-6)),
               lua_kb = math.floor(collectgarbage('count')),
            })
            last_real, last_game = r, g
         end
         if ticks % 20 == 0 then
            track_live_buildings(PLAYERS, kpis, g - start_game)
         end
         if ticks % KPI_EVERY_TICKS == 0 then
            emit_kpis('progress')
         end
      end)

   autotest.util:fail_if_expired(TIMEOUT_S * 1000)
end

return bench
