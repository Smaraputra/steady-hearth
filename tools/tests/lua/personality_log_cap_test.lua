-- Test for mods/steady_hearth/patches/personality_log_cap.lua (run from the repository root with
-- `lua5.1 tools/tests/lua/personality_log_cap_test.lua`): with the base game's Personality:_init_day as
-- the original, a new day keeps the pages dated up to 30 calendar days back, drops older ones
-- wherever they sit, keeps undated and future-dated pages, works across month and year boundaries (7-day months, 12-month years, as
-- the base calendar), and marks the saved variables changed only when it dropped something.
_host = { get_config = function() return nil end }
stonehearth = { calendar = { get_constants = function() return { days_per_month = 7, months_per_year = 12 } end } }
radiant = { log = { write_ = function() end } }
local patch = dofile('mods/steady_hearth/patches/personality_log_cap.lua')

-- base Personality:_init_day (stonehearth/components/personality/personality_component.lua 162-171)
local function base_init_day(self, day)
   if self._sv.todays_log.date then
      table.insert(self._sv._log, 1, self._sv.todays_log)
   end
   local new_day_data = {}
   new_day_data.date = day
   new_day_data.entries = {}
   self._sv.todays_log = new_day_data
   self.__saved_variables:mark_changed()
end
local init_day = patch.wrap(base_init_day)

local function date_of(n)   -- day number (from 0) to a get_date_data date
   local year = math.floor(n / 84)
   local rest = n % 84
   return { year = year, month = math.floor(rest / 7) + 1, day = rest % 7 + 1 }
end

-- a citizen whose pages run from day `first` to day `last` (newest first in _log), today = last + 1
local function citizen(first, last)
   local changed = 0
   local self = { _sv = { _log = {}, todays_log = {} }, __saved_variables = { mark_changed = function() changed = changed + 1 end } }
   for n = first, last do
      base_init_day(self, date_of(n))
   end
   return self, function() return changed end
end

local failures = 0
local function check(ok, what)
   if not ok then
      failures = failures + 1
      print('FAIL: ' .. what)
   end
end

-- 60 days of pages crossing a year boundary (days 60 to 119), the new day is 120
local c = citizen(60, 119)
init_day(c, date_of(120))
check(#c._sv._log == 30, 'kept ' .. #c._sv._log .. ' pages, expected 30')
local newest, oldest = c._sv._log[1].date, c._sv._log[#c._sv._log].date
check(newest.year == date_of(119).year and newest.month == date_of(119).month and newest.day == date_of(119).day, 'newest page is not yesterday')
check(oldest.year == date_of(90).year and oldest.month == date_of(90).month and oldest.day == date_of(90).day, 'oldest page is not 30 days back')
check(c._sv.todays_log.date.day == date_of(120).day and #c._sv.todays_log.entries == 0, 'today\'s page is not the new day')

-- exactly 30 days of history: nothing dropped, so no extra mark_changed beyond the original's
local d, changes = citizen(91, 119)
local before = changes()
init_day(d, date_of(120))
check(#d._sv._log == 29, 'short history changed: ' .. #d._sv._log)
check(changes() - before == 1, 'marked changed ' .. (changes() - before) .. ' times for a new day without trimming')

-- an undated page and a page dated after the new day are kept, and expired pages around them still go
local e = citizen(10, 79)
table.insert(e._sv._log, { entries = {} })
table.insert(e._sv._log, 20, { date = date_of(500), entries = {} })
init_day(e, date_of(80))
local undated, future = 0, 0
for _, page in ipairs(e._sv._log) do
   if page.date == nil then undated = undated + 1 elseif page.date.year == date_of(500).year then future = future + 1 end
end
check(undated == 1 and future == 1, 'kept ' .. undated .. ' undated and ' .. future .. ' future pages, expected 1 and 1')
check(#e._sv._log == 32, 'kept ' .. #e._sv._log .. ' pages, expected 30 dated plus 2')

-- an empty log
local f = { _sv = { _log = {}, todays_log = {} }, __saved_variables = { mark_changed = function() end } }
init_day(f, date_of(5))
check(#f._sv._log == 0, 'empty log changed')

print(string.format('personality log cap: %d failures', failures))
if failures > 0 then
   os.exit(1)
end
