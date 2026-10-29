-- Shared helpers for the perf_bench scenarios: result logging, a wrap-safe real clock,
-- placement grids and crafter maintain orders.
local bench_lib = {}

local REALTIME_WRAP = 4294967296  -- _host:get_realtime_us() is an unsigned 32-bit counter

-- Writes one machine-parseable result line: PERF_BENCH|<event>|key=value|... (keys sorted).
function bench_lib.emit(event, fields)
   local parts = { 'PERF_BENCH', event }
   local keys = {}
   for k in pairs(fields or {}) do
      table.insert(keys, k)
   end
   table.sort(keys)
   for _, k in ipairs(keys) do
      table.insert(parts, k .. '=' .. tostring(fields[k]))
   end
   radiant.log.write_('perf_bench', 0, table.concat(parts, '|'))
end

local last_raw_us, wrap_offset_us = nil, 0
function bench_lib.now_real_s()
   local raw = _host:get_realtime_us()
   if last_raw_us and raw < last_raw_us then
      wrap_offset_us = wrap_offset_us + REALTIME_WRAP
   end
   last_raw_us = raw
   return (raw + wrap_offset_us) / 1000000
end

function bench_lib.now_game_s()
   return stonehearth.calendar:get_elapsed_time()
end

-- n points on a grid with the given number of columns and spacing, starting at (x0, z0).
function bench_lib.grid(x0, z0, cols, n, spacing)
   local points = {}
   for i = 0, n - 1 do
      local col = i % cols
      local row = math.floor(i / cols)
      table.insert(points, { x0 + col * spacing, z0 + row * spacing })
   end
   return points
end

-- Adds a maintain order for a recipe to a crafter and returns the produced item uri.
function bench_lib.maintain(crafter, recipe_path, player_id, at_least)
   local recipe = radiant.resources.load_json(recipe_path)
   local uri = recipe.workshop
   if type(uri) == 'string' then
      recipe.workshop = { uri = uri }
   end
   local order_list = crafter:get_component('stonehearth:job'):get_job_info():get_order_list()
   order_list:add_order(player_id, recipe, { type = 'maintain', at_least = at_least })
   return recipe.produces[1].item
end

return bench_lib
