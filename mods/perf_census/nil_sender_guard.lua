-- Census runs switch the game to the Lua event manager (mods.radiant.use_cpp_events=false) to see
-- listeners. It asserts on a nil sender, while the C++ event manager of normal play accepts one
-- silently: a job-churn run with C++ events logged no error over 360 job changes
-- (20261028-133458-...-pchurn-time-t1c-r1) where every census run asserts in events.lua:310 (RT8),
-- from EntityFormsComponent:destroy triggering on a nil parent while demotion destroys equipment.
-- The assertion aborts the rest of that destroy, so census runs leaked traces that normal play does
-- not. In Lua events mode this makes trigger and trigger_async ignore a nil sender, as the C++
-- manager does; with C++ events it changes nothing. Listening on a nil sender (RT7) is left alone.
local function install()
   local events = radiant.events
   if events._senders == nil then
      return false   -- C++ events: normal play, nothing to change
   end
   local trigger, trigger_async = events.trigger, events.trigger_async
   events.trigger = function(object, ...)
      if object == nil then
         return
      end
      return trigger(object, ...)
   end
   events.trigger_async = function(object, ...)
      if object == nil then
         return
      end
      return trigger_async(object, ...)
   end
   return true
end

return install
