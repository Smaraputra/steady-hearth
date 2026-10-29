-- ACE catalog: remember material checks per pair of material strings (material_memo_common.lua). ACE's
-- is_material is the same code as the base game's in its own copy of the catalog service.
local common = require 'steady_hearth.patches.material_memo_common'

return {
   id = 'ace_material_check_memo',
   default_enabled = true,    -- exact (shadow checks 0 mismatches); docs/experiments/009-restock-caches-material-memo.md
   target_ace = true,
   module = 'stonehearth.services.server.catalog.catalog_service',
   method = 'is_material',
   expect = { source_suffix = 'services/server/catalog/catalog_service.lua', linedefined = 93, lastlinedefined = 106 },
   wrap = common.memo_wrap('ace_material_check_memo'),
   requires = {
      { module = 'stonehearth.services.server.catalog.catalog_service', method = 'get_material_object',
        expect = { source_suffix = 'services/server/catalog/catalog_service.lua', linedefined = 108, lastlinedefined = 115 } },
      { module = 'stonehearth.components.material.material', method = 'contains_all_parts',
        expect = { source_suffix = 'components/material/material.lua', linedefined = 85, lastlinedefined = 87 } },
   },
}
