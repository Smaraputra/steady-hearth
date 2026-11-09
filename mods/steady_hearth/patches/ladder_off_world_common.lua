-- Shared wrap for the build_ladder_adjacent action, in a base and an ACE variant (ACE replaces run).
--
-- The action reads the citizen's world location and indexes it straight away. A town can take a
-- citizen off the world at any moment (a player disconnects, or the citizen leaves on a dispatch
-- quest), and the be_away_from_town action that takes over reaches the running AI frames only on
-- the next game loop. In that gap the compound action can step into this action with no location.
-- The wrap aborts instead, as the game's other actions do when an entity has left the world; the AI
-- then waits until the citizen is back in the world.
local function wrap(original)
   return function(self, ai, entity, args)
      if not radiant.entities.get_world_grid_location(entity) then
         ai:abort('not in the world')
         return
      end
      return original(self, ai, entity, args)
   end
end

return { wrap = wrap }
