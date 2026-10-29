-- AiService:_add_reconsidered_entity also clears the reconsidered entity from the result caches of
-- running ACE nearby item searches (finding R7b; part of experiment 004, used by
-- ace_nearby_search_extra_predicate).
--
-- Without the patch, AiService:fast_call_filter_fn keeps a native FilterResultCache for every filter function
-- it is given in FAST_CALL_CACHES, a strong table (base ai_service.lua:35, 569-583), and
-- _add_reconsidered_entity clears the reconsidered entity from every one of them, synchronously
-- (:496-501), on every reconsider. ACE's restock searches add one such cache per errand (a new
-- closure each time), so every reconsider gets slower as the session goes on. With this wrapper
-- installed, the NearbyItemSearch patch gives each search its own result cache, dropped when the
-- search ends, and this clears the reconsidered entity from the caches of the searches still
-- running, as the shipped loop does, before running the original. With no search running it only
-- checks an empty table.

local nearby = require 'steady_hearth.patches.ace_nearby_search_extra_predicate'
local AiService = radiant.mods.require('stonehearth.services.server.ai.ai_service')

local original = AiService._add_reconsidered_entity
local active = nearby.hooks.active_result_caches

local function add_reconsidered_entity(self, entity, reason)
   if next(active) then
      local id = entity:get_id()
      for filter_rc in pairs(active) do
         filter_rc:clear_cache_entry(id)
      end
   end
   return original(self, entity, reason)
end

-- the NearbyItemSearch patch uses its own result caches only while this is the installed method
nearby.hooks.reconsider = add_reconsidered_entity

return {
   id = 'ace_reconsider_clears_search_caches',
   default_enabled = true,    -- decision 2026-10-29 after the mechanism check (experiment 004), the three R7 patches together
   target_ace = true,
   module = 'stonehearth.services.server.ai.ai_service',
   method = '_add_reconsidered_entity',
   expect = {
      source_suffix = 'stonehearth/services/server/ai/ai_service.lua',
      linedefined = 493,
      lastlinedefined = 512,
   },
   replacement = add_reconsidered_entity,
}
