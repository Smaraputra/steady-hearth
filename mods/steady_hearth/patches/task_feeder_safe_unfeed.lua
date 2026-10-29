-- Task feeder: take a task's action back from a worker that left the group, but not while the
-- worker is still executing it, apart from the residual race described below (finding T1, third approach).
--
-- TaskFeeder:_start_feeding listens for 'worker_remove', but TaskGroup:remove_worker triggers
-- 'worker_removed', so a worker that leaves a group keeps the actions of the group's tasks; the
-- census measured them accumulating under job changes. The first repair (task_feeder_worker_removed)
-- listens for the right event and unfeeds at once. Under job churn it ran clean in 4 of 6 runs; the
-- other two hung (an AI CHECK cascade with a busy hang, and an idle hang). In the cascade's trace the
-- worker was still executing the task's action (following a path for build_ladder) when it was
-- removed, while TaskGroup:remove_worker was tearing down the dispatcher frame above it
-- (docs/experiments/002-lua-ai-fixes.md). The second repair (task_feeder_departed_cleanup) waited
-- for the task to end and so missed the permanent tasks.
--
-- This variant listens for 'worker_removed' like the first, and unfeeds through the game's own
-- deferred path when the worker is not running this task's action. A departed worker cannot start
-- the action again (Task:__action_try_start refuses workers no longer in the group), so it can only
-- be running if it started before leaving; such a worker waits on a per-feeder game-loop check until
-- the engine has stopped that action (Task:__action_stopped clears it from _running_actions), and is
-- unfed then. The check is repeated when the deferred removal actually runs
-- (_process_deferred_unfed_workers): a worker that is back in the group keeps the action, and one
-- that runs it again goes back to waiting, so, apart from that residual, no removal reaches an executing action while the task
-- lives. A worker that rejoins while waiting is forgotten and handled as in the shipped game. When the
-- task ends, its current workers are unfed exactly as shipped, and departed workers still waiting or
-- still running the action are dropped without an unfeed, as the shipped game never unfeeds departed
-- workers (two review rounds, 2026-10-28). Residual, shared with the shipped removal path: the engine
-- applies a removal on the AI thread after a message, so a worker that rejoins and starts the action
-- in that window is not covered.
-- The four methods are copies of the originals with the marked additions. Mutually exclusive with
-- task_feeder_worker_removed and task_feeder_departed_cleanup (whichever installs first changes
-- _start_feeding, and the others' guards then refuse).

local function running_for(self, worker_id)
   local running = self._task and self._task._running_actions
   if not running then
      return false
   end
   for action, _ in pairs(running) do
      local entity = action.get_entity and action:get_entity()
      if entity and entity:is_valid() and entity:get_id() == worker_id then
         return true
      end
   end
   return false
end

local function stop_waiting_loop(self)
   if self._perf_wait_loop then
      self._perf_wait_loop:destroy()
      self._perf_wait_loop = nil
   end
end

local function check_waiting(self)
   if not self._perf_waiting then
      stop_waiting_loop(self)
      return
   end
   for id, worker in pairs(self._perf_waiting) do
      -- assigning nil to an existing key during pairs is allowed in Lua
      if not worker:is_valid() then
         self._perf_waiting[id] = nil
      elseif not running_for(self, id) then
         self._perf_waiting[id] = nil
         self:_unfeed(worker)
      end
   end
   if not next(self._perf_waiting) then
      stop_waiting_loop(self)
   end
end

local function wait_for_stop(self, worker)
   self._perf_waiting[worker:get_id()] = worker
   if not self._perf_wait_loop then
      self._perf_wait_loop = radiant.on_game_loop('TaskFeeder departed worker wait', function()
            check_waiting(self)
         end)
   end
end

local function on_worker_removed(self, worker)
   if self._perf_stopped or not self._perf_waiting or not worker or not worker:is_valid() then
      return
   end
   if running_for(self, worker:get_id()) then
      wait_for_stop(self, worker)
   else
      self:_unfeed(worker)
   end
end

local function on_worker_added(self, worker)
   if self._perf_waiting and worker and worker:is_valid() then
      self._perf_waiting[worker:get_id()] = nil
      if not next(self._perf_waiting) then
         stop_waiting_loop(self)
      end
   end
end

local function start_feeding(self)
   for id, worker in pairs(self._task_group:get_workers()) do
      self:_feed(worker)
   end
   self._worker_added_listener = radiant.events.listen(self._task_group, 'worker_added', self, self._feed)
   if self._perf_stopped then
      -- a 'started' that arrives after the task ended: as shipped
      self._worker_removed_listener = radiant.events.listen(self._task_group, 'worker_remove', self, self._unfeed)
      return
   end
   -- perf: the event the task group actually fires, unfeeding only workers not running the action
   self._perf_waiting = self._perf_waiting or {}
   self._worker_removed_listener = radiant.events.listen(self._task_group, 'worker_removed', function(worker)
         on_worker_removed(self, worker)
      end)
   self._perf_returned_listener = radiant.events.listen(self._task_group, 'worker_added', function(worker)
         on_worker_added(self, worker)
      end)
end

local function stop_feeding_and_self_destruct(self)
   for id, worker in pairs(self._task_group:get_workers()) do
      self:_unfeed(worker)
   end
   -- perf: departed workers still running the action are dropped, not unfed (as shipped)
   self._perf_stopped = true
   self._perf_waiting = nil
   stop_waiting_loop(self)
   if self._perf_returned_listener then
      self._perf_returned_listener:destroy()
      self._perf_returned_listener = nil
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
   self._perf_waiting = nil
   stop_waiting_loop(self)
   if self._perf_returned_listener then
      self._perf_returned_listener:destroy()
      self._perf_returned_listener = nil
   end
end

local function process_deferred_unfed_workers(self)
   while true do
      local worker_id = next(self._workers_pending_unfeed)
      if not worker_id then
         break
      end
      local worker = self._workers_pending_unfeed[worker_id]
      self._workers_pending_unfeed[worker_id] = nil

      if worker:is_valid() then
         -- perf: check again now that the removal is due. A worker back in the group keeps the
         -- action while the task lives; a departed worker running it waits while the task lives and
         -- is dropped after the task ended (the shipped game never unfeeds departed workers);
         -- current workers at the task's end are unfed as shipped.
         local live = self._perf_waiting ~= nil and not self._perf_stopped
         local member = self._task_group:contains_worker(worker)
         if live and member then
            self._log:detail('worker %s rejoined; keeping run task action', worker)
         elseif not member and running_for(self, worker_id) then
            if live then
               wait_for_stop(self, worker)
            end
         else
            self._log:detail('removing run task action from %s', worker)
            worker:add_component('stonehearth:ai')
                     :remove_custom_action(self._task_action)
         end
      end
   end
end

local SOURCE = 'stonehearth/services/server/tasks/task_feeder.lua'

return {
   id = 'task_feeder_safe_unfeed',
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
      {
         method = '_process_deferred_unfed_workers',
         expect = { source_suffix = SOURCE, linedefined = 126, lastlinedefined = 141 },
         replacement = process_deferred_unfed_workers,
      },
   },
}
