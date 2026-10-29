-- Debug-only retention census, never enabled in timing runs. Every mods.perf_census.interval_s game
-- seconds (default 7200) it forces a full garbage collection and writes PERF_CENSUS lines with:
--   heap:        live Lua heap after the collection
--   listeners:   live Lua event listeners per event name (needs mods.radiant.use_cpp_events=false, as
--                the C++ event manager keeps its listeners out of reach), and listener_sites: the
--                same by defining line, or 'once@<caller>' for listen_once listeners
--   ai_custom:   custom AI actions (task actions and the like) added and not yet removed, per entity
--                (total, max), and the distinct actions held (keys, max_keys)
--   spatial_caches: native spatial caches created (one per distinct filter function, never freed),
--                in total and since the previous census, by description
--   fast_call:   distinct filter functions given to AiService:fast_call_filter_fn, each holding a
--                native FilterResultCache in FAST_CALL_CACHES for the rest of the session
--   clone_nav_grid: every call of _radiant.sim.clone_nav_grid with the bounds it receives and its
--                real time, and default_cube: what Cube3() holds (stall hunt, see below)
--   storage_filter_caches: ACE only, per-storage filter caches (one per filter function a storage
--                was searched with, kept until the storage is destroyed): total, the most on one
--                storage, and the item entries they hold (finding R7b)
--   placement_tasks: town item placement requests, the live ghosts that want them, and the stale
--                entries left with no ghost (finding E1)
--   nearby_search: restock nearby item searches started and finished, and the game seconds each
--                took (experiment 004 mechanism check)
perf_census = {}

-- installed at load, before any entity exists (nil_sender_guard.lua explains why)
local NIL_SENDER_GUARD = require 'perf_census.nil_sender_guard'()

local INTERVAL_S = tonumber(_host:get_config('mods.perf_census.interval_s')) or 7200
local TOP_N = 15

local function emit(event, fields)
   local parts = { 'PERF_CENSUS', event }
   local keys = {}
   for k in pairs(fields) do
      table.insert(keys, k)
   end
   table.sort(keys)
   for _, k in ipairs(keys) do
      table.insert(parts, k .. '=' .. tostring(fields[k]))
   end
   radiant.log.write_('perf_census', 0, table.concat(parts, '|'))
end

