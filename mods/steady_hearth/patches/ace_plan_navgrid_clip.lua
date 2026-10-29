-- ACE building plans: only add finished buildings near the plan to the plan's nav grid.
--
-- ACE's BlueprintsToBuildingPiecesJob:clone_nav_grid builds a private nav grid for each building
-- plan from the terrain inside the plan bounds plus the full region of every completed building in
-- the world, for every player. The terrain outside the bounds is never copied, so building regions
-- there float in empty space and cannot change the topology the plan queries inside the bounds,
-- but the engine still has to process their collision for the whole map. That native work runs
-- inside one job step that never yields, and stalled the XL benchmark for up to 25 s per step
-- (docs/atlas/findings.md, RT3). This copy keeps ACE's function line for line, except that it adds
-- the full region of a finished building only when that region comes within NEARBY_MARGIN voxels
-- of the plan bounds (horizontally), and adds it once instead of twice. Nearby buildings keep their
-- whole geometry, so any detour over a neighbouring roof or bridge that ACE's planner could find is
-- preserved; distant buildings cannot be reached from the plan area because no terrain outside the
-- bounds is copied. Log lines go to the steady_hearth.build.* category instead of ACE's.
-- It also passes explicitly empty bounds to clone_nav_grid instead of Cube3(), which is not
-- initialized (finding E9, see ace_plan_clone_empty_bounds.lua).
local Cube3 = _radiant.csg.Cube3
local Point3 = _radiant.csg.Point3
local Region3 = _radiant.csg.Region3

local log = radiant.log.create_logger('build.blueprints_to_building_pieces_job')

local NEARBY_MARGIN = tonumber(_host:get_config('mods.steady_hearth.ace_plan_nearby_margin')) or 16

local function clone_nav_grid(self)
   local nav_grid_bounds = Cube3(self._sv._building_bounds)
   nav_grid_bounds:grow(Point3(nav_grid_bounds.min.x, -1000, nav_grid_bounds.min.z))
   nav_grid_bounds:grow(Point3(nav_grid_bounds.max.x, 1000, nav_grid_bounds.max.z))

   -- Inflate this a little to account for scaffolding that is on the sides.
   self._sv._nav_grid_bounds = nav_grid_bounds:inflated(Point3(1, 1, 1))
   local bounds = self._sv._nav_grid_bounds
   local nearby = bounds:inflated(Point3(NEARBY_MARGIN, 0, NEARBY_MARGIN))

   -- PERF: an explicitly empty cube; Cube3() is not initialized (finding E9)
   self._sv._nav_grid_id = _radiant.sim.clone_nav_grid(Cube3(Point3.zero, Point3.zero), radiant.entities.get_player_id(self._sv._building), {})
   local new_root = _radiant.sim.get_entity(_radiant.sim.get_nav_grid_root(self._sv._nav_grid_id))

   log:info('cloned new nav_grid with id %s', self._sv._nav_grid_id)

   _radiant.sim.topology.set_manual_mode(self._sv._nav_grid_id, true)

   local terrain_region = radiant.terrain.intersect_cube(bounds)
   local proxy = radiant.entities.create_entity('stonehearth_ace:object:navgrid_proxy')
   local rcs = proxy:add_component('region_collision_shape')
   rcs:set_region(_radiant.sim.alloc_region3())
   rcs:get_region():modify(function(cursor)
         cursor:copy_region(terrain_region - self._sv._terrain_cutout)

         -- PERF: only finished buildings near the plan can be reached from it
         for _, b in stonehearth.building:get_buildings():each() do
            local bc = b:get('stonehearth:build2:building')
            if bc:completed() then
               local r = bc:get_total_building_region()
               if r then
                  if r:intersects_cube(nearby) then
                     cursor:add_region(r)
                  end
               else
                  log:error('building %s has no total building region!', radiant.entities.get_custom_name(b))
               end
            end
         end
      end)
   radiant.terrain.place_entity_at_exact_location(proxy, Point3.zero, { root_entity = new_root })
   self._sv._navgrid_proxy = proxy

   _radiant.sim.topology.force_reflow(bounds, self._sv._nav_grid_id)

   local waiting_for_adjacency = true
   _radiant.sim.adjacency.on_adjacency_complete(function()
         waiting_for_adjacency = false
      end, self._sv._nav_grid_id)
   while waiting_for_adjacency do
      self:yield()
   end

   self._sv._color_regions = _radiant.sim.topology.to_regions(bounds, self._sv._nav_grid_id)
   self._sv._outside_color_regions = {}
   for c, r in pairs(self._sv._color_regions) do
      local r2 = Region3(r)
      r2:subtract_cube(self._sv._building_bounds)
      self._sv._outside_color_regions[c] = r2
   end

   self:incstage()
end

return {
   id = 'ace_plan_navgrid_clip',
   default_enabled = true,    -- decision 2026-10-29: plans identical, early-game freezes about 13 min to seconds
   target_ace = true,
   module = 'stonehearth.components.building2.plan.jobs.blueprints_to_building_pieces_job',
   method = 'clone_nav_grid',
   expect = {
      source_suffix = 'monkey_patches/ace_blueprints_to_building_pieces_job.lua',
      linedefined = 348,
      lastlinedefined = 415,
   },
   replacement = clone_nav_grid,
}
