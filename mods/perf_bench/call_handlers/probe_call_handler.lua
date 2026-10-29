local probe_state = require 'perf_bench.lib.probe_state'

local ProbeCallHandler = class()

function ProbeCallHandler:probe_phase(session, response)
   return { phase = probe_state.phase }
end

function ProbeCallHandler:probe_done(session, response, result)
   probe_state.result = result or {}
   probe_state.phase = 'done'
   return true
end

return ProbeCallHandler
