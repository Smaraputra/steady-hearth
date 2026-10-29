-- Ghosts release their town placement requests (finding A2b) and the release finds its entry
-- (finding E1), ACE variant. See placement_common.lua.
--
-- ACE's version keeps the base game's _remove_from_town structure (requests are released only for
-- items with a placement limit) and splits requests into build fixtures and other items, each stored
-- by AceTown:_request_placement_task under tasks[placement tag][key]. AceTown:_unrequest_placement_task
-- looks the entry up as tasks[key], so a release does not reach the entry it was meant for (E1). This patch records each request in _add_to_town (a wrapper; the original body runs
-- unchanged), releases exactly the recorded requests in _remove_from_town (a copy of ACE's with the
-- release moved out of the limited block), and looks the entry up under the placement tag that
-- _request_placement_task used. ACE's own placement actions already restart when the entry under
-- their cursor is gone (prev_key); its summon stone action, a copy of the base game's, gets the same
-- restart as in the base variant.
local common = require 'steady_hearth.patches.placement_common'

local NO_PLACEMENT_TAG = '__NO_PLACEMENT_TAG__'   -- as in ACE's ace_town.lua

local function wrap_add_to_town(original)
   return function(self, moving_placed_item)
      -- ACE's original requests exactly when a town exists, the ghost has placement info, it is not
      -- moving a placed item, and it places an item type; fixtures of a building go to the build list
      local placement_info = self._sv.placement_info
      local requests = placement_info and not moving_placed_item and self:is_place_item_type()
      local request = requests and {
         player_id = radiant.entities.get_player_id(self._entity),
         iconic_uri = placement_info.iconic_uri,
         quality = self._sv.quality,
         build = self:is_building_fixture(),
         placement_tag = self:_get_placement_tag(),
      }
      local result = original(self, moving_placed_item)
      local town = request and stonehearth.town:get_town(request.player_id)
      if town then
         request.town = town
         common.record(self, request)
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
         if request.build then
            request.town:unrequest_build_placement_task(request.iconic_uri, request.quality, false, request.placement_tag)
         else
            request.town:unrequest_placement_task(request.iconic_uri, request.quality, false, request.placement_tag)
         end
      end
   end
end

local function unrequest_placement_task(self, tasks, iconic_uri, quality, require_exact)
   local quality_str = quality and tostring(quality) or 'any'
   local require_exact_str = require_exact and '_exact' or ''
   local key = iconic_uri .. stonehearth.constants.item_quality.KEY_SEPARATOR .. quality_str .. require_exact_str
   -- PERF: _request_placement_task stores the entry under the root form's placement tag
   local catalog_data = stonehearth.catalog:get_catalog_data(iconic_uri)
   local root_form = catalog_data and catalog_data.root_entity_uri
   local placement_data = root_form and radiant.entities.get_entity_data(root_form, 'stonehearth:placement')
   local key_tasks = tasks[placement_data and placement_data.tag or NO_PLACEMENT_TAG]
   local task = key_tasks and key_tasks[key]
   if not task then
      return
   end

   task.count = task.count - 1
   if task.count <= 0 then
      key_tasks[key] = nil
   end
end

return {
   id = 'ace_placement_requests_release',
   default_enabled = true,    -- correctness repair, validated 2026-10-29: 0 stale placement requests, no errors
   target_ace = true,
   module = 'stonehearth.components.ghost_form.ghost_form_component',
   method = '_add_to_town',
   expect = {
      source_suffix = 'monkey_patches/ace_ghost_form_component.lua',
      linedefined = 53,
      lastlinedefined = 91,
   },
   wrap = wrap_add_to_town,
   also = {
      {
         method = '_remove_from_town',
         expect = {
            source_suffix = 'monkey_patches/ace_ghost_form_component.lua',
            linedefined = 25,
            lastlinedefined = 51,
         },
         replacement = remove_from_town,
      },
      {
         module = 'stonehearth.services.server.town.town',
         method = '_unrequest_placement_task',
         expect = {
            source_suffix = 'monkey_patches/ace_town.lua',
            linedefined = 1132,
            lastlinedefined = 1145,
         },
         replacement = unrequest_placement_task,
      },
      {
         script = 'stonehearth:actions:place_summon_stone_type',
         path = { '_base_action' },  -- the script returns a compound action wrapping the class
         method = '_try_next_entry',
         expect = {
            source_suffix = 'ai/actions/place_summon_stone_type_action.lua',
            linedefined = 67,
            lastlinedefined = 113,
         },
         wrap = common.wrap_try_next_entry,
      },
   },
   requires = {
      -- called by the wrapper and the copied _remove_from_town
      {
         module = 'stonehearth.components.ghost_form.ghost_form_component',
         method = '_get_placement_tag',
         expect = { source_suffix = 'monkey_patches/ace_ghost_form_component.lua', linedefined = 93, lastlinedefined = 96 },
      },
      {
         module = 'stonehearth.components.ghost_form.ghost_form_component',
         method = 'is_building_fixture',
         expect = { source_suffix = 'monkey_patches/ace_ghost_form_component.lua', linedefined = 20, lastlinedefined = 22 },
      },
      -- the request side whose storage layout the fixed lookup mirrors
      {
         module = 'stonehearth.services.server.town.town',
         method = '_request_placement_task',
         expect = { source_suffix = 'monkey_patches/ace_town.lua', linedefined = 1098, lastlinedefined = 1130 },
      },
   },
}
