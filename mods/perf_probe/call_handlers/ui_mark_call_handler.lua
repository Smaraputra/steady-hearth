-- perf_probe (diagnostic only): the UI calls perf_probe:ui_mark to put a timestamped line into
-- stonehearth.log (JS console output does not reach the log).
local UiMarkCallHandler = class()

function UiMarkCallHandler:ui_mark(session, response, name, detail)
   radiant.log.write_('perf_probe', 0, 'PERF_PROBE|ui_mark|name=%s|detail=%s', tostring(name), tostring(detail or ''))
   return true
end

return UiMarkCallHandler
