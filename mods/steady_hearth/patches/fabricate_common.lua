-- Shared builder for the fabricate_chunk fix (findings RT1 and B1), in a base and an ACE variant
-- (ACE replaces the whole file and adds the owning building to the think output).
--
-- FabricateChunk:_start_item_finder keeps its chunk finder running after the first match. Every
-- further chunk it finds calls ai:set_think_output again and starts another failsafe timer,
-- overwriting self._failsafe_timer without destroying the previous one. A late set_think_output
-- while the compound action is no longer thinking raises "CHECK failed: compound_action.cpp:151"
-- (about once per XL run), and the orphaned failsafe timers can later clear the think output and
-- reject the action. The fix sets the output once per thinking cycle, keeps a single failsafe timer
-- and stops the finder after the first match. The action's existing rejection flow (failsafe ->
-- reject -> restart, with _found_chunks skipping chunks already tried) moves on to other chunks.
local RETRY_TIMEOUT = 2500
local FAILSAFE_TIMEOUT = 5000

local function build_start_item_finder(ace)
   return function(self, ai, entity, args)
      self._think_output_set = false

      local exhausted_cb = function()
         if self._chunk_if == nil then
            return
         end

         self._chunk_if:destroy()
         self._chunk_if = nil
         self._found_chunks = {}

         -- We exhausted the universe.  But something might have become useful in the
         -- intervening time!  Loop around after waiting for a spell, and try again.
         self._retry_timer = radiant.set_realtime_timer('fabricate chunk retry', RETRY_TIMEOUT, function()
               self:_start_item_finder(ai, entity, args)
            end)
      end

      local found_cb = function(chunk)
         if self._think_output_set or self._found_chunks[chunk:get_id()] then
            return false
         end
         self._found_chunks[chunk:get_id()] = true
         self._think_output_set = true

         -- Wait, and then restart the search.  This probably only happens (mostly) when
         -- downstream thinking stalls (probably inside pickup_item, because its looking
         -- for a resource that no longer exists anywhere.)
         if self._failsafe_timer then
            self._failsafe_timer:destroy()
         end
         self._failsafe_timer = radiant.set_realtime_timer('fabricate chunk failsafe', FAILSAFE_TIMEOUT, function()
               self._failsafe_timer = nil
               self._think_output_set = false
               ai:clear_think_output()
               ai:reject('fail safe timeout hit')
            end)

         local output = {
            filter_fn = self._filter_fn,
            owner_player_id = self._work_player_id,
            description = 'fabricate chunks',
            action = self,
            chunk = chunk,
         }
         if ace then
            output.building = chunk:get_component('stonehearth:build2:chunk'):get_owning_building()
         end
         ai:set_think_output(output)

         -- PERF: the first match is the nearest; stop searching instead of re-electing farther chunks
         if self._chunk_if then
            self._chunk_if:destroy()
            self._chunk_if = nil
         end
         return true
      end

      if self._chunk_if then
         self._chunk_if:destroy()
      end
      self._chunk_if = entity:add_component('stonehearth:item_finder'):find_reachable_entity_type(
            self._location,
            self._filter_fn,
            found_cb,
            {
               description = 'Finding chunk',
               owner_player_id = args.owner_player_id,
               exhausted_cb = exhausted_cb,
            })
      if self._think_output_set and self._chunk_if then
         -- the finder matched while it was being created
         self._chunk_if:destroy()
         self._chunk_if = nil
      end
   end
end

return { build_start_item_finder = build_start_item_finder }
