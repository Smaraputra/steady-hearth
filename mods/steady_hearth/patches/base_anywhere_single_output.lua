-- find_reachable_entity_type_anywhere: one think output, then stop both searches (finding RT2),
-- base game variant. See anywhere_common.lua.
local common = require 'steady_hearth.patches.anywhere_common'

return {
   id = 'base_anywhere_single_output',
   default_enabled = true,    -- correctness repair: removes duplicate think outputs and idle searching
   target_ace = false,
   script = 'stonehearth:actions:find_reachable_entity_type_anywhere',
   method = 'start_thinking',
   expect = {
      source_suffix = 'ai/actions/find_reachable_entity_type_anywhere.lua',
      linedefined = 93,
      lastlinedefined = 223,
   },
   replacement = common.build_start_thinking(false),
}
