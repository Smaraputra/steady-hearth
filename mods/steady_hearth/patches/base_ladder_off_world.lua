-- build_ladder_adjacent with a citizen that has left the world, base game variant.
-- See ladder_off_world_common.lua.
local common = require 'steady_hearth.patches.ladder_off_world_common'

return {
   id = 'base_ladder_off_world',
   default_enabled = true,    -- correctness repair: removes a script error
   target_ace = false,
   script = 'stonehearth:actions:build_ladder_adjacent',
   method = 'run',
   expect = {
      source_suffix = 'ai/actions/build_ladder_adjacent_action.lua',
      linedefined = 29,
      lastlinedefined = 76,
   },
   wrap = common.wrap,
}
