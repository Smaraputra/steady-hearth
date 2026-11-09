-- build_ladder_adjacent with a citizen that has left the world, ACE variant.
-- See ladder_off_world_common.lua.
local common = require 'steady_hearth.patches.ladder_off_world_common'

return {
   id = 'ace_ladder_off_world',
   default_enabled = true,    -- correctness repair: removes a script error
   target_ace = true,
   script = 'stonehearth:actions:build_ladder_adjacent',
   method = 'run',
   expect = {
      source_suffix = 'monkey_patches/ace_build_ladder_adjacent_action.lua',
      linedefined = 3,
      lastlinedefined = 46,
   },
   wrap = common.wrap,
}
