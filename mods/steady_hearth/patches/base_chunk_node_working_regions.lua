-- Building monitor: skip chunk entities that no longer exist (finding RT6).
--
-- BuildingMonitor:_on_building_progress_slow asks the active plan node for its working regions every
-- slow-progress check and re-arms its own timer only at the end. NewChunkNode:get_working_regions
-- calls get_world_region on every chunk and scaffolding chunk entity without checking that it still
-- exists; once one has been destroyed the call raises "entities.lua:21: attempt to index a nil
-- value", the check aborts before re-arming, and the monitor never runs again for that building
-- (no unreachable-work warning for the player). This copy is identical except that it skips
-- entities that are no longer valid.
local Point3 = _radiant.csg.Point3

local function valid(entity)
   return entity and entity:is_valid() and entity:get('destination') ~= nil
end

local function get_working_regions(self)
   local regions = {}
   for id, chunk in pairs(self._chunks) do
      if valid(chunk.chunk_entity) then
         local r = {
            region_w = radiant.entities.get_world_region(chunk.chunk_entity),
            standable_w = radiant.entities.get_world_adjacency_region(chunk.chunk_entity),
            require_all = false,
         }
         table.insert(regions, r)

         for _, scaffolding_chunk in ipairs(chunk.scaffolding_region_chunks) do
            if valid(scaffolding_chunk) then
               local region_w = radiant.entities.get_world_region(scaffolding_chunk)
               local r = {
                  region_w = region_w,
                  standable_w = region_w:peel(Point3(0, 1, 0)),
                  require_all = true,
               }
               table.insert(regions, r)
            end
         end
      end
   end
   return regions
end

return {
   id = 'base_chunk_node_working_regions',
   default_enabled = true,    -- correctness repair: only removes the error path
   target_ace = nil,          -- base code, used with and without ACE
   module = 'stonehearth.components.building2.plan.nodes.new_chunk_node',
   method = 'get_working_regions',
   expect = {
      source_suffix = 'stonehearth/components/building2/plan/nodes/new_chunk_node.lua',
      linedefined = 192,
      lastlinedefined = 215,
   },
   replacement = get_working_regions,
}
