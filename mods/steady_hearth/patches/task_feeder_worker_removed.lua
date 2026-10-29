-- Task feeder: listen for the event the task group actually fires (finding T1).
--
-- TaskFeeder:_start_feeding listens for 'worker_remove', but TaskGroup:remove_worker triggers
-- 'worker_removed'. A worker that leaves a task group (job change, removal) therefore keeps the
-- group's injected TaskActions for the rest of the session and keeps thinking about the old group's
-- tasks; the census measured +17 live task actions per worker every 4 game hours under job changes.
-- This copy is identical except for the event name.
local function start_feeding(self)
   for id, worker in pairs(self._task_group:get_workers()) do
      self:_feed(worker)
   end
   self._worker_added_listener = radiant.events.listen(self._task_group, 'worker_added', self, self._feed)
   self._worker_removed_listener = radiant.events.listen(self._task_group, 'worker_removed', self, self._unfeed)
end

return {
   id = 'task_feeder_worker_removed',
   -- off until the churn census hang of 2026-10-28 is explained: removing task actions on job change
   -- is an engine path the shipped game never ran (docs/experiments/002-lua-ai-fixes.md)
   default_enabled = false,
   target_ace = nil,          -- base code, used with and without ACE
   module = 'stonehearth.services.server.tasks.task_feeder',
   method = '_start_feeding',
   expect = {
      source_suffix = 'stonehearth/services/server/tasks/task_feeder.lua',
      linedefined = 50,
      lastlinedefined = 56,
   },
   replacement = start_feeding,
}
