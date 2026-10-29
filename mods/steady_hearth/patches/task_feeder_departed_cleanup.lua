-- Task feeder: take a task's action back from workers that left the group, when the task ends
-- (finding T1, second approach).
--
-- TaskFeeder:_start_feeding listens for 'worker_remove', but TaskGroup:remove_worker triggers
-- 'worker_removed', so a worker that leaves a group keeps the action of every task that ends after
-- it left; the census measured +17 live task actions per worker every 4 game hours under job
-- changes. The first repair (task_feeder_worker_removed) unfed those workers at once. That removed
-- the actions while TaskGroup:remove_worker was still tearing down the group's dispatcher frame
-- above them, and under job churn the AI hit engine CHECKs (execution_frame.cpp:1698, :1320,
-- :2174) and hung (docs/experiments/002-lua-ai-fixes.md).
--
-- This variant leaves the moment of leaving alone (the original 'worker_remove' listener is kept
-- and never fires, as in the shipped game). It records every worker the feeder fed. When the task
-- ends, the workers that were fed but are no longer in the group (read synchronously from
-- get_workers, so a departure whose async event is still queued is included) are unfed through the
-- same deferred path the game already uses for the current workers. Usually such a worker's
-- dispatcher frame for this group is long gone and the removal only updates its action index; a
-- departure immediately followed by the task's end can still overlap the teardown, as the shipped
-- TaskGroup:destroy (clear_tasks, then clear_workers) does for current workers. A worker that
-- rejoined is a current worker again and is handled exactly as in the shipped game.
-- The three methods are copies of the originals with the marked additions. Mutually exclusive with
-- task_feeder_worker_removed (whichever installs first changes _start_feeding, and the other's
-- guard then refuses).

local function start_feeding(self)
   for id, worker in pairs(self._task_group:get_workers()) do
      self:_feed(worker)
   end
   self._worker_added_listener = radiant.events.listen(self._task_group, 'worker_added', self, self._feed)
   self._worker_removed_listener = radiant.events.listen(self._task_group, 'worker_remove', self, self._unfeed)
   -- perf: remember who was fed; a 'started' that arrives after the task ended records nothing
   if not self._perf_stopped then
      self._perf_fed = {}
      for id, worker in pairs(self._task_group:get_workers()) do
         if worker:is_valid() then
            self._perf_fed[id] = worker
         end
      end
      self._perf_fed_listener = radiant.events.listen(self._task_group, 'worker_added', function(worker)
            if self._perf_fed and worker and worker:is_valid() then
               self._perf_fed[worker:get_id()] = worker
            end
         end)
   end
end

local function stop_feeding_and_self_destruct(self)
   local current = self._task_group:get_workers()
   for id, worker in pairs(current) do
      self:_unfeed(worker)
   end
   -- perf: fed workers that are no longer in the group still hold this task's action
   self._perf_stopped = true
   if self._perf_fed then
      for id, worker in pairs(self._perf_fed) do
         if not current[id] then
            self:_unfeed(worker)
         end
      end
      self._perf_fed = nil
   end
   if self._perf_fed_listener then
      self._perf_fed_listener:destroy()
      self._perf_fed_listener = nil
   end
   if self._worker_added_listener then
      self._worker_added_listener:destroy()
      self._worker_added_listener = nil
   end
   if self._worker_removed_listener then
      self._worker_removed_listener:destroy()
      self._worker_removed_listener = nil
   end
   self._gameloop_listener = radiant.on_game_loop_once('TaskFeeder self destruct', function()
      self:destroy()
   end)
end

local function destroy(self)
   if self._task_started_listener then
      self._task_started_listener:destroy()
      self._task_started_listener = nil
   end
   if self._worker_added_listener then
      self._worker_added_listener:destroy()
      self._worker_added_listener = nil
   end
   if self._worker_removed_listener then
      self._worker_removed_listener:destroy()
      self._worker_removed_listener = nil
   end
   -- perf
   self._perf_stopped = true
   self._perf_fed = nil
   if self._perf_fed_listener then
      self._perf_fed_listener:destroy()
      self._perf_fed_listener = nil
   end
end

local SOURCE = 'stonehearth/services/server/tasks/task_feeder.lua'

return {
   id = 'task_feeder_departed_cleanup',
   default_enabled = false,   -- experiment: churn census first (docs/experiments/002-lua-ai-fixes.md)
   target_ace = nil,          -- base code, used with and without ACE
   module = 'stonehearth.services.server.tasks.task_feeder',
   method = '_start_feeding',
   expect = { source_suffix = SOURCE, linedefined = 50, lastlinedefined = 56 },
   replacement = start_feeding,
   also = {
      {
         method = 'stop_feeding_and_self_destruct',
         expect = { source_suffix = SOURCE, linedefined = 58, lastlinedefined = 73 },
         replacement = stop_feeding_and_self_destruct,
      },
      {
         method = 'destroy',
         expect = { source_suffix = SOURCE, linedefined = 35, lastlinedefined = 48 },
         replacement = destroy,
      },
   },
}
