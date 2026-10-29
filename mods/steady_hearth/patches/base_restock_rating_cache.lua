-- Base game restock director: use the item rating cache the director keeps but never reads
-- (restock_caches_common.lua).
local common = require 'steady_hearth.patches.restock_caches_common'

return {
   id = 'base_restock_rating_cache',
   default_enabled = false,   -- off: changes restock priorities (ratings up to 60 s old); its effect on town work could not be separated from the validity window in the runs of 2026-10-29 (docs/experiments/009-restock-caches-material-memo.md)
   target_ace = false,
   module = 'stonehearth.services.server.inventory.restock_director',
   method = '_rate_item',
   expect = { source_suffix = 'services/server/inventory/restock_director.lua', linedefined = 653, lastlinedefined = 706 },
   wrap = common.rating_cache_wrap,
}
