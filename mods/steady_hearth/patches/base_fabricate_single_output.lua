-- fabricate_chunk: one think output and one failsafe timer per thinking cycle (findings RT1, B1),
-- base game variant. See fabricate_common.lua.
local common = require 'steady_hearth.patches.fabricate_common'

return {
   id = 'base_fabricate_single_output',
   default_enabled = true,    -- correctness repair: removes the engine CHECK and orphaned timers
   target_ace = false,
   script = 'stonehearth:actions:fabricate_chunk',
   path = { '_base_action' },  -- the script returns a compound action wrapping the class
   method = '_start_item_finder',
   expect = {
      source_suffix = 'ai/actions/fabrication/fabricate_chunk_action.lua',
      linedefined = 37,
      lastlinedefined = 97,
   },
   replacement = common.build_start_item_finder(false),
}
