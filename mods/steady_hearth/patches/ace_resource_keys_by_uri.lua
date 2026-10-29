-- ACE resource tracker: remember the resource materials an item matches per uri
-- (resource_keys_common.lua). Copy of ACE's AceResourceMaterialTracker:create_key_for_entity
-- (stonehearth_ace/monkey_patches/ace_resource_material_tracker.lua) with the material loop replaced,
-- marked PERF.
local common = require 'steady_hearth.patches.resource_keys_common'

local function create_key_for_entity(self, entity, storage)
   assert(entity:is_valid(), 'entity is not valid.')

   local in_reachable_storage
   local on_ground = self:_is_item_on_ground(entity)

   if storage and not storage:get_component('stonehearth_ace:consumer') then
      -- If this item is in a storage that is not a crafter's ingredient storage,
      -- it should become available eventually
      local storage_component = storage:get_component('stonehearth:storage')
      if storage_component and storage_component:get_type() ~= 'crafter_backpack' and storage_component:allow_item_removal() then
         in_reachable_storage = true
      end
   end

   local keys = {}
   if in_reachable_storage or on_ground then
      -- PERF: the materials this item's uri matches, remembered per uri
      keys = common.keys_for(entity)
   end

   return keys
end

return {
   id = 'ace_resource_keys_by_uri',
   default_enabled = true,
   target_ace = true,
   module = 'stonehearth.services.server.inventory.resource_material_tracker',
   method = 'create_key_for_entity',
   expect = { source_suffix = 'monkey_patches/ace_resource_material_tracker.lua', linedefined = 7, lastlinedefined = 32 },
   replacement = create_key_for_entity,
   requires = {
      -- the remembered answer is valid because is_material asks the catalog by uri for an item
      -- without a stonehearth:material component
      { global = { 'radiant', 'entities' }, method = 'is_material',
        expect = { source_suffix = 'radiant/modules/entities.lua', linedefined = 1360, lastlinedefined = 1373 } },
   },
}
