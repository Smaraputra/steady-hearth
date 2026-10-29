-- radiant.entities.trace_grid_location without the per-fire table (finding R3).
--
-- The shipped function wraps the mob's transform trace in a FilteredTrace whose on_changed
-- closure runs on every transform change of a moving entity (sub-voxel steps every tick), builds
-- a table from the filter's results ({ filter_fn(...) }) and unpacks it, only to report a new grid
-- location a few times per second. The window profile of 2026-10-28 put that closure at 11.7% of
-- Lua samples inclusive, 2.7% self plus 1.3% in the filter (docs/atlas/profiles-2026-10-28.md).
--
-- This copy keeps the same semantics in one closure without the table: the filter only runs while
-- a changed callback is set, last_location is updated the same way (also to nil when the entity is
-- off the world), and the callback gets the new location only when it is not nil. The returned
-- object has the methods FilteredTrace has (on_changed, on_destroyed, push_object_state, destroy).

local GridLocationTrace = {}
GridLocationTrace.__index = GridLocationTrace

function GridLocationTrace:on_changed(changed_cb)
   self._changed_cb = changed_cb
   return self
end

function GridLocationTrace:on_destroyed(destroyed_cb)
   self._trace_impl:on_destroyed(destroyed_cb)
   return self
end

function GridLocationTrace:push_object_state()
   self._trace_impl:push_object_state()
   return self
end

function GridLocationTrace:destroy()
   if self._trace_impl then
      self._trace_impl:destroy()
      self._trace_impl = nil
   end
end

local function trace_grid_location(entity, reason)
   local mob = entity:add_component('mob')
   local last_location = mob:get_world_grid_location()
   local trace = setmetatable({}, GridLocationTrace)
   trace._trace_impl = mob:trace_transform(reason)
   trace._trace_impl:on_changed(function()
         local changed_cb = trace._changed_cb
         if changed_cb then
            local current_location = mob:get_world_grid_location()
            if current_location == last_location then
               return
            end
            last_location = current_location
            if current_location then
               changed_cb(current_location)
            end
         end
      end)
   return trace
end

return {
   id = 'grid_location_trace',
   default_enabled = false,   -- behaviour-preserving optimization: timing A/B first
   target_ace = nil,          -- radiant code, used with and without ACE
   global = { 'radiant', 'entities' },
   method = 'trace_grid_location',
   expect = {
      source_suffix = 'radiant/modules/entities.lua',
      linedefined = 1315,
      lastlinedefined = 1332,
   },
   replacement = trace_grid_location,
}
