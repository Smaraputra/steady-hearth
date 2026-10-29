-- Citizen journals: keep the last 30 days of personality log pages instead of every day of the game.
--
-- Personality:_init_day (stonehearth/components/personality/personality_component.lua, base game; ACE
-- wraps only _add_log_entry, which calls this) moves yesterday's journal page to the top of
-- _sv._log whenever a citizen logs the first entry of a new day. _log is never trimmed and, being an
-- underscore field, is never sent to the UI: the character sheet shows only todays_log. So every
-- citizen's save data grows by one page per day with entries, for the whole game. This wrap lets the
-- original run, then drops the pages of _log whose date is more than
-- mods.steady_hearth.personality_log_days (default 30) calendar days before the new day. A citizen's
-- existing longer history is trimmed the next time it starts a new page. Pages without a date are
-- kept. Trimmed pages stay trimmed when the save is loaded without the mod; nothing reads them.

local DAYS = math.max(1, math.floor(tonumber(_host:get_config('mods.steady_hearth.personality_log_days')) or 30))

-- calendar days since the calendar's year 0 for a date from CalendarService:get_date_data (day and
-- month count from 1)
local function day_number(date, constants)
   return (date.year * constants.months_per_year + (date.month - 1)) * constants.days_per_month + (date.day - 1)
end

local function trimmed_init_day(original)
   return function(self, day)
      original(self, day)
      local log = self._sv._log
      local constants = stonehearth.calendar:get_constants()
      if type(log) ~= 'table' or type(day) ~= 'table' or not constants then
         return
      end
      local today = day_number(day, constants)
      local trimmed = false
      -- every expired page goes, wherever it sits; undated pages and pages dated after the new day
      -- (a calendar set back) stay. About 30 pages once trimmed, so a full pass costs nothing.
      for i = #log, 1, -1 do
         local date = log[i].date
         if type(date) == 'table' and today - day_number(date, constants) > DAYS then
            table.remove(log, i)
            trimmed = true
         end
      end
      if trimmed then
         self.__saved_variables:mark_changed()
      end
   end
end

return {
   id = 'personality_log_cap',
   default_enabled = true,
   module = 'stonehearth.components.personality.personality_component',
   method = '_init_day',
   expect = { source_suffix = 'components/personality/personality_component.lua', linedefined = 162, lastlinedefined = 171 },
   wrap = trimmed_init_day,
   requires = {
      -- the page dates are get_date_data's, and day_number uses the calendar's own constants
      { module = 'stonehearth.services.server.calendar.calendar_service', method = 'get_date_data',
        expect = { source_suffix = 'services/server/calendar/calendar_service.lua', linedefined = 600, lastlinedefined = 602 } },
   },
}
