-- Base game restock director: trust a checked errand longer than 20 ms, re-checking all but reachability
-- (restock_caches_common.lua).
local common = require 'steady_hearth.patches.restock_caches_common'

return {
   id = 'base_restock_validity_window',
   default_enabled = false,   -- off: runs of 2026-10-29 with it on did less town work (restock, construction), and the one ACE run with it and the material memo logged engine callback errors (docs/experiments/009-restock-caches-material-memo.md)
   target_ace = false,
   module = 'stonehearth.services.server.inventory.restock_director',
   method = '_is_errand_valid',
   expect = { source_suffix = 'services/server/inventory/restock_director.lua', linedefined = 614, lastlinedefined = 634 },
   replacement = common.is_errand_valid,
   requires = {
      -- the copy calls this as the original does
      { module = 'stonehearth.services.server.inventory.restock_director', method = '_are_reachable',
        expect = { source_suffix = 'services/server/inventory/restock_director.lua', linedefined = 824, lastlinedefined = 845 } },
   },
}
