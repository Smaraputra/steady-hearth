-- Debug-only leak census, client side: only the nil-sender guard for Lua events mode (see
-- nil_sender_guard.lua); the census itself runs on the server.
local guarded = require 'perf_census.nil_sender_guard'()
radiant.log.write_('perf_census', 0, 'PERF_CENSUS|client|nil_sender_guard=%s', tostring(guarded))

return {}
