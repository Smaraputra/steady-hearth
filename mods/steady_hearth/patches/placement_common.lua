-- Shared parts of the placement request release patches (finding A2b in docs/atlas/findings.md, E1 in
-- docs/ace-notes.md).
--
-- A ghost asks its town for a placement task in _add_to_town (every placeable item type), but
-- _remove_from_town gives it back only inside the block for items with a placement limit, so the
-- town's entry for an item type outlives every ghost that wanted it. Placement actions keep trying
-- those types, each try holding the worker until a 5 s realtime failsafe. The patches record each
-- request a ghost makes and release exactly those requests when the ghost leaves the town.
local M = {}

-- A plain field, not saved: a loaded ghost requests again in post_activate, which records again.
function M.record(ghost, request)
   local requests = ghost._perf_placement_requests
   if not requests then
      requests = {}
      ghost._perf_placement_requests = requests
   end
   table.insert(requests, request)
end

-- A request goes back only to the town that took it, and only while that town is still the player's
-- town: a replacement town for the same player may hold an unrelated request for the same item.
function M.same_town(request)
   return request.town ~= nil and stonehearth.town:get_town(request.player_id) == request.town
end

function M.take(ghost)
   local requests = ghost._perf_placement_requests or {}
   ghost._perf_placement_requests = nil
   return requests
end

-- Placement actions walk the town's entries with next(item_types, cursor) across ticks. Once entries
-- are released, the entry under a cursor can disappear, and next() from a key that is no longer in
-- the table is undefined in Lua 5.1 ("invalid key to 'next'" after a rehash). ACE's own actions
-- restart from the beginning in that case (prev_key in its place_item_type_on_structure_2); this
-- wrapper gives the base game's actions the same behaviour and leaves the original body untouched.
local function work_town_entries(self)
   local town = stonehearth.town:get_town(radiant.entities.get_work_player_id(self._entity))
   return town and town:get_requested_placement_tasks()
end

function M.wrap_try_next_entry(original)
   return function(self, ai, entity)
      local cursor = self._item_type_cursor
      if cursor ~= nil then
         local item_types = work_town_entries(self)
         if not (item_types and item_types[cursor] ~= nil) then
            self._item_type_cursor = nil
         end
      end
      return original(self, ai, entity)
   end
end

return M
