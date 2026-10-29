-- Ghosts release their town placement requests (finding A2b), base game variant. See
-- placement_common.lua.
--
-- GhostFormComponent:_add_to_town requests a placement task for every placeable item type, but
-- _remove_from_town unrequests only inside its _limited_registration_tag block, so the town keeps an
-- entry for every item type ever placed (the census of 2026-10-28: all 64 entries of 4 towns stale,
-- no ghost left). This patch records each request in _add_to_town (a wrapper; the original body runs
-- unchanged) and releases exactly the recorded requests in _remove_from_town (a copy of the original
-- with the release moved out of the limited block). Released entries can disappear under a
-- placement action's cursor, so the two base actions that walk the entries with a plain next() get
-- the restart that ACE's actions already have.
local common = require 'steady_hearth.patches.placement_common'

local function wrap_add_to_town(original)
   return function(self, moving_placed_item)
      -- the original requests exactly when a town exists, the ghost has placement info, it is not
      -- moving a placed item, and it places an item type
      local placement_info = self._sv.placement_info
      local requests = placement_info and not moving_placed_item and self:is_place_item_type()
      local player_id = radiant.entities.get_player_id(self._entity)
      local iconic_uri, quality = placement_info and placement_info.iconic_uri, self._sv.quality
      local result = original(self, moving_placed_item)
      local town = requests and stonehearth.town:get_town(player_id)
      if town then
         common.record(self, { town = town, player_id = player_id, iconic_uri = iconic_uri, quality = quality })
      end
      return result
   end
end

local function remove_from_town(self)
   if self._sv.placement_info then
      local player_id = radiant.entities.get_player_id(self._entity)
      local inventory = stonehearth.inventory:get_inventory(player_id)
      if inventory and self._added_to_town then
         inventory:update_placeable_items_placed(self._root_entity_uri, self._sv.quality, -1)
         self._added_to_town = nil
      end

      if self._sv._limited_registration_tag then
         local town = stonehearth.town:get_town(player_id)
         if town then
            town:unregister_limited_placement_item(self._entity, self._sv._limited_registration_tag)
         end
      end
   end

   -- PERF: release every placement request this ghost made, not only those of limited items
   for _, request in ipairs(common.take(self)) do
      if common.same_town(request) then
         request.town:unrequest_placement_task(request.iconic_uri, request.quality)
      end
   end
end

return {
   id = 'base_placement_requests_release',
   default_enabled = true,    -- correctness repair, validated 2026-10-29: 0 stale placement requests, no errors
   target_ace = false,
   module = 'stonehearth.components.ghost_form.ghost_form_component',
   method = '_add_to_town',
   expect = {
      source_suffix = 'components/ghost_form/ghost_form_component.lua',
      linedefined = 151,
      lastlinedefined = 184,
   },
   wrap = wrap_add_to_town,
   also = {
      {
         method = '_remove_from_town',
         expect = {
            source_suffix = 'components/ghost_form/ghost_form_component.lua',
            linedefined = 128,
            lastlinedefined = 149,
         },
         replacement = remove_from_town,
      },
      {
         script = 'stonehearth:actions:place_item_type_on_structure_2',
         path = { '_base_action' },  -- the script returns a compound action wrapping the class
         method = '_try_next_entry',
         expect = {
            source_suffix = 'ai/actions/place_item_type_on_structure_2.lua',
            linedefined = 84,
            lastlinedefined = 141,
         },
         wrap = common.wrap_try_next_entry,
      },
      {
         script = 'stonehearth:actions:place_summon_stone_type',
         path = { '_base_action' },
         method = '_try_next_entry',
         expect = {
            source_suffix = 'ai/actions/place_summon_stone_type_action.lua',
            linedefined = 67,
            lastlinedefined = 110,
         },
         wrap = common.wrap_try_next_entry,
      },
   },
}