local function top_entries(counts, n)
   local list = {}
   for name, count in pairs(counts) do
      table.insert(list, { name = tostring(name), count = count })
   end
   table.sort(list, function(a, b)
         if a.count ~= b.count then
            return a.count > b.count
         end
         return a.name < b.name
      end)
   local parts = {}
   for i = 1, math.min(n, #list) do
      table.insert(parts, list[i].name .. ':' .. list[i].count)
   end
   return table.concat(parts, ';'), #list
end

-- Live custom AI actions per entity id: ctor -> adds minus removes.
local custom_actions = {}

local function install_ai_counters()
   local AIComponent = radiant.mods.require('stonehearth.components.ai.ai_component')
   local add, remove = AIComponent.add_custom_action, AIComponent.remove_custom_action
   AIComponent.add_custom_action = function(self, ctor, ...)
      local id = self._entity:get_id()
      local per_entity = custom_actions[id]
      if not per_entity then
         per_entity = {}
         custom_actions[id] = per_entity
      end
      per_entity[ctor] = (per_entity[ctor] or 0) + 1
      return add(self, ctor, ...)
   end
   AIComponent.remove_custom_action = function(self, ctor, ...)
      local per_entity = custom_actions[self._entity:get_id()]
      if per_entity and per_entity[ctor] then
         per_entity[ctor] = per_entity[ctor] - 1
         if per_entity[ctor] <= 0 then
            per_entity[ctor] = nil
         end
      end
      return remove(self, ctor, ...)
   end
end

-- Native spatial caches: AiService:create_spatial_cache keeps one per distinct filter function for
-- the rest of the session (base ai_service.lua:632-642), so a caller that passes a new closure for
-- every search adds a cache every time (finding R7). Counted per description.
local spatial_seen = {}          -- filter_fn -> true (the engine holds them strongly as well)
local spatial_total, spatial_new = 0, 0
local spatial_by_description = {}

local function install_spatial_cache_counter()
   local AiService = radiant.mods.require('stonehearth.services.server.ai.ai_service')
   local create = AiService.create_spatial_cache
   if type(create) ~= 'function' then
      emit('spatial_caches', { available = false })
      return
   end
   AiService.create_spatial_cache = function(self, filter_fn, filter_key, description, ...)
      if filter_fn ~= nil and not spatial_seen[filter_fn] then
         spatial_seen[filter_fn] = true
         spatial_total = spatial_total + 1
         spatial_new = spatial_new + 1
         local d = tostring(description)
         spatial_by_description[d] = (spatial_by_description[d] or 0) + 1
      end
      return create(self, filter_fn, filter_key, description, ...)
   end
end

-- Fast-call filter caches: AiService:fast_call_filter_fn keeps a native FilterResultCache per
-- distinct filter function in FAST_CALL_CACHES, a strong table (base ai_service.lua:35, 569-583).
-- ACE's storage searches call it with whatever filter the caller passed, including a new closure
-- per restock errand (finding R7b). This wraps a hot path: census runs are never timing runs.
local fast_seen = {}             -- filter_fn -> true (FAST_CALL_CACHES holds them strongly as well)
local fast_total, fast_new = 0, 0

local function install_fast_call_counter()
   local AiService = radiant.mods.require('stonehearth.services.server.ai.ai_service')
   local fast_call = AiService.fast_call_filter_fn
   if type(fast_call) ~= 'function' then
      emit('fast_call', { available = false })
      return
   end
   AiService.fast_call_filter_fn = function(self, filter_fn, entity)
      if filter_fn ~= nil and not fast_seen[filter_fn] then
         fast_seen[filter_fn] = true
         fast_total = fast_total + 1
         fast_new = fast_new + 1
      end
      return fast_call(self, filter_fn, entity)
   end
end

local function census_fast_call()
   emit('fast_call', { total = fast_total, new = fast_new })
   fast_new = 0
end

-- ACE storage filter caches (AceStorageComponent:_get_filter_cache, ace_storage_component.lua:328-342):
-- each holds a passed and an untested table of the storage's items and is walked on every item
-- change (reconsider_entity_in_filter_caches). Read from every storage registered in an inventory.
local function census_storage_filter_caches()
   local inventories = stonehearth.inventory and stonehearth.inventory._sv.inventories
   if not inventories then
      return
   end
   local seen, storages, total, max, entries = {}, 0, 0, 0, 0
   local by_site = {}   -- where each cache's filter function was defined, to find who creates them
   for _, inventory in pairs(inventories) do
      for _, by_id in pairs(inventory._sv._storage or {}) do
         for id, entity in pairs(by_id) do
            local storage = not seen[id] and entity and entity:is_valid() and entity:get_component('stonehearth:storage')
            seen[id] = true
            if storage and storage._storage_filter_cache then
               storages = storages + 1
               local n = 0
               for filter_fn, cache in pairs(storage._storage_filter_cache) do
                  n = n + 1
                  local info = type(filter_fn) == 'function' and debug.getinfo(filter_fn, 'S')
                  local site = info and (tostring(info.short_src) .. ':' .. tostring(info.linedefined)) or type(filter_fn)
                  by_site[site] = (by_site[site] or 0) + 1
                  for _ in pairs(cache.passed or {}) do entries = entries + 1 end
                  for _ in pairs(cache.untested or {}) do entries = entries + 1 end
               end
               total = total + n
               if n > max then
                  max = n
               end
            end
         end
      end
   end
   if storages > 0 then
      local top, sites = top_entries(by_site, TOP_N)
      emit('storage_filter_caches', { storages = storages, total = total, max = max, entries = entries,
                                      sites = sites, top = top })
   end
end

-- Stall hunt (experiment 001): a job-list step that never returned on 2026-10-28 17:36 was a
-- building plan's nav-grid clone, which walks the tiles within the bounds it is given.
-- ACE's BlueprintsToBuildingPiecesJob:clone_nav_grid
-- passes Cube3() as those bounds. If the default constructor leaves the cube uninitialized, the
-- bounds are whatever the memory held, and rarely huge. Log what each call receives and how long it
-- takes, and what a few fresh Cube3() hold.
local Cube3 = _radiant.csg.Cube3

local function cube_text(c)
   local ok, text = pcall(function()
         return string.format('%s,%s,%s..%s,%s,%s', tostring(c.min.x), tostring(c.min.y), tostring(c.min.z),
                              tostring(c.max.x), tostring(c.max.y), tostring(c.max.z))
      end)
   return ok and text or ('unreadable:' .. tostring(c))
end

local function census_default_cubes()
   local parts = {}
   for i = 1, 5 do
      table.insert(parts, cube_text(Cube3()))
   end
   emit('default_cube', { cubes = table.concat(parts, ';') })
end

local function install_clone_probe()
   local sim = _radiant.sim
   local clone = sim and sim.clone_nav_grid
   if type(clone) ~= 'function' then
      emit('clone_nav_grid', { available = false })
      return
   end
   sim.clone_nav_grid = function(bounds, ...)
      local text = cube_text(bounds)
      emit('clone_nav_grid', { at = 'start', bounds = text })
      local t0 = _host:get_realtime_us()
      local id = clone(bounds, ...)
      local dt = (_host:get_realtime_us() - t0) % 4294967296   -- unsigned 32-bit counter
      emit('clone_nav_grid', { at = 'end', bounds = text, ms = math.floor(dt / 1000), id = tostring(id) })
      return id
   end
end

local function census_spatial_caches()
   local top = top_entries(spatial_by_description, TOP_N)
   emit('spatial_caches', { total = spatial_total, new = spatial_new, top = top })
   spatial_new = 0
end

local function census_ai()
   local entities, total, max, max_id = 0, 0, 0, nil
   -- keys: distinct (entity, action) pairs, while total counts adds minus removes, so an action added
   -- again for the same key (a worker rejoining a group) counts once in keys and twice in total
   local keys, max_keys = 0, 0
   local by_name = {}
   for id, per_entity in pairs(custom_actions) do
      if radiant.entities.get_entity(id) then
         local n, k = 0, 0
         for ctor, count in pairs(per_entity) do
            n = n + count
            k = k + 1
            local name = type(ctor) == 'table' and ctor.name or tostring(ctor)
            by_name[name] = (by_name[name] or 0) + count
         end
         keys = keys + k
         if k > max_keys then
            max_keys = k
         end
         if n > 0 then
            entities = entities + 1
            total = total + n
            if n > max then
               max, max_id = n, id
            end
         end
      else
         custom_actions[id] = nil
      end
   end
   local top = top_entries(by_name, TOP_N)
   emit('ai_custom', { entities = entities, total = total, max = max, max_entity = tostring(max_id), top = top,
                       keys = keys, max_keys = max_keys })
end

-- radiant.events.listen_once registers its own wrapper closure, so every listen_once listener has the
-- same defining line (radiant/modules/events.lua:156). This copy of listen_once (same body) records
-- the line that called it, so listener_sites can name the real site ('once@<caller>').
local once_sites = setmetatable({}, { __mode = 'k' })   -- wrapper closure -> caller 'source:line'

local function install_listen_once_sites()
   local events = radiant.events
   events.listen_once = function(object, event, obj, method)
      local fn = function(...)
            if method then
               method(obj, ...)
            else
               obj(...)
            end
            return radiant.events.UNLISTEN
         end
      local info = debug.getinfo(2, 'Sl')
      if info then
         once_sites[fn] = string.format('%s:%d', info.short_src or '?', info.currentline or 0)
      end
      return events.listen(object, event, fn)
   end
end

local function census_listeners()
   local events = radiant.events
   if not events._senders then
      emit('listeners', { available = false })
      return
   end
   local counts, total = {}, 0
   local sites = {}   -- 'event@source:line' -> live listener count
   for _, senders in ipairs({ events._senders, events._global_senders, events._side_senders, events._side_global_senders }) do
      for _, sender in pairs(senders) do
         for event, listeners in pairs(sender) do
            for _, entry in pairs(listeners) do
               if not entry.dead then
                  counts[event] = (counts[event] or 0) + 1
                  total = total + 1
                  -- listen(sender, event, fn) stores fn as the instance, whereas listen(sender, event, obj, method) stores method
                  local fn = type(entry.fn) == 'function' and entry.fn or entry.instance
                  local site = '?'
                  if type(fn) == 'function' and once_sites[fn] then
                     site = 'once@' .. once_sites[fn]
                  elseif type(fn) == 'function' then
                     local info = debug.getinfo(fn, 'S')
                     site = string.format('%s:%d', info.short_src or '?', info.linedefined or 0)
                  end
                  local key = event .. '@' .. site
                  sites[key] = (sites[key] or 0) + 1
               end
            end
         end
      end
   end
   local top, distinct = top_entries(counts, TOP_N)
   emit('listeners', { available = true, total = total, events = distinct, top = top })
   local top_sites = top_entries(sites, 25)
   emit('listener_sites', { top = top_sites })
end

-- Optional (mods.perf_census.native_timing=true): wrap native functions that Lua calls synchronously
-- and accumulate their real time, which the Lua CPU profiler cannot see (it counts Lua instructions).
local REALTIME_WRAP = 4294967296   -- _host:get_realtime_us() is an unsigned 32-bit counter
local native_time = {}             -- name -> { calls, us, max_us }

local function wrap_native(table_ref, table_name)
   if type(table_ref) ~= 'table' then
      return 0
   end
   local names = {}
   for name, fn in pairs(table_ref) do
      if type(fn) == 'function' then
         table.insert(names, name)
      end
   end
   for _, name in ipairs(names) do
      local fn = table_ref[name]
      local key = table_name .. '.' .. name
      local stats = { calls = 0, us = 0, max_us = 0 }
      native_time[key] = stats
      table_ref[name] = function(...)
         local t0 = _host:get_realtime_us()
         local r = { n = 0 }
         local function keep(...)
            r.n = select('#', ...)
            for i = 1, r.n do
               r[i] = (select(i, ...))
            end
         end
         keep(fn(...))
         local dt = _host:get_realtime_us() - t0
         if dt < 0 then
            dt = dt + REALTIME_WRAP
         end
         stats.calls = stats.calls + 1
         stats.us = stats.us + dt
         if dt > stats.max_us then
            stats.max_us = dt
         end
         return unpack(r, 1, r.n)
      end
   end
   return #names
end

local function install_native_timing()
   local sim = _radiant.sim
   local n = wrap_native(sim.topology, 'topology') + wrap_native(sim.adjacency, 'adjacency')
   -- selected free functions in _radiant.sim (wrapping all of it would include hot getters)
   local selected = {}
   for _, name in ipairs({ 'clone_nav_grid', 'destroy_nav_grid', 'create_astar_path_finder',
                           'create_bfs_path_finder', 'create_direct_path_finder' }) do
      if type(sim[name]) == 'function' then
         selected[name] = sim[name]
      end
   end
   n = n + wrap_native(selected, 'sim')
   for name, fn in pairs(selected) do
      sim[name] = fn
   end
   emit('native_timing', { wrapped = n })
end

local function census_native()
   local list = {}
   for name, stats in pairs(native_time) do
      if stats.calls > 0 then
         table.insert(list, { name = name, stats = stats })
      end
   end
   table.sort(list, function(a, b) return a.stats.us > b.stats.us end)
   local parts = {}
   for i = 1, math.min(15, #list) do
      local s = list[i].stats
      table.insert(parts, string.format('%s:%d calls/%d ms/max %d ms', list[i].name, s.calls,
                                        math.floor(s.us / 1000), math.floor(s.max_us / 1000)))
   end
   emit('native', { top = table.concat(parts, ';') })
end

-- Town placement requests (finding E1): the entries a town offers to its item placement actions,
-- against the ghosts that still want each item type. Ghosts request on _add_to_town and release the
-- request only when the item has a placement limit (base and ACE ghost_form _remove_from_town), and
-- with ACE the release looks the entry up under a different key than the request used, so entries
-- can outlive their ghosts. An entry with no live ghost is stale: placement actions still try it (5 s failsafe each).
local function census_placement_tasks()
   local towns = stonehearth.town and stonehearth.town._sv.towns
   if not towns then
      return
   end
   local sep = stonehearth.constants.item_quality.KEY_SEPARATOR
   local live = {}   -- player_id -> key -> live ghosts that request placement
   local ghosts = 0
   for _, entity in pairs(_radiant.sim.get_all_entities()) do
      local ghost = entity:is_valid() and entity:get_component('stonehearth:ghost_form')
      if ghost and ghost.is_place_item_type and ghost:is_place_item_type() then
         local quality = ghost._sv.quality
         local key = ghost._sv.placement_info.iconic_uri .. sep .. (quality and tostring(quality) or 'any')
         local player_id = radiant.entities.get_player_id(entity)
         live[player_id] = live[player_id] or {}
         live[player_id][key] = (live[player_id][key] or 0) + 1
         ghosts = ghosts + 1
      end
   end
   local entries, stale, count_sum = 0, 0, 0
   local stale_keys = {}
   local function visit(player_id, key, entry)
      entries = entries + 1
      count_sum = count_sum + (entry.count or 0)
      if not (live[player_id] and live[player_id][key]) then
         stale = stale + 1
         local short = key:match('([^:/]+)$') or key
         stale_keys[short] = (stale_keys[short] or 0) + 1
      end
   end
   for player_id, town in pairs(towns) do
      for _, tasks in ipairs({ town._placement_tasks or {}, town._build_placement_tasks or {} }) do
         for k, v in pairs(tasks) do
            if type(v) == 'table' and v.iconic_uri then
               visit(player_id, k, v)                     -- base: key -> entry
            elseif type(v) == 'table' then
               for key, entry in pairs(v) do              -- ACE: placement tag -> key -> entry
                  if type(entry) == 'table' and entry.iconic_uri then
                     visit(player_id, key, entry)
                  end
               end
            end
         end
      end
   end
   emit('placement_tasks', { entries = entries, stale = stale, count_sum = count_sum, ghosts = ghosts,
                             top = top_entries(stale_keys, 10) })
end

-- Nearby item searches (experiment 004 mechanism check): game seconds from a NearbyItemSearch's
-- first finder (_search, which __init calls first) to _done_searching, and the results it hands
-- back. Restock errands wait on these searches, so a slower search means slower restocking in game
-- time. Installed on the first game loop, after steady_hearth has installed its patches, so it
-- wraps whatever methods are installed (no patch replaces _search or _done_searching).
local nearby = { started = 0, done = 0, results = 0, empty = 0, timeouts = 0, waits = {} }

local function install_nearby_search_probe()
   local ok, NearbyItemSearch = pcall(radiant.mods.require, 'stonehearth.services.server.inventory.nearby_item_search')
   if not ok or type(NearbyItemSearch) ~= 'table' or not NearbyItemSearch._search or not NearbyItemSearch._done_searching then
      emit('nearby_search', { available = false })
      return
   end
   local search, done_searching = NearbyItemSearch._search, NearbyItemSearch._done_searching
   NearbyItemSearch._search = function(self, ...)
      if not self._perf_census_t0 then
         self._perf_census_t0 = stonehearth.calendar:get_elapsed_time()
         nearby.started = nearby.started + 1
      end
      return search(self, ...)
   end
   NearbyItemSearch._done_searching = function(self, ...)
      local counted = self._perf_census_t0 and self._done_cb
      local result = done_searching(self, ...)
      if counted then
         local wait = stonehearth.calendar:get_elapsed_time() - self._perf_census_t0
         local n = self._results and #self._results or 0
         nearby.done = nearby.done + 1
         nearby.results = nearby.results + n
         if n == 0 then
            nearby.empty = nearby.empty + 1
         end
         if wait >= 1799 then
            nearby.timeouts = nearby.timeouts + 1   -- its 30 game minute timeout ended it
         end
         table.insert(nearby.waits, wait)
      end
      return result
   end
end

local function census_nearby_search()
   local waits = nearby.waits
   table.sort(waits)
   local function pct(p)
      return #waits > 0 and string.format('%.1f', waits[math.max(1, math.ceil(#waits * p))]) or '-'
   end
   local sum = 0
   for _, w in ipairs(waits) do
      sum = sum + w
   end
   emit('nearby_search', { started = nearby.started, done = nearby.done, results = nearby.results,
                           empty = nearby.empty, timeouts = nearby.timeouts, n = #waits,
                           wait_mean = #waits > 0 and string.format('%.1f', sum / #waits) or '-',
                           wait_p50 = pct(0.5), wait_p90 = pct(0.9), wait_max = pct(1) })
   nearby.waits = {}   -- the wait figures cover the interval since the previous census; counts are totals
end

local function run_census()
   local game_s = stonehearth.calendar:get_elapsed_time()
   collectgarbage('collect')
   emit('heap', { game_s = string.format('%.0f', game_s), lua_kb = math.floor(collectgarbage('count')) })
   census_listeners()
   census_ai()
   census_spatial_caches()
   census_fast_call()
   census_storage_filter_caches()
   local ok, err = pcall(census_placement_tasks)   -- new probe: an error must not cost the lines after it
   if not ok then
      emit('placement_tasks', { error = tostring(err) })
   end
   census_nearby_search()
   census_default_cubes()
   if next(native_time) then
      census_native()
   end
end

local function start()
   install_ai_counters()
   install_spatial_cache_counter()
   install_fast_call_counter()
   install_clone_probe()
   if radiant.events._senders ~= nil then
      install_listen_once_sites()   -- only the Lua event manager's listeners can be counted
   end
   census_default_cubes()
   local timing = _host:get_config('mods.perf_census.native_timing')
   if timing == true or timing == 'true' then
      local ok, err = pcall(install_native_timing)
      if not ok then
         emit('native_timing', { error = tostring(err) })
      end
   end
   local next_at = nil
   radiant.on_game_loop('perf census', function()
         local game_s = stonehearth.calendar:get_elapsed_time()
         if not next_at then
            next_at = game_s + INTERVAL_S
            local ok, err = pcall(install_nearby_search_probe)
            if not ok then
               emit('nearby_search', { error = tostring(err) })
            end
         elseif game_s >= next_at then
            next_at = next_at + INTERVAL_S
            run_census()
         end
      end)
   if radiant.events._senders ~= nil and rawget(_G, 'stonehearth_ace') then
      -- ACE (like base code) listens on and triggers nil senders, which only the C++ event manager
      -- accepts, so in Lua events mode ACE world generation fails (docs/harness/bench.md, error review)
      emit('warning', { what = 'lua events mode is not supported with ACE; listener census unreliable' })
   end
   emit('start', { interval_s = INTERVAL_S, lua_events = radiant.events._senders ~= nil,
                   nil_sender_guard = NIL_SENDER_GUARD })
end

-- Install after ACE's monkey patches when ACE is present, so the wrappers see the final methods.
-- ACE fires its event from its own radiant:required_loaded handler, which may run before or after
-- ours, so listen for it from load time and start on whichever event applies.
local started = false
local function start_once()
   if not started then
      started = true
      start()
   end
end
radiant.events.listen_once(radiant, 'stonehearth_ace:server:required_loaded', start_once)
radiant.events.listen_once(radiant, 'radiant:required_loaded', function()
      if not rawget(_G, 'stonehearth_ace') then
         start_once()
      end
   end)

return perf_census
