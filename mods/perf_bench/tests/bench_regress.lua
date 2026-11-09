-- Regression scenario for two script errors: build_ladder_adjacent with a citizen that has left the
-- world, and a teleport action left installed by a second request. Each stage logs one line,
--   PERF_BENCH|regress|stage=<name>|...
-- with the number of script errors raised during that stage. Run it with the patches off to see the
-- errors and with them on to see none: tools/bench.sh regress <variant> <label> [key=value ...].
local Point3 = _radiant.csg.Point3

local bench_lib = require 'perf_bench.tests.bench_lib'
local emit = bench_lib.emit

local LADDER_ACTION = 'stonehearth:actions:build_ladder_adjacent'
local TELEPORT_ACTION = 'stonehearth:actions:compelled_behaviors:teleporting'
local POLL_MS = 250
local WAIT_MS = 120000
local SETTLE_MS = 8000

local function wait_until(autotest, timeout_ms, condition)
   local waited = 0
   while not condition() and waited < timeout_ms do
      autotest:sleep(POLL_MS)
      waited = waited + POLL_MS
   end
   return condition() and true or false
end

-- Takes the first citizen that reaches the action off the world at the moment the action starts,
-- which is the state a town suspension or a dispatch quest can leave it in, then brings it back.
local function stage_ladder(autotest, town, player_id)
   local script = radiant.mods.load_script(LADDER_ACTION)
   local installed = script.run
   local removed
   script.run = function(self, ai, entity, args)
      if not removed then
         removed = entity
         town:dispatch_citizen(entity)
      end
      return installed(self, ai, entity, args)
   end

   local start_errors = _host:get_error_count()
   local handle = stonehearth.build:request_ladder_to(player_id, Point3(20, 18, 20), Point3(0, 0, 1), { category = 'common' })
   local builder = handle:get_builder()

   local reached = wait_until(autotest, WAIT_MS, function()
         return removed ~= nil
      end)
   autotest:sleep(SETTLE_MS)
   local errors_off_world = _host:get_error_count() - start_errors
   if removed then
      town:return_citizen(removed)
   end
   local finished = wait_until(autotest, WAIT_MS, function()
         return builder:is_ladder_finished('build')
      end)
   script.run = installed

   emit('regress', {
      stage = 'ladder',
      reached = reached,
      errors_off_world = errors_off_world,
      errors = _host:get_error_count() - start_errors,
      finished = finished,
      back_in_world = removed ~= nil and radiant.entities.exists_in_world(removed),
   })
end

local function stage_teleport(autotest, name, worker, destinations)
   local script = radiant.mods.load_script(TELEPORT_ACTION)
   local installed = script.run
   local run_calls = 0
   script.run = function(self, ai, entity, args)
      run_calls = run_calls + 1
      return installed(self, ai, entity, args)
   end

   local teleportation = worker:get_component('stonehearth:teleportation')
   local ai_component = worker:get_component('stonehearth:ai')
   local start_errors = _host:get_error_count()

   for _, destination in ipairs(destinations) do
      teleportation:set_teleporting(destination)
   end

   local target = destinations[#destinations]
   local arrived = wait_until(autotest, WAIT_MS, function()
         local location = radiant.entities.get_world_grid_location(worker)
         return location and location.x == target.x and location.z == target.z
      end)
   autotest:sleep(SETTLE_MS)
   local calls_settled = run_calls
   autotest:sleep(SETTLE_MS)

   emit('regress', {
      stage = name,
      arrived = arrived,
      run_calls = run_calls,
      calls_after_settle = run_calls - calls_settled,
      errors = _host:get_error_count() - start_errors,
      ref_count = ai_component._ref_counts:get_ref_count(TELEPORT_ACTION),
      destination = tostring(teleportation:get_destination()),
   })
   script.run = installed
end

local bench = {}

function bench.bench_regress(autotest)
   local env = autotest.env
   local player_id = env:get_player_id()
   local town = stonehearth.town:get_town(player_id)

   local banner = env:create_entity(Point3(0, 1, 0), 'stonehearth:camp_standard',
                                    { owner = player_id, force_iconic = false })
   town:set_banner(banner)

   local workers = {}
   for i = 1, 4 do
      table.insert(workers, env:create_person(2 + i * 2, 2, { job = 'worker' }))
   end
   emit('setup', { scenario = 'regress', workers = #workers })
   autotest:sleep(3000)

   local start_errors = _host:get_error_count()
   stage_ladder(autotest, town, player_id)
   stage_teleport(autotest, 'teleport_once', workers[1], { Point3(-6, 10, -6) })
   stage_teleport(autotest, 'teleport_twice', workers[2], { Point3(-6, 10, 6), Point3(-10, 10, 6) })

   emit('regress', { stage = 'done', errors = _host:get_error_count() - start_errors })
   autotest:success()
end

return bench
