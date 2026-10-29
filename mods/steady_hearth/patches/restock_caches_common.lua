-- Restock director caches that the game's code sets up but does not use.
--
-- Rating cache (base game only): RestockDirector:_rate_item stores every rating in
-- _item_rating_cache (cleared every ITEM_RATING_CACHE_RESET_INTERVAL_SEC, 60 real seconds) but only
-- reads it while _item_rating_cache_enabled is true, and nothing sets that field; the only setter is
-- test_only_disable_rating_cache, which sets it to false. So every errand rating recomputes the
-- item's score (inventory tracker lookups). The wrap turns the flag on the first time a director
-- rates an item, unless something has set it already (an explicit false from the test helper stays).
-- ACE's copy of _rate_item has the same unused cache, but it scores an item in two modes
-- (include_tracking_rating) under one cache entry and sets up per-item quality data on the first call,
-- so turning its cache on would mix the modes and skip that setup; this mod leaves ACE's alone
-- (docs/ace-notes.md).
--
-- Validity window (base game and ACE, identical code): RestockDirector:_is_errand_valid keeps the time
-- an errand was last found valid and skips every check while `now - timestamp <=
-- ERRAND_VALIDITY_CACHE_EXPIRY_SEC` (20). `now` is radiant.gamestate.now(), which counts simulation
-- milliseconds (9 per game second, the clock the director's ERRAND_CONSIDER_LEASE_DURATION_MS is
-- added to), so that cache expires after 20 ms, less than one game tick, and every errand gets the full
-- check again on nearly every tick. The copy below keeps the original's 20 ms shortcut unchanged and
-- adds a longer window, WINDOW_MS (mods.steady_hearth.restock_validity_ms, default 2,000, about one
-- real second at game speed 2): within it, everything the check reads cheaply is still checked (the
-- item is still restockable, the storage still exists and still has the errand's filter, the item
-- still passes the errand's filter), and only the item-to-storage reachability query is skipped. A
-- full check is done at least every WINDOW_MS and records a new time; a failed check returns false
-- as before, and the caller then drops the errand and its time.

local constants = require 'stonehearth.constants'

local gamestate_now = radiant.gamestate.now
local ERRAND_VALIDITY_CACHE_EXPIRY_SEC = constants.inventory.restock_director.ERRAND_VALIDITY_CACHE_EXPIRY_SEC
local WINDOW_MS = tonumber(_host:get_config('mods.steady_hearth.restock_validity_ms')) or 2000

local common = {}

function common.rating_cache_wrap(original)
   return function(self, item, ...)
      if rawget(self, '_item_rating_cache_enabled') == nil then
         rawset(self, '_item_rating_cache_enabled', true)
      end
      return original(self, item, ...)
   end
end

-- Copy of RestockDirector:_is_errand_valid (base game 614-634, ACE 940-960, the same code), with the
-- marked change.
function common.is_errand_valid(self, errand_id, errand)
   local errand_last_validated = rawget(self, '_errand_last_validated')
   local timestamp = rawget(errand_last_validated, errand_id)
   local now = gamestate_now()
   if timestamp and now - timestamp <= ERRAND_VALIDITY_CACHE_EXPIRY_SEC then
      return true
   end

   local main_item = rawget(errand, 'main_item')
   local storage = rawget(errand, 'storage')
   local ai_service = rawget(stonehearth, 'ai')
   local fast_call_filter_fn = ai_service.fast_call_filter_fn
   -- steady_hearth: within WINDOW_MS of the last full check, skip only the reachability query
   local recent = timestamp and now - timestamp <= WINDOW_MS
   local result = fast_call_filter_fn(ai_service, self._is_restockable_predicate, main_item)
      and (recent and storage:is_valid() or self:_are_reachable(main_item, storage))
      and self._storage_filters[storage:get_id()] == rawget(errand, 'filter_key')
      and fast_call_filter_fn(ai_service, rawget(errand, 'filter_fn'), main_item)
   if result and not recent then
      rawset(errand_last_validated, errand_id, now)
   end
   return result
end

return common
