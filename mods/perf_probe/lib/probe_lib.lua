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

return probe_lib
