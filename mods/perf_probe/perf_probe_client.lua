perf_probe = {}

local probe_lib = require 'perf_probe.lib.probe_lib'

probe_lib.report_runtime('client')

return perf_probe
