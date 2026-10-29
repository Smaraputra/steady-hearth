-- Material checks: remember CatalogService:is_material by the two material descriptions it compares.
--
-- is_material(uri, desired_materials) looks up the item's catalog entry and returns whether its
-- materials (the entity's material_tags array, kept by the catalog) contain every tag of
-- desired_materials (a string such as 'wood resource'), by turning both into Material objects (cached
-- per string or per array, by identity) and testing one against the other. Item finders and pickup filters call it for
-- every candidate item, so the two get_material_object calls and the subset test are paid again and
-- again for the same pairs of strings (the 2026-10-29 xl-v4 profiles: is_material, get_material_object
-- and Material:contains_all_parts together about 2.6% of vanilla and 4.9% of ACE Lua samples). Material
-- objects never change after they are built and their test reads only the two descriptions, so the
-- answer depends on (the item's materials, the desired string) alone. The item's materials are keyed
-- by identity, exactly as get_material_object keys its own cache, so the memo assumes no more than the
-- original does (that a catalog entry's material_tags array is not changed in place). The wrap keeps the
-- catalog lookup and the original's two early `return false` exits, and remembers the original's
-- answer per pair; a desired value that is not a string goes straight to the original, so callers
-- cannot grow the memo with throwaway tables. The original answers true or nil, and the memo returns
-- exactly that. (A first version keyed only strings and so never matched the catalog's arrays.)
--
-- With mods.steady_hearth.shadow_checks=true (diagnostic runs only) remembered answers are also
-- recomputed with the original and any difference is logged, plus a running total every 500 checks.
-- mods.steady_hearth.shadow_every=N checks one remembered answer in N (default every one), so a
-- profiling run can carry the check without the extra work showing up in its profile.

local log = function(fmt, ...)
   radiant.log.write_('steady_hearth', 0, fmt, ...)
end

local shadow = _host:get_config('mods.steady_hearth.shadow_checks')
shadow = shadow == true or shadow == 'true'
local SHADOW_EVERY = math.max(1, tonumber(_host:get_config('mods.steady_hearth.shadow_every')) or 1)

local NO = {}   -- remembered nil answer

local common = {}

function common.memo_wrap(id)
   local memo = {}   -- desired material string -> { item materials (string or catalog array) -> answer or NO }
   local shadow_hits, shadow_calls, shadow_mismatches = 0, 0, 0
   return function(original)
      -- Plain indexing throughout: the catalog, its entries and the memo are tables without metatables,
      -- where t[k] equals rawget(t, k), and in the game's PUC Lua 5.1 rawget is a C function call (about
      -- three times the cost of an index in a Lua 5.1 loop), so a memo built on rawget cost as much as
      -- the work it saved (xl-v4 profiles, 2026-10-29).
      return function(self, uri, desired_materials)
         local catalog_data = self._catalog[uri]
         if not catalog_data then
            return false
         end
         local materials = catalog_data.materials
         if not materials then
            return false
         end
         local row = memo[desired_materials]
         local remembered = row and row[materials]
         if remembered == nil then
            if type(desired_materials) ~= 'string' then
               return original(self, uri, desired_materials)
            end
            local answer = original(self, uri, desired_materials)
            if not row then
               row = {}
               memo[desired_materials] = row
            end
            if answer == nil then
               row[materials] = NO
            else
               row[materials] = answer
            end
            return answer
         end
         local answer = remembered
         if remembered == NO then
            answer = nil
         end
         if shadow then
            shadow_hits = shadow_hits + 1
            if shadow_hits % SHADOW_EVERY == 0 then
               local expected = original(self, uri, desired_materials)
               shadow_calls = shadow_calls + 1
               if expected ~= answer then
                  shadow_mismatches = shadow_mismatches + 1
                  log('shadow %s: MISMATCH for %s / %s: original %s, remembered %s', id, tostring(uri),
                      tostring(desired_materials), tostring(expected), tostring(answer))
               end
               if shadow_calls % 500 == 0 then
                  log('shadow %s: %d calls, %d mismatches', id, shadow_calls, shadow_mismatches)
               end
            end
         end
         return answer
      end
   end
end

return common
