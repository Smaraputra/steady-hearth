-- Debug-only probe: reports what the sandboxed Lua runtime lets a mod see and wrap.
-- Every finding is written at log level 0 under the 'perf_probe' tag.
perf_probe = {}

local probe_lib = require 'perf_probe.lib.probe_lib'

probe_lib.report_runtime('server')

-- Optional (mods.perf_probe.memory_cap_mb = N): hold N distinct 1 MB strings, logging the heap every
-- 32 MB, to find whether the engine's Lua allocator stops short of N (some LuaJIT-era setups cap
-- the Lua heap near 768 MB, and ACE heaps reach about 690 MB in one game day). Result on 2026-10-29:
-- no ceiling up to 1,400 MB. Freed again afterwards; diagnostic runs only.
local function memory_cap_test(limit_mb)
   local log = function(fmt, ...)
      radiant.log.write_('perf_probe', 0, 'PERF_PROBE|' .. fmt, ...)
   end
   local held = {}
   local one_mb = string.rep('x', 1024 * 1024 - 16)
   local count = 0
   local ok, err = pcall(function()
         for i = 1, limit_mb do
            held[i] = one_mb .. string.format('%016d', i)   -- a new 1 MB string each time
            count = i
            if i % 32 == 0 then
               log('memory|held_mb=%d|lua_kb=%d', i, math.floor(collectgarbage('count')))
            end
         end
      end)
   log('memory_result|ok=%s|held_mb=%d|lua_kb=%d|error=%s', tostring(ok), count,
       math.floor(collectgarbage('count')), tostring(err))
   held = nil
   collectgarbage('collect')
   log('memory_freed|lua_kb=%d', math.floor(collectgarbage('count')))
end

radiant.events.listen(radiant, 'radiant:required_loaded', function()
      probe_lib.report_hooks('server')
      local limit = tonumber(_host:get_config('mods.perf_probe.memory_cap_mb'))
      if limit then
         memory_cap_test(limit)
      end
   end)

return perf_probe
