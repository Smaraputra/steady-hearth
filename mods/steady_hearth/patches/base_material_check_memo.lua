-- Base game catalog: remember material checks per pair of material strings (material_memo_common.lua).
local common = require 'steady_hearth.patches.material_memo_common'

return {
   id = 'base_material_check_memo',
   default_enabled = true,    -- exact (shadow checks 0 mismatches); docs/experiments/009-restock-caches-material-memo.md
   target_ace = false,
   module = 'stonehearth.services.server.catalog.catalog_service',
   method = 'is_material',
   expect = { source_suffix = 'services/server/catalog/catalog_service.lua', linedefined = 82, lastlinedefined = 95 },
   wrap = common.memo_wrap('base_material_check_memo'),
   requires = {
      -- the memo relies on Material objects being built once per string and tested by string alone
      { module = 'stonehearth.services.server.catalog.catalog_service', method = 'get_material_object',
        expect = { source_suffix = 'services/server/catalog/catalog_service.lua', linedefined = 97, lastlinedefined = 104 } },
      { module = 'stonehearth.components.material.material', method = 'contains_all_parts',
        expect = { source_suffix = 'components/material/material.lua', linedefined = 85, lastlinedefined = 87 } },
   },
}
