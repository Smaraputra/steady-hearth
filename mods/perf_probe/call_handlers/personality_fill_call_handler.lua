-- perf_probe (diagnostic only): give every citizen a long journal, to measure what the personality
-- log costs a save (Steady Hearth's personality_log_cap, docs/experiments/014).
--
-- perf_probe:fill_personality_log(days, per_day) clears each citizen's journal, then writes per_day
-- entries for each of the `days` days before today through the citizen's own _add_log_entry (ACE's
-- wrapper included), with the calendar's get_date_data pointed at each past day in turn, so the pages
-- and entries have exactly the shape the game writes. The entries come from the personality
-- service's activity logs for the citizen's personality. Finally today's page is started, which moves
-- the last past day into the log. Responds with the citizens filled and the pages they hold.
local PersonalityFillCallHandler = class()

local function date_of(n, constants)
   local per_year = constants.months_per_year * constants.days_per_month
   local rest = n % per_year
   return { year = math.floor(n / per_year), month = math.floor(rest / constants.days_per_month) + 1, day = rest % constants.days_per_month + 1 }
end

local function day_number(date, constants)
   return (date.year * constants.months_per_year + (date.month - 1)) * constants.days_per_month + (date.day - 1)
end

function PersonalityFillCallHandler:fill_personality_log(session, response, days, per_day)
   days, per_day = tonumber(days) or 60, tonumber(per_day) or 3
   local calendar = stonehearth.calendar
   local constants = calendar:get_constants()
   local today = calendar:get_date_data()
   local today_n = day_number(today, constants)
   local activities = {}
   for name, _ in pairs(stonehearth.personality._activity_logs or {}) do
      table.insert(activities, name)
   end
   table.sort(activities)

   local real_get_date_data = calendar.get_date_data
   local citizens, pages, entries = 0, 0, 0
   local ok, err = pcall(function()
      for _, population in pairs(stonehearth.population:get_all_populations()) do
         for _, citizen in population:get_citizens():each() do
            local personality = citizen:get_component('stonehearth:personality')
            if personality then
               citizens = citizens + 1
               personality._sv._log = {}
               personality._sv.todays_log = {}
               for d = days, 1, -1 do
                  local date = date_of(today_n - d, constants)
                  calendar.get_date_data = function() return radiant.shallow_copy(date) end
                  local written, tried = 0, 0
                  while written < per_day and tried < #activities do
                     tried = tried + 1
                     local activity = activities[((d * per_day + tried) % #activities) + 1]
                     local substitutions = radiant.shallow_copy(personality._sv.substitutions or {})
                     local title, log, extra = stonehearth.personality:get_activity_log(nil, activity, personality._sv.personality, substitutions)
                     if log then
                        personality:_add_log_entry(title, log, extra or {}, nil)
                        written = written + 1
                        entries = entries + 1
                     end
                  end
               end
               calendar.get_date_data = real_get_date_data
               personality:_init_day(today)
               pages = pages + #personality._sv._log
            end
         end
      end
   end)
   calendar.get_date_data = real_get_date_data
   radiant.log.write_('perf_probe', 0, 'PERF_PROBE|personality_fill|ok=%s|citizens=%d|pages=%d|entries=%d|activities=%d|error=%s',
      tostring(ok), citizens, pages, entries, #activities, tostring(err))
   response:resolve({ ok = ok, citizens = citizens, pages = pages, entries = entries, error = err and tostring(err) })
end

return PersonalityFillCallHandler
