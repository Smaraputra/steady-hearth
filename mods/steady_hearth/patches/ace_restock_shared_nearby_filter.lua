-- ACE restock director: search for extra items with the storage's shared filter and check the
-- errand's priority on each found item (finding R7, part 2 of 2; needs ace_nearby_search_extra_predicate).
--
-- ACE's _generate_next_errand passes best_filter_fn, a new closure per errand, to
-- NearbyItemSearch, which keys a permanent native spatial cache by it, so caches accumulate with
-- every restock errand and keep evaluating their filters. The ACE window profile of 2026-10-28 put
-- about 42% of ACE's Lua samples in this filter path (docs/atlas/profiles-2026-10-28.md). This copy
-- passes filter_fn (one shared function per storage filter key, from filter_from_key, as the base
-- game does) and the priority check as the search's extra predicate. It does so only when the
-- NearbyItemSearch patch is the installed implementation (checked by function identity); otherwise
-- it runs exactly as shipped, so enabling one patch without the other cannot drop the check.
-- Copy of the ACE override's method with the marked addition; the file's locals are recreated.

local constants = require 'stonehearth.constants'
local NearbyItemSearch = radiant.mods.require('stonehearth.services.server.inventory.nearby_item_search')
local nearby_patch = require 'steady_hearth.patches.ace_nearby_search_extra_predicate'

local get_world_location = radiant.entities.get_world_location
local get_item_quality = radiant.entities.get_item_quality
local MAX_EXTRA_ITEMS = constants.inventory.restock_director.MAX_EXTRA_ITEMS
local log = radiant.log.create_logger('restock_director')

local function nearby_patch_installed()
   return NearbyItemSearch.__init == nearby_patch.replacement
      and NearbyItemSearch._add_result == nearby_patch.also[1].replacement
      and NearbyItemSearch._exhausted_ground_item_finder == nearby_patch.also[2].replacement
end

local function generate_next_errand(self)
   if not next(self._storages_by_filter) then
      return  -- We have nowhere to restock things to.
   end
   if self._active_nearby_item_search then
      return  -- We'll recurse later once we're done.
   end
   -- Check size.
   local num_errands = 0
   local max_errands = self:_get_max_errands()
   for _ in pairs(self._errands) do
      num_errands = num_errands + 1
      if num_errands >= max_errands then
         return
      end
   end

   --log:debug('%s generating next errand', self._director_name)

   -- Select a valid item.
   local target_item, best_storage, filter_fn = self:_get_next_restockable_item()
   if not target_item then
      -- After a delay, requeue failed items.
      if next(self._failed_items) then
         self:_request_process_failed_items()
      end
      return
   end

   -- Find nearby items that we can opportunistically include.
   local search_src_entity
   if get_world_location(target_item) then
      search_src_entity = target_item
   else
      search_src_entity = self._inventory:container_for(target_item)
   end

   local best_storage_component = best_storage:get('stonehearth:storage')
   local storage_priority = best_storage_component:get_input_bin_priority()
   local best_filter_fn = function(item)
      if self:_is_higher_priority_for_item(item, search_src_entity, storage_priority) then
         return filter_fn(item)
      else
         return false
      end
   end

   local prioritize_high_quality = best_storage_component:get_prioritize_restocking_high_quality()
   local rating_fn = function(item)
      local item_quality = get_item_quality(item)
      if prioritize_high_quality then
         return item_quality - 1
      elseif item_quality == stonehearth.constants.item_quality.NORMAL then
         return 1
      else
         return 0
      end
   end

   local errand_id = self._current_errand_id
   local target_item_id = target_item:get_id()
   self._covered_items[target_item_id] = errand_id  -- Need to do this before the search so we don't choose this as an extra item.
   local storage_space_lease = best_storage:get_component('stonehearth:storage'):reserve_space(nil, 'restock errand')  -- Get an initial lease for one item.
   -- perf: with the NearbyItemSearch patch installed, search with the storage's shared filter (its
   -- spatial cache is shared and bounded) and check the priority on each found item instead
   local nearby_filter_fn, extra_predicate = best_filter_fn, nil
   if nearby_patch_installed() then
      nearby_filter_fn = filter_fn
      extra_predicate = function(item)
         return self:_is_higher_priority_for_item(item, search_src_entity, storage_priority)
      end
   end
   self._active_nearby_item_search = NearbyItemSearch(self._player_id, search_src_entity, nearby_filter_fn, self._is_restockable_predicate, self._covered_items, MAX_EXTRA_ITEMS, function(extra_items)
         local item_location = get_world_location(search_src_entity)
         if item_location and get_world_location(best_storage) then  -- The target item may have gotten moved/destroyed while we were searching.
            -- Replace the initial lease with one that also includes the extra items, if possible.
            storage_space_lease:destroy()
            local best_storage_component = best_storage:get_component('stonehearth:storage')
            if best_storage_component then  -- storage might be destroyed while searching for nearby items
               -- trim down the extra items to only those that are still valid and not already covered by another errand
               for i, extra_item in ipairs(extra_items) do
                  if extra_item and extra_item:is_valid() then
                     if self._covered_items[extra_item:get_id()] then
                        extra_items[i] = nil
                     end
                  else
                     extra_items[i] = nil
                  end
               end

               storage_space_lease = best_storage_component:reserve_space(nil, 'restock errand', 1 + radiant.size(extra_items))
               if storage_space_lease then
                  -- Create the errand.
                  self._errands[errand_id] = {
                     id = errand_id,
                     filter_fn = filter_fn,
                     filter_key = self._storage_filters[best_storage:get_id()],
                     main_item = target_item,
                     item_location = item_location,
                     extra_items = extra_items,
                     storage = best_storage,
                     storage_space_lease = storage_space_lease,
                  }

                  for _, extra_item in ipairs(extra_items) do
                     self._covered_items[extra_item:get_id()] = errand_id
                  end

                  self._errands[errand_id].score = self:_rate_errand(self._errands[errand_id])
                  self._current_errand_id = (self._current_errand_id + 1) % 999999  -- avoid the (unlikely) float mantissa limit.

                  radiant.events.trigger_async(self, 'stonehearth:restock:errand_available', errand_id)
               end
            end
         else
            storage_space_lease:destroy()
            log:debug('Item/storage %s or destination storage %s not in world, marking %s as failed', search_src_entity, best_storage, target_item)
            self._failed_items[target_item_id] = target_item
         end

         self._active_nearby_item_search = nil
         self:_mark_ready_to_generate_new_errands()
      end, rating_fn, extra_predicate)
end

return {
   id = 'ace_restock_shared_nearby_filter',
   default_enabled = true,    -- decision 2026-10-29 after the mechanism check (experiment 004), the three R7 patches together
   target_ace = true,
   module = 'stonehearth.services.server.inventory.restock_director',
   method = '_generate_next_errand',
   expect = {
      source_suffix = 'services/server/inventory/restock_director.lua',
      linedefined = 743,
      lastlinedefined = 857,
   },
   replacement = generate_next_errand,
}
