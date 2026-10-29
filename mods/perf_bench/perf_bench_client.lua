-- Post-window probes on the client (diagnostic runs only). Once the benchmark's measured window has
-- ended, the client runs its probes, then reports to the server, which ends the test:
--   mods.perf_bench.post_probes=true: a CPU profile toggled from the client for PROFILE_S seconds
--     (on 2026-10-29 this turned out to profile the server, not the client), then one timed save;
--   mods.perf_bench.post_probes=save: the timed save only.
-- The save id is mods.perf_bench.save_id (default perf_bench_probe, which tools/run_game.sh measures
-- and removes after the run; any other id is kept and archived as a fixture under runs/fixtures/).
local bench_lib = require 'perf_bench.tests.bench_lib'

local mode = _host:get_config('mods.perf_bench.post_probes')
if mode == true or mode == 'true' then
   mode = 'all'
elseif mode ~= 'save' then
   return {}
end

local PROFILE_S = 60
local FLUSH_MS = 15000
local SAVE_ID = _host:get_config('mods.perf_bench.save_id') or 'perf_bench_probe'

local state = 'waiting'
local poll

local function report(result)
   bench_lib.emit('client_probe', result)
   _radiant.call('perf_bench:probe_done', result)
   state = 'done'
end

local function save_game(result)
   local start = _host:get_realtime()
   local ok, promise = pcall(_radiant.call, 'radiant:client:save_game', SAVE_ID, {
         name = SAVE_ID, town_name = SAVE_ID, game_date = {}, timestamp = 0, time = '',
         jobs = { crafters = 0, workers = 0, soldiers = 0 },
      })
   if not ok or not promise then
      result.saved, result.save_error = false, tostring(promise)
      report(result)
      return
   end
   promise:done(function()
         result.saved, result.save_s = true, string.format('%.3f', _host:get_realtime() - start)
         report(result)
      end)
      :fail(function(err)
         result.saved, result.save_s = false, string.format('%.3f', _host:get_realtime() - start)
         result.save_error = tostring(err)
         report(result)
      end)
end

-- Toggles the CPU profiler from the client and records the call's outcome in result[key]
-- ('done', 'failed: ...' or 'error: ...'), then continues with next() either way.
local function toggle_profiler(result, key, next)
   local ok, promise = pcall(_radiant.call, 'radiant:toggle_cpu_profile')
   if not ok or not promise then
      result[key] = 'error: ' .. tostring(promise)
      next()
      return
   end
   promise:done(function()
         result[key] = 'done'
         next()
      end)
      :fail(function(err)
         result[key] = 'failed: ' .. tostring(err)
         next()
      end)
end

local function run_probes()
   local result = { save_id = SAVE_ID }
   if mode == 'save' then
      save_game(result)
      return
   end
   toggle_profiler(result, 'profile_on', function()
         radiant.set_realtime_timer('perf_bench client profile', PROFILE_S * 1000, function()
               toggle_profiler(result, 'profile_off', function()
                     radiant.set_realtime_timer('perf_bench client profile flush', FLUSH_MS, function()
                           save_game(result)
                        end)
                  end)
            end)
      end)
end

poll = radiant.set_realtime_interval('perf_bench probe poll', 5000, function()
      if state ~= 'waiting' then
         if poll then
            poll:destroy()
            poll = nil
         end
         return
      end
      _radiant.call('perf_bench:probe_phase'):done(function(response)
            if state == 'waiting' and response and response.phase == 'client' then
               state = 'running'
               run_probes()
            end
         end)
   end)

return {}
