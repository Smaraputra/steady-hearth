-- One pending teleport per citizen.
--
-- set_teleporting injects the teleport action and keeps the injector in self._injected_ai, without
-- releasing an injector it already holds. Injected actions are reference counted, so a second
-- request leaves the count at 2. set_teleported clears the destination and releases one reference,
-- and the action stays installed with no destination to go to.
--
-- With this patch a request made while another is pending only changes the destination, so the
-- count stays at 1. The action's run returns without acting when there is no destination, which
-- covers a run that starts before the removal of the action has reached the AI.
local function wrap_set_teleporting(original)
   return function(self, location)
      if self._injected_ai then
         self._location = location
         return
      end
      return original(self, location)
   end
end

local function wrap_run(original)
   return function(self, ai, entity, args)
      if not entity:get('stonehearth:teleportation'):get_destination() then
         return
      end
      return original(self, ai, entity, args)
   end
end

return {
   id = 'teleport_single_request',
   default_enabled = true,    -- correctness repair: removes a script error
   target_ace = nil,          -- ACE does not replace either method
   module = 'stonehearth.components.teleportation.teleportation_component',
   method = 'set_teleporting',
   expect = {
      source_suffix = 'components/teleportation/teleportation_component.lua',
      linedefined = 74,
      lastlinedefined = 85,
   },
   wrap = wrap_set_teleporting,
   also = {
      {
         script = 'stonehearth:actions:compelled_behaviors:teleporting',
         method = 'run',
         expect = {
            source_suffix = 'ai/actions/compelled_behaviors/teleport_action.lua',
            linedefined = 17,
            lastlinedefined = 45,
         },
         wrap = wrap_run,
      },
   },
}
