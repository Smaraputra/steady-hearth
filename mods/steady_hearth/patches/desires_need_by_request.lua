-- Town desires: compute an item's needed count from the materials that are actually requested.
--
-- DesiresTracker:get_needed_item_or_resource_count (base game, also used with ACE) rates an item by
-- the larger of its own needed count and the needed count of every material subset of the item's
-- materials. Material subsets come from a power set of the material tags, so an item with several
-- tags has dozens of subsets, and get_needed_material_count returns 0 for every subset nobody has
-- requested. Harvest actions call this for every candidate tree, bush and plant they consider; the
-- ACE window profile of 2026-10-29 puts 7.2% of all Lua samples in get_needed_material_count alone
-- (about 10% with its caller). This copy visits only the requested materials that are subsets of the
-- item's materials, which gives the same maximum, because unrequested materials contribute 0 and the
-- count starts at the item's own needed count (never negative).
--
-- With mods.steady_hearth.shadow_checks=true (diagnostic runs only) every call also runs the original
-- loop and logs any difference, plus a running total every 20,000 calls.

local log = function(fmt, ...)
   radiant.log.write_('steady_hearth', 0, fmt, ...)
end

local shadow = _host:get_config('mods.steady_hearth.shadow_checks')
shadow = shadow == true or shadow == 'true'
local shadow_calls, shadow_mismatches = 0, 0

local function original_count(self, item_uri)
   local count = self:get_needed_item_count(item_uri)

   local catalog = stonehearth.catalog:get_catalog_data(item_uri)
   if catalog and catalog.materials then
      local material = stonehearth.catalog:get_material_object(catalog.materials)
      for material_id, _ in pairs(material.material_subsets) do
         local material_count = self:get_needed_material_count(material_id)
         if material_count > count then
            count = material_count
         end
      end
   end

   return count
end

local function get_needed_item_or_resource_count(self, item_uri)
   local count = self:get_needed_item_count(item_uri)

   local catalog = stonehearth.catalog:get_catalog_data(item_uri)
   if catalog and catalog.materials then
      local material = stonehearth.catalog:get_material_object(catalog.materials)
      -- PERF: only requested materials can have a needed count above 0, so visit those that are
      -- subsets of the item's materials instead of every subset
      local subsets = material.material_subsets
      for material_id, _ in pairs(self._material_desires) do
         if subsets[material_id] ~= nil then
            local material_count = self:get_needed_material_count(material_id)
            if material_count > count then
               count = material_count
            end
         end
      end
   end

   if shadow then
      local expected = original_count(self, item_uri)
      shadow_calls = shadow_calls + 1
      if expected ~= count then
         shadow_mismatches = shadow_mismatches + 1
         log('shadow desires_need_by_request: MISMATCH for %s: original %s, patched %s', tostring(item_uri), tostring(expected), tostring(count))
      end
      if shadow_calls % 20000 == 0 then
         log('shadow desires_need_by_request: %d calls, %d mismatches', shadow_calls, shadow_mismatches)
      end
   end

   return count
end

local SOURCE = 'services/server/inventory/desires_tracker.lua'

return {
   id = 'desires_need_by_request',
   default_enabled = true,    -- validated 2026-10-29: shadow check 0 mismatches, desires share of Lua samples 10.1% to 0.3%
   module = 'stonehearth.services.server.inventory.desires_tracker',
   method = 'get_needed_item_or_resource_count',
   expect = { source_suffix = SOURCE, linedefined = 124, lastlinedefined = 139 },
   replacement = get_needed_item_or_resource_count,
   requires = {
      -- reads _material_desires as keyed by request_material, and calls these as the original does
      { module = 'stonehearth.services.server.inventory.desires_tracker', method = 'request_material',
        expect = { source_suffix = SOURCE, linedefined = 49, lastlinedefined = 60 } },
      { module = 'stonehearth.services.server.inventory.desires_tracker', method = 'get_needed_material_count',
        expect = { source_suffix = SOURCE, linedefined = 107, lastlinedefined = 122 } },
   },
}
