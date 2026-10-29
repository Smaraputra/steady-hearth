-- ACE building plans: clone the plan's nav grid with explicitly empty bounds (finding E9).
--
-- ACE's BlueprintsToBuildingPiecesJob:clone_nav_grid wants a blank nav grid for each building plan
-- ("don't use the bounds or entities for cloning; just make it blank") and calls
-- _radiant.sim.clone_nav_grid(Cube3(), ...). Cube3() is not initialized: the census of 2026-10-28
-- logged fresh cubes holding whatever the reused memory held (huge numbers, NaN, coordinates of
-- earlier cubes), and clone_nav_grid received such bounds. The clone walks the nav-grid tiles
-- inside the bounds it gets. Usually the garbage is empty or tiny, and the clone is blank or copies
-- a tile or two of the world; when it is huge, the walk covers an enormous range inside one job step
-- that never yields. That was the 17-minute step of 2026-10-28 02:08 and the step that never
-- returned at 17:36, about one ACE run in ten, with or without the plan clip. This copy of ACE's function passes Cube3(Point3.zero,
-- Point3.zero): no tile is visited, so the clone is always blank, as ACE intends. Everything else is
-- ACE's code line for line. ace_plan_navgrid_clip, a copy of the same function, carries the same
-- fix and supersedes this patch when it is enabled.
local Cube3 = _radiant.csg.Cube3
local Point3 = _radiant.csg.Point3
local Region3 = _radiant.csg.Region3

local log = radiant.log.create_logger('build.blueprints_to_building_pieces_job')

local function clone_nav_grid(self)
   local nav_grid_bounds = Cube3(self._sv._building_bounds)
   nav_grid_bounds:grow(Point3(nav_grid_bounds.min.x, -1000, nav_grid_bounds.min.z))
   nav_grid_bounds:grow(Point3(nav_grid_bounds.max.x, 1000, nav_grid_bounds.max.z))

   -- Inflate this a little to account for scaffolding that is on the sides.
   self._sv._nav_grid_bounds = nav_grid_bounds:inflated(Point3(1, 1, 1))

   -- don't use the bounds or entities for cloning; just make it blank,
   -- then copy the terrain region minus what we want to mine out
   -- and put it into the rcs of a proxy entity that we place on that root entity
   -- self._sv._nav_grid_id = _radiant.sim.clone_nav_grid(self._sv._nav_grid_bounds, radiant.entities.get_player_id(self._sv._building), self._sv._ignored_entities)
   -- PERF: an explicitly empty cube; Cube3() is not initialized (see the header)
   self._sv._nav_grid_id = _radiant.sim.clone_nav_grid(Cube3(Point3.zero, Point3.zero), radiant.entities.get_player_id(self._sv._building), {})
   local new_root = _radiant.sim.get_entity(_radiant.sim.get_nav_grid_root(self._sv._nav_grid_id))

   log:info('cloned new nav_grid with id %s', self._sv._nav_grid_id)

   -- Now, collect up all the like-colored regions in this new nav-grid, and then
   -- store them (after removing the building's contribution)
   _radiant.sim.topology.set_manual_mode(self._sv._nav_grid_id, true)

   -- ACE: copy the terrain region within the bounds
   local terrain_region = radiant.terrain.intersect_cube(self._sv._nav_grid_bounds)
   local proxy = radiant.entities.create_entity('stonehearth_ace:object:navgrid_proxy')
   local rcs = proxy:add_component('region_collision_shape')
   rcs:set_region(_radiant.sim.alloc_region3())
   rcs:get_region():modify(function(cursor)
         cursor:copy_region(terrain_region - self._sv._terrain_cutout)

         -- also copy the finished collision regions of existing buildings
         for _, b in stonehearth.building:get_buildings():each() do
            local bc = b:get('stonehearth:build2:building')
            if bc:completed() then
               local r = bc:get_total_building_region()
               if r then
                  cursor:add_region(r)
               else
                  log:error('building %s has no total building region!', radiant.entities.get_custom_name(b))
               end
               cursor:add_region(bc:get_total_building_region())
            end
         end
      end)
   radiant.terrain.place_entity_at_exact_location(proxy, Point3.zero, { root_entity = new_root })
   self._sv._navgrid_proxy = proxy

   _radiant.sim.topology.force_reflow(self._sv._nav_grid_bounds, self._sv._nav_grid_id)

   local waiting_for_adjacency = true
   _radiant.sim.adjacency.on_adjacency_complete(function()
         waiting_for_adjacency = false
      end, self._sv._nav_grid_id)
   while waiting_for_adjacency do
      self:yield()
   end


   -- ACE: save the raw regions for later, but also subtract out for a copy
   self._sv._color_regions = _radiant.sim.topology.to_regions(self._sv._nav_grid_bounds, self._sv._nav_grid_id)
   self._sv._outside_color_regions = {}
   for c, r in pairs(self._sv._color_regions) do
      local r2 = Region3(r)
      r2:subtract_cube(self._sv._building_bounds)
      self._sv._outside_color_regions[c] = r2
   end

   self:incstage()
end

return {
   id = 'ace_plan_clone_empty_bounds',
   default_enabled = true,    -- correctness repair: validated 2026-10-28 (every clone blank, 0-1 ms, no errors)
   target_ace = true,
   superseded_by = 'ace_plan_navgrid_clip',
   module = 'stonehearth.components.building2.plan.jobs.blueprints_to_building_pieces_job',
   method = 'clone_nav_grid',
   expect = {
      source_suffix = 'monkey_patches/ace_blueprints_to_building_pieces_job.lua',
      linedefined = 348,
      lastlinedefined = 415,
   },
   replacement = clone_nav_grid,
}
