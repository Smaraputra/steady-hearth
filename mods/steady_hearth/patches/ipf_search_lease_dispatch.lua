-- IpfSearch: one shared lease listener instead of one per search (lease fan-out, S4).
--
-- Every running IpfSearch (stonehearth/components/pathfinder/ipf_search.lua) listens to the global
-- 'stonehearth:lease_released' event, which every lease release fires once, and its listener only
-- acts when the released entity is one of its own solutions. Each release therefore calls every
-- running search. The vanilla window profile of 2026-10-28 puts 6.8% of all Lua samples on that
-- listener's first line (ipf_search.lua:146, filed under _start_pathfinder by the profiler; 5,701 of
-- 7,050 samples on line 146 and 1,173 on its end, almost all on the main thread).
--
-- This patch registers one listener for all searches and an index from solution entity id to the
-- searches holding that solution. A release calls only those searches, each in its own protected
-- call, and each still checks its solutions table at that moment, as its own listener did. They are
-- called in the order they started. The events module gives listeners of one event no defined order
-- (the Lua event manager walks them with pairs), so when one search's reaction stops another that
-- also holds the released item, which of the two hears the release first was already arbitrary;
-- this patch makes it the start order. The event, its timing (it is fired asynchronously) and every
-- search's reaction are unchanged. _start_pathfinder and _stop_pathfinder are copies of the base
-- game's with the listener replaced by the index; the solved closure also records its solution in
-- the index.
local dispatch = {
   listener = nil,
   by_entity = {},   -- entity id -> { [search] = start sequence }
   sequence = 0,
}

local function index_add(entity_id, search)
   local searches = dispatch.by_entity[entity_id]
   if not searches then
      searches = {}
      dispatch.by_entity[entity_id] = searches
   end
   searches[search] = search._perf_lease_seq
end

local function index_remove_all(search)
   for entity_id in pairs(search._solutions or {}) do
      local searches = dispatch.by_entity[entity_id]
      if searches then
         searches[search] = nil
         if not next(searches) then
            dispatch.by_entity[entity_id] = nil
         end
      end
   end
end

local function by_sequence(a, b)
   return a[2] < b[2]
end

local function on_lease_released(e)
   if e.lease_name ~= stonehearth.ai.RESERVATION_LEASE_NAME then
      return
   end
   local searches = dispatch.by_entity[e.entity_id]
   if not searches then
      return
   end
   local ordered = {}
   for search, sequence in pairs(searches) do
      table.insert(ordered, { search, sequence })
   end
   table.sort(ordered, by_sequence)
   for _, entry in ipairs(ordered) do
      local search = entry[1]
      -- a search stopped by an earlier one in this loop no longer listens, as its own listener
      -- would have been destroyed (the event loops skip dead listeners)
      if search._perf_lease_seq == entry[2] and search._solutions[e.entity_id] then
         -- each search in its own protected call, as the event loops call each listener: an error
         -- in one must not keep the others from hearing the release. Nothing is rethrown: the
         -- engine's event manager (the default) delivers this asynchronous event without rethrowing
         -- listener errors (review round 2, docs/experiments/006-ipf-search-lease-dispatch.md)
         radiant.xpcall(function()
               search._log:detail('got lease released on %s', e.entity_id)
               search:_on_leased_solution_ready(e.entity_id)
            end)
      end
   end
end

local function start_pathfinder(self)
   assert(not self._search)

   local function solved(path)
      local dst = path:get_destination()

      -- whoa, not so fast!  before we can pass this destination off to the pathfinders,
      -- make sure it's actually kosker.  "why isn't this done by the filter function?",
      -- you ask.  the filter function result for each entity is *heavily cached* by the
      -- FilterCacheResult object.  `_is_valid_destination` will check against certain
      -- transient conditions (e.g. can we get the ai lease?) which are inappropriate to
      -- cache
      if not self:_is_valid_destination(dst) then
         return false
      end

      local solution = {
         dst = dst,
         path = path,
      }
      self._solutions[dst:get_id()] = solution
      -- PERF: the shared lease listener finds this search through the index
      if self._perf_lease_seq then
         index_add(dst:get_id(), self)
      end

      self._log:debug('found solution %s!', dst)
      return self:_call_solved_cbs(solution)
   end

   local function exhausted_callback()
      if self._exhausted_callback then
         self._exhausted_callback()
      end
   end

   assert(radiant.empty(self._solved_cbs))

   self._solutions = {}
   self._already_solved = {}
   -- PERF: one shared listener for all searches instead of one per search
   if not dispatch.listener then
      dispatch.listener = radiant.events.listen(radiant, 'stonehearth:lease_released', on_lease_released)
   end
   dispatch.sequence = dispatch.sequence + 1
   self._perf_lease_seq = dispatch.sequence

   self._search = self._pathfinder:add_query(self._description, self._filter_key)
                                       :set_solved_cb(solved)
                                       :set_search_exhausted_cb(exhausted_callback)

   self._log:info('created ipf search id:%d', self._search:get_id())
end

local function stop_pathfinder(self)
   if self._search then
      self._log:info('removing search')
      self._search:destroy()
      self._search = nil
   end
   -- PERF: stop listening, as destroying the search's own listener did
   if self._perf_lease_seq then
      index_remove_all(self)
      self._perf_lease_seq = nil
   end
end

local SOURCE = 'components/pathfinder/ipf_search.lua'

return {
   id = 'ipf_search_lease_dispatch',
   default_enabled = true,    -- validated 2026-10-29: no errors on vanilla and ACE, lease share of Lua samples 7.2% to 1.5%
   module = 'stonehearth.components.pathfinder.ipf_search',
   method = '_start_pathfinder',
   expect = { source_suffix = SOURCE, linedefined = 109, lastlinedefined = 157 },
   replacement = start_pathfinder,
   also = {
      {
         method = '_stop_pathfinder',
         expect = { source_suffix = SOURCE, linedefined = 162, lastlinedefined = 172 },
         replacement = stop_pathfinder,
      },
   },
   requires = {
      -- called by the shared listener exactly as the per-search listener called it
      {
         module = 'stonehearth.components.pathfinder.ipf_search',
         method = '_on_leased_solution_ready',
         expect = { source_suffix = SOURCE, linedefined = 233, lastlinedefined = 246 },
      },
   },
   dispatch = dispatch,   -- for the census
}
