-- ACE NearbyItemSearch: accept an optional per-search predicate, checked on every found item
-- (finding R7, part 1 of 2; part 2 is ace_restock_shared_nearby_filter).
--
-- NearbyItemSearch:_search keys a native spatial cache by tostring(filter_fn), and
-- AiService:create_spatial_cache keeps one cache per distinct filter function for the rest of the
-- session. ACE's restock director passes a new closure for every errand (best_filter_fn: the
-- storage's shared filter plus a priority check that depends on the errand), so every restock
-- errand adds a permanent cache. With this predicate, the director can pass the shared filter (one
-- cache per storage filter, as the base game does) and the priority check separately. _add_result
-- applies it before anything else, as when it was part of the finder's filter: the same items are
-- accepted, in the same distance order (rejected ones return false and the finder goes on). For
-- storages, eval_best_passing_item keeps a per-filter cache whose state changes the order in which
-- it offers items (review 2026-10-28: with a warm shared cache a different, equally valid item can
-- fill the last slot), so storages are evaluated with a fresh per-search closure (priority check,
-- then filter), exactly what the shipped caller passed. Without a predicate (other callers)
-- nothing changes. Copies of the ACE override's methods with the marked additions.
--
-- Finding R7b, same root: a per-search filter also leaves state behind that nothing uses again.
-- Each storage it evaluates keeps a filter cache for it (AceStorageComponent:_get_filter_cache: a
-- copy of the storage's items, kept until the storage is destroyed and walked by
-- reconsider_entity_in_filter_caches on every item change), and AiService:fast_call_filter_fn keeps
-- a native FilterResultCache for it in FAST_CALL_CACHES for the rest of the session, which
-- AiService:_add_reconsidered_entity walks on every reconsider. So _cleanup removes the search's
-- filter cache from every storage it visited (while the search runs, the storage caches are
-- registered and maintained by ACE as shipped; after it ends nothing calls its filter again). And
-- when ace_reconsider_clears_search_caches is installed (it clears reconsidered entities from the
-- result caches of running searches, as the shipped loop does for FAST_CALL_CACHES), storages are
-- evaluated by a copy of AceStorageComponent:eval_best_passing_item that uses the search's own
-- FilterResultCache (built exactly as fast_call_filter_fn builds one), dropped when the search ends;
-- without it, through fast_call_filter_fn as shipped.

local FilterResultCache = _radiant.sim.FilterResultCache
local AiService = radiant.mods.require('stonehearth.services.server.ai.ai_service')

-- result caches of the searches still running (weak: a search dropped without _cleanup takes its
-- cache with it), and the reconsider wrapper that clears them, set by
-- ace_reconsider_clears_search_caches when its file loads
local hooks = { active_result_caches = setmetatable({}, { __mode = 'k' }), reconsider = nil }

local function reconsider_hook_installed()
   return hooks.reconsider ~= nil and AiService._add_reconsidered_entity == hooks.reconsider
end

local function init(self, player_id, src_entity, filter_fn, inclusion_filter_fn, exclusion_filter, max_results, done_cb, rating_fn, extra_predicate)
   self._player_id = player_id
   self._entity = src_entity
   self._filter_fn = filter_fn
   self._results = {}
   self._backup_results = {}
   self._result_ids = {}
   self._done_cb = done_cb
   self._max_results = max_results
   self._inclusion_filter_fn = inclusion_filter_fn
   self._exclusion_filter = exclusion_filter
   self._rating_fn = rating_fn
   -- perf: a per-search predicate checked on each found item, and for storages the same fresh
   -- per-search filter the shipped caller passed (see the header)
   self._perf_extra_predicate = extra_predicate
   if extra_predicate then
      self._perf_storage_filter = function(item)
         if extra_predicate(item) then
            return filter_fn(item)
         else
            return false
         end
      end
   end

   -- Start looking around us on the ground by default.
   self._ground_item_finder = self:_search(self._entity, self._filter_fn,
         function(item)
            return self:_add_result(item)
         end,
         function()
            self:_exhausted_ground_item_finder()
         end)

   -- Sometimes searches might get stuck. Time them out after a while.
   self._timeout_timer = stonehearth.calendar:set_timer('nearby item timeout', '30m', function()
         self:_done_searching()
      end)
end

local function add_result(self, item)
   -- perf: the per-search predicate first, as when it was part of the item finder's filter
   local extra_predicate = self._perf_extra_predicate
   if extra_predicate and not extra_predicate(item) then
      return false
   end
   local item_id = item:get_id()
   if item ~= self._entity and not self._result_ids[item_id] and not self._exclusion_filter[item_id] and
         stonehearth.ai:fast_call_filter_fn(self._inclusion_filter_fn, item) then
      self._result_ids[item_id] = true
      local rating = self._rating_fn and self._rating_fn(item)
      if not rating or rating >= 1 then
         table.insert(self._results, item)

         if #self._results >= self._max_results then
            self:_done_searching()
            return true
         end
      else
         table.insert(self._backup_results, {item = item, rating = rating})
      end
   end
   return false
end

