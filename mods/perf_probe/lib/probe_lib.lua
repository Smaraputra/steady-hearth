local probe_lib = {}

local function say(side, fmt, ...)
   radiant.log.write_('perf_probe', 0, '[' .. side .. '] ' .. fmt, ...)
end

local function try(side, label, fn)
   local ok, result = pcall(fn)
   say(side, '%s: %s', label, ok and tostring(result) or ('ERROR ' .. tostring(result)))
end

local function keys_of(t)
   if type(t) ~= 'table' then
      return type(t)
   end
   local names = {}
   for k in pairs(t) do
      table.insert(names, tostring(k))
   end
   table.sort(names)
   return table.concat(names, ',')
end

function probe_lib.report_runtime(side)
   try(side, '_VERSION', function() return _VERSION end)
   try(side, 'jit', function() return type(rawget(_G, 'jit')) end)
   try(side, 'string.dump', function() return type(string.dump) end)
   try(side, 'string.dump works', function() return #string.dump(function() return 1 end) end)
   try(side, 'debug fields', function() return keys_of(debug) end)
   try(side, 'coroutine fields', function() return keys_of(coroutine) end)
   try(side, 'collectgarbage count KB', function() return collectgarbage('count') end)
   try(side, 'os', function() return type(rawget(_G, 'os')) end)
   try(side, '_host realtime_us', function() return _host:get_realtime_us() end)
end

function probe_lib.report_hooks(side)
   -- Function identity: what debug.getinfo reports for a known Lua function.
   try(side, 'getinfo radiant.entities.get_entity_data', function()
         local info = debug.getinfo(radiant.entities.get_entity_data, 'S')
         return info.source .. ':' .. info.linedefined .. '-' .. info.lastlinedefined
      end)

   -- Datastores: is the native object's metatable reachable and is mark_changed wrappable?
   try(side, 'datastore type', function() return type(radiant.create_datastore()) end)
   try(side, 'datastore metatable', function()
         local mt = getmetatable(radiant.create_datastore())
         if mt == nil then
            return 'nil'
         end
         return type(mt) .. ' keys=' .. keys_of(mt)
      end)
   try(side, 'datastore mark_changed type', function()
         local ds = radiant.create_datastore()
         return type(ds.mark_changed)
      end)
   try(side, 'datastore metatable __index type', function()
         local mt = getmetatable(radiant.create_datastore())
         return mt and type(rawget(mt, '__index')) or 'no mt'
      end)

   -- Events: are radiant.events.* plain Lua fields we can wrap?
   try(side, 'radiant.events.listen type', function() return type(radiant.events.listen) end)
   try(side, 'radiant.events.trigger type', function() return type(radiant.events.trigger) end)

   -- Count natively fired events seen through the Lua wrapper for one game minute.
   if side == 'server' then
      local seen = { trigger = 0, trigger_async = 0 }
      local orig_trigger, orig_async = radiant.events.trigger, radiant.events.trigger_async
      radiant.events.trigger = function(...)
         seen.trigger = seen.trigger + 1
         return orig_trigger(...)
      end
      radiant.events.trigger_async = function(...)
         seen.trigger_async = seen.trigger_async + 1
         return orig_async(...)
      end
      local post_create = 0
      radiant.events.listen(radiant, 'radiant:entity:post_create', function()
            post_create = post_create + 1
         end)

      radiant.events.listen(stonehearth.game_creation, 'stonehearth:world_generation_complete', function()
            say(side, 'world_generation_complete at realtime_us=%.0f', _host:get_realtime_us())
         end)

      -- Heartbeat: proves the game loop runs, and reports wrapper counts as it goes.
      local ticks = 0
      local last_us = _host:get_realtime_us()
      radiant.on_game_loop('perf_probe heartbeat', function()
            ticks = ticks + 1
            if ticks % 200 == 0 then
               local now_us = _host:get_realtime_us()
               say(side, 'heartbeat ticks=%d avg_tick_ms=%.2f lua_kb=%d wrapper trigger=%d trigger_async=%d native post_create=%d',
                   ticks, (now_us - last_us) / 200000, collectgarbage('count'),
                   seen.trigger, seen.trigger_async, post_create)
               last_us = now_us
            end
         end)
   end
end

-- Catalog detail (mods.perf_probe.catalog_detail=true): while a catalog service is created, times
-- every radiant.resources.load_json call and, when the service class has one, every
-- get_material_object call. begin wraps both, finish restores them and logs
-- PERF_PROBE|catalog_detail|side=...|total_ms=...|json_calls=...|json_ms=...|material_calls=...|material_ms=...
function probe_lib.catalog_detail_begin(service_class)
   local d = { t0 = _host:get_realtime(), json_calls = 0, json_s = 0, material_calls = 0, material_s = 0 }
   local load_json = radiant.resources.load_json
   d.load_json = load_json
   radiant.resources.load_json = function(...)
      local t = _host:get_realtime()
      local json = load_json(...)
      d.json_s = d.json_s + (_host:get_realtime() - t)
      d.json_calls = d.json_calls + 1
      return json
   end
   local get_material_object = service_class and rawget(service_class, 'get_material_object')
   if get_material_object then
      d.service_class, d.get_material_object = service_class, get_material_object
      service_class.get_material_object = function(...)
         local t = _host:get_realtime()
         local material = get_material_object(...)
         d.material_s = d.material_s + (_host:get_realtime() - t)
         d.material_calls = d.material_calls + 1
         return material
      end
   end
   return d
end

function probe_lib.catalog_detail_finish(d, side)
   radiant.resources.load_json = d.load_json
   if d.service_class then
      d.service_class.get_material_object = d.get_material_object
   end
   radiant.log.write_('perf_probe', 0,
      'PERF_PROBE|catalog_detail|side=%s|total_ms=%.0f|json_calls=%d|json_ms=%.0f|material_calls=%d|material_ms=%.0f',
      side, (_host:get_realtime() - d.t0) * 1000, d.json_calls, d.json_s * 1000, d.material_calls, d.material_s * 1000)
end

-- Material check (mods.perf_probe.material_check=true): for every distinct material tag set in the
-- built catalog, generates the subsets with the original and the incremental algorithm
-- (lib/material_subsets.lua), compares both with the catalog's own Material table (keys, order and
-- count) and logs PERF_PROBE|material_check|... with the totals and the time of each algorithm.
function probe_lib.material_check(catalog_service)
   local ms = require 'perf_probe.lib.material_subsets'
   local seen, sets, subsets_total, max_n, mismatches = {}, 0, 0, 0, 0
   local original_s, incremental_s = 0, 0
   for _, material in pairs(catalog_service._materials or {}) do
      local hash = material._hash
      if hash and not seen[hash] and material._material_string ~= '' then
         seen[hash] = true
         local parts = ms.parts_of(material._material_string)
         sets = sets + 1
         subsets_total = subsets_total + 2 ^ #parts - 1
         max_n = math.max(max_n, #parts)
         local t = _host:get_realtime()
         local a, na = ms.original(parts)
         local t2 = _host:get_realtime()
         local b, nb = ms.incremental(parts)
         local t3 = _host:get_realtime()
         original_s, incremental_s = original_s + (t2 - t), incremental_s + (t3 - t2)
         if na ~= nb or na ~= material._num_subparts or not ms.same_order(a, b)
               or not ms.same_order(b, material.material_subsets) then
            mismatches = mismatches + 1
         end
      end
   end
   radiant.log.write_('perf_probe', 0,
      'PERF_PROBE|material_check|sets=%d|subsets=%d|max_tags=%d|mismatches=%d|original_ms=%.0f|incremental_ms=%.0f',
      sets, subsets_total, max_n, mismatches, original_s * 1000, incremental_s * 1000)
end

-- Diagnostic profiles: toggles the engine's Lua CPU profiler (needs lua.enable_cpu_profiler=true) and
-- logs PERF_PROBE|profile|what=<label>|phase=called, then phase=done or phase=failed when the call
-- resolves, so a run shows whether a toggle outside the game loop took effect at once. The engine
-- writes the profile when it is toggled off (profiler_output/server_<time>/).
function probe_lib.toggle_profiler(label)
   local function mark(phase, extra)
      radiant.log.write_('perf_probe', 0, 'PERF_PROBE|profile|what=%s|phase=%s|realtime=%.3f%s', label, phase,
         _host:get_realtime(), extra or '')
   end
   mark('called')
   local ok, promise = pcall(_radiant.call, 'radiant:toggle_cpu_profile')
   if not ok or not promise then
      mark('failed', '|error=' .. tostring(promise))
      return
   end
   promise:done(function() mark('done') end)
      :fail(function(err) mark('failed', '|error=' .. tostring(err)) end)
end

return probe_lib
