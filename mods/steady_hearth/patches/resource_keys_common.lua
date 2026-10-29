-- Inventory trackers: remember per uri which resource materials an item matches.
--
-- ResourceMaterialTracker:create_key_for_entity (base game, and ACE's copy) runs for every item on the
-- ground or in reachable storage whenever the item is added to the resource tracker: for every such
-- item when a save loads, and whenever an item is placed, stored or moved. It calls
-- radiant.entities.is_material once per material in stonehearth.constants.resources (24 in the base
-- game, 105 with ACE), and each call checks the entity, looks for a stonehearth:material component and
-- asks the catalog by the item's uri. The ACE save-load profile of 2026-10-29 put 46.5% of the Lua work
-- between required_loaded and the first game loop in this function (docs/atlas/load-save-ui.md).
--
-- For an item without a stonehearth:material component, is_material answers from the catalog by uri
-- alone, and neither the catalog nor the resource constants change after loading, so every item with
-- that uri matches the same materials. keys_for runs the original loop once per uri and returns a new
-- list each time (the tracker saves the list per item in _ids_to_keys), in the order the original loop
-- produces. Items with a stonehearth:material component always take the original loop.
--
-- With mods.steady_hearth.shadow_checks=true (diagnostic runs only) remembered answers are also
-- recomputed with the original loop and any difference is logged, plus a running total every 2,000
-- checks. mods.steady_hearth.shadow_every=N checks one remembered answer in N (default every one).

local log = function(fmt, ...)
   radiant.log.write_('steady_hearth', 0, fmt, ...)
end

local shadow = _host:get_config('mods.steady_hearth.shadow_checks')
shadow = shadow == true or shadow == 'true'
local SHADOW_EVERY = math.max(1, tonumber(_host:get_config('mods.steady_hearth.shadow_every')) or 1)
local shadow_seen, shadow_calls, shadow_mismatches = 0, 0, 0

local KEYS_BY_URI = {}

local common = {}

-- the original loop
local function matching_materials(entity)
   local keys = {}
   for material, _ in pairs(stonehearth.constants.resources) do
      if radiant.entities.is_material(entity, material) then
         table.insert(keys, material)
      end
   end
   return keys
end

local function same_list(a, b)
   if #a ~= #b then
      return false
   end
   for i = 1, #a do
      if a[i] ~= b[i] then
         return false
      end
   end
   return true
end

function common.keys_for(entity)
   if entity:get_component('stonehearth:material') then
      return matching_materials(entity)
   end

   local uri = entity:get_uri()
   local remembered = KEYS_BY_URI[uri]
   if not remembered then
      remembered = matching_materials(entity)
      KEYS_BY_URI[uri] = remembered
   end
   local keys = {}
   for i = 1, #remembered do
      keys[i] = remembered[i]
   end

   if shadow then
      shadow_seen = shadow_seen + 1
      if shadow_seen % SHADOW_EVERY == 0 then
         shadow_calls = shadow_calls + 1
         if not same_list(keys, matching_materials(entity)) then
            shadow_mismatches = shadow_mismatches + 1
            log('shadow resource_keys_by_uri: MISMATCH for %s', tostring(uri))
         end
         if shadow_calls % 2000 == 0 then
            log('shadow resource_keys_by_uri: %d checks, %d mismatches', shadow_calls, shadow_mismatches)
         end
      end
   end

   return keys
end

return common