-- Copy of AceStorageComponent:eval_best_passing_item (ace_storage_component.lua:401-440, guarded by
-- requires below) with the search's own FilterResultCache in place of fast_call_filter_fn.
local function eval_best_passing_item(self, storage, filter_fn, is_max_rating_fn)
   local cache = storage:_get_filter_cache(filter_fn)
   local passed, untested = cache.passed, cache.untested

   -- first process through all passed items
   for id, item in pairs(passed) do
      if item:is_valid() then
         if is_max_rating_fn(id, item) then
            return
         end
      else
         rawset(passed, id, nil)
      end
   end

   -- if we have no untested items, return false
   if not next(untested) then
      return
   end

   -- perf: the search's own result cache, built as AiService:fast_call_filter_fn builds one and
   -- cleared on reconsider like FAST_CALL_CACHES (ace_reconsider_clears_search_caches)
   local filter_rc = self._perf_filter_rc
   if not filter_rc then
      filter_rc = FilterResultCache(FilterResultCache.INVALIDATE_ON_MOVE + FilterResultCache.INVALIDATE_ON_PLAYER_ID_CHANGED)
      filter_rc:set_filter_fn('fast call for ' .. tostring(filter_fn), filter_fn)
      self._perf_filter_rc = filter_rc
      hooks.active_result_caches[filter_rc] = true
   end
   for id, item in pairs(untested) do
      rawset(untested, id, nil)
      if filter_rc:consider_entity(item) then
         rawset(passed, id, item)
         if is_max_rating_fn(id, item) then
            return true
         end
      end
   end

   return
end

local function exhausted_ground_item_finder(self)
   if self._ground_item_finder then
      self._ground_item_finder:destroy()
      self._ground_item_finder = nil
   end

   local is_valid_storage_predicate = stonehearth.ai:filter_from_key('is_nonempty_public_storage', '', function(storage_entity)
         local storage = storage_entity:get_component('stonehearth:storage')
         return storage and storage:is_public() and not storage:is_empty()
      end)

   local process_storage = function(storage_entity)
         local found_item = false
         local is_max_rating_fn = function(id, item)
               if self:_add_result(item) then
                  found_item = true
                  return true
               end
            end
         local storage = storage_entity:get_component('stonehearth:storage')
         -- perf: the per-search filter, as shipped (storage filter caches are keyed by the filter
         -- function), evaluated so that the search can release its caches when it ends (R7b)
         if self._perf_storage_filter then
            self._perf_visited_storages = self._perf_visited_storages or {}
            self._perf_visited_storages[storage_entity:get_id()] = storage
            if reconsider_hook_installed() then
               eval_best_passing_item(self, storage, self._perf_storage_filter, is_max_rating_fn)
            else
               storage:eval_best_passing_item(self._perf_storage_filter, is_max_rating_fn)
            end
         else
            storage:eval_best_passing_item(self._filter_fn, is_max_rating_fn)
         end

         return found_item
      end

   if #self._results >= self._max_results then
      return
   end

   if stonehearth.ai:fast_call_filter_fn(is_valid_storage_predicate, self._entity) then
      process_storage(self._entity)
   end

   self._storage_item_finder = self:_search(self._entity, is_valid_storage_predicate, process_storage, function()
         self:_done_searching()
      end)
end

local function cleanup(self)
   if self._ground_item_finder then
      self._ground_item_finder:destroy()
      self._ground_item_finder = nil
   end
   if self._storage_item_finder then
      self._storage_item_finder:destroy()
      self._storage_item_finder = nil
   end
   if self._timeout_timer then
      self._timeout_timer:destroy()
      self._timeout_timer = nil
   end
   -- perf: release the search's filter cache from every storage it visited (R7b); nothing calls the
   -- search's filter again, and a destroyed storage has already dropped its caches
   local visited = self._perf_visited_storages
   if visited then
      self._perf_visited_storages = nil
      local filter_fn = self._perf_storage_filter
      for _, storage in pairs(visited) do
         local caches = storage._storage_filter_cache
         if caches and caches[filter_fn] then
            caches[filter_fn] = nil
            storage._num_storage_filter_caches = storage._num_storage_filter_caches - 1
         end
      end
   end
   if self._perf_filter_rc then
      hooks.active_result_caches[self._perf_filter_rc] = nil
      self._perf_filter_rc = nil
   end
end

local SOURCE = 'services/server/inventory/nearby_item_search.lua'
local STORAGE_SOURCE = 'stonehearth_ace/monkey_patches/ace_storage_component.lua'

return {
   id = 'ace_nearby_search_extra_predicate',
   default_enabled = true,    -- decision 2026-10-29 after the mechanism check (experiment 004), the three R7 patches together
   target_ace = true,
   module = 'stonehearth.services.server.inventory.nearby_item_search',
   method = '__init',
   expect = { source_suffix = SOURCE, linedefined = 7, lastlinedefined = 33 },
   replacement = init,
   also = {
      {
         method = '_add_result',
         expect = { source_suffix = SOURCE, linedefined = 94, lastlinedefined = 112 },
         replacement = add_result,
      },
      {
         method = '_exhausted_ground_item_finder',
         expect = { source_suffix = SOURCE, linedefined = 39, lastlinedefined = 73 },
         replacement = exhausted_ground_item_finder,
      },
      {
         method = '_cleanup',
         expect = { source_suffix = SOURCE, linedefined = 134, lastlinedefined = 147 },
         replacement = cleanup,
      },
   },
   -- the ACE storage methods this patch copies or calls must be the ones it was written against
   hooks = hooks,
   requires = {
      {
         module = 'stonehearth.components.storage.storage_component',
         method = 'eval_best_passing_item',
         expect = { source_suffix = STORAGE_SOURCE, linedefined = 401, lastlinedefined = 440 },
      },
      {
         module = 'stonehearth.components.storage.storage_component',
         method = '_get_filter_cache',
         expect = { source_suffix = STORAGE_SOURCE, linedefined = 328, lastlinedefined = 342 },
      },
   },
}
