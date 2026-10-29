perf_probe = {}

local probe_lib = require 'perf_probe.lib.probe_lib'

probe_lib.report_runtime('client')

-- load-time marks on the client (tools/load_report.py): when the engine's client-side steps of a
-- launch or a save load happen, between the server's marks and the UI's
local load_mark = function(what)
   radiant.log.write_('perf_probe', 0, 'PERF_PROBE|load|what=client_%s|realtime=%.3f|lua_kb=%d', what,
      _host:get_realtime(), math.floor(collectgarbage('count')))
end

load_mark('perf_probe_client_init')
-- first occurrence only: some of these fire every frame (data_restored) or on every UI reload
local seen = {}
for _, event in ipairs({ 'required_loaded', 'client:server_ready', 'client:data_restored',
                         'client:terrain_ready', 'client:game_joined', 'client:ui_screen_changed',
                         'client:ui_reloaded' }) do
   radiant.events.listen(radiant, 'radiant:' .. event, function()
         if not seen[event] then
            seen[event] = true
            load_mark((event:gsub('^client:', '')))
         end
      end)
end

return perf_probe
