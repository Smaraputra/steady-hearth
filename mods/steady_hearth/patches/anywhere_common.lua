-- Shared builder for the find_reachable_entity_type_anywhere fix (finding RT2), in a base and an ACE
-- variant (ACE replaces the whole file and filters storage through its cached
-- storage_contains_filter_fn).
--
-- start_thinking runs a ground item finder and a storage item finder side by side. Both call
-- ai:set_think_output({}) on every match and neither stops, so the engine logs 'duplicate
-- "set_think_output" in state ready' (1,904 to 4,733 times per vanilla XL run) while both searches
-- keep scanning. The think output carries no item: it only says that something exists somewhere,
-- and the downstream actions find and pick up the item themselves. So the fix sets the output once
-- and stops both finders on the first match. Everything else is copied line for line.
local NONE = 0
local STORAGE = 1
local GROUND = 2

local NO_MATERIAL = stonehearth.constants.construction.NO_MATERIAL

local log = radiant.log.create_logger('find_reachable_entity_type_anywhere')

local function make_base_storage_filter_fn(args_filter_fn)
   return function(entity)
         local storage = entity:get('stonehearth:storage')
         if not storage then
            return false
         end

         -- Don't look in stockpiles.  Ground searching is done separately.
         if entity:get('stonehearth:stockpile') then
            return false
         end

         -- Don't take items out of non-public storage (e.g.hearthling backpacks)
         if not storage:is_public() then
            return false
         end

         -- cache these upvalues for the loop
         local ai_service = stonehearth.ai
         for _, item in pairs(storage:get_items()) do
            if ai_service:fast_call_filter_fn(args_filter_fn, item) then
               return true
            end
         end

         return false
      end
end

local function make_ace_storage_filter_fn(args_filter_fn)
   return function(entity)
         local storage = entity:get('stonehearth:storage')
         if not storage then
            return false
         end

         -- Don't look in stockpiles.  Ground searching is done separately.
         if entity:get('stonehearth:stockpile') then
            return false
         end

         -- Don't take items out of non-public storage (e.g.hearthling backpacks)
         if not storage:is_public() then
            return false
         end

         return storage:storage_contains_filter_fn(args_filter_fn)
      end
end

local function build_start_thinking(ace)
   local make_storage_filter_fn = ace and make_ace_storage_filter_fn or make_base_storage_filter_fn

   return function(self, ai, entity, args)
      self._ai = ai
      self._description = args.description
      self._filter_fn = args.filter_fn
      self._log = log
      self._location = ai.CURRENT.location
      self._exhausted = NONE
      self._think_output_set = false

      -- ACE: if we're not in the world, why are we thinking about this?
      if ace and not self._location then
         ai:set_think_output({})
         return
      end

      -- If the filter is for a no-material object, then use 'that'.
      if args.material == NO_MATERIAL then
         ai:set_think_output({})
         return
      end

      -- If we're holding, use that.
      local carried_item = ai.CURRENT.carrying
      if carried_item then
         if self._filter_fn(carried_item) then
            ai:set_think_output({})
            return
         else
            local iconic_form = carried_item:get('stonehearth:iconic_form')
            if iconic_form and self._filter_fn(iconic_form:get_root_entity()) then
               ai:set_think_output({})
               return
            end
         end
      end

      -- If we have a backpack, and it's in that, use that.
      local backpack = entity:get('stonehearth:storage')
      if backpack then
         for _, item in pairs(backpack:get_items()) do
            if self._filter_fn(item) then
               ai:set_think_output({})
               return
            else
               local iconic_form = item:get('stonehearth:iconic_form')
               if iconic_form and self._filter_fn(iconic_form:get_root_entity()) then
                  ai:set_think_output({})
                  return
               end
            end
         end
      end

      -- PERF: one think output, then both searches stop
      local function found()
         if not self._think_output_set then
            self._think_output_set = true
            ai:set_think_output({})
         end
         self:_destroy_itemfinders()
      end

      -- Look everywhere on the ground.
      local ground_exhausted_cb = function()
         if self._ground_if == nil then
            return
         end
         self._ground_if:destroy()
         self._ground_if = nil

         self:_set_exhausted(GROUND)
      end
      local ground_found_cb = function(item, flush)
         local item_id = item:get_id()
         if ai.CURRENT.self_reserved[item_id] then
            self._log:spam('already reserved')
            return false
         end

         if not stonehearth.ai:can_acquire_ai_lease(item, entity) then
            return false
         end

         found()
         return true
      end
      self._ground_if = entity:add_component('stonehearth:item_finder'):find_reachable_entity_type(
            self._location,
            args.filter_fn,
            ground_found_cb,
            {
               description = self._description .. ' (ground)',   -- for those of us in meat space
               owner_player_id = args.owner_player_id,
               exhausted_cb = ground_exhausted_cb,
            })
      if self._think_output_set then
         -- the ground finder matched while it was being created
         self:_destroy_itemfinders()
         return
      end

      -- Look everywhere in accessible storage.
      local storage_exhausted_cb = function()
         if self._storage_if == nil then
            return
         end

         self._storage_if:destroy()
         self._storage_if = nil

         self:_set_exhausted(STORAGE)
      end

      local storage_found_cb = function(storage)
         found()
         return true
      end
      local storage_filter_fn = stonehearth.ai:filter_from_key('stonehearth:find_reachable_entity_type_anywhere',
                                                               args.filter_fn, make_storage_filter_fn(args.filter_fn))
      self._storage_if = entity:add_component('stonehearth:item_finder'):find_reachable_entity_type(
            self._location,
            storage_filter_fn,
            storage_found_cb,
            {
               description = self._description .. ' (storage)',   -- for those of us in meat space
               owner_player_id = args.owner_player_id,
               exhausted_cb = storage_exhausted_cb,
            })
      if self._think_output_set then
         self:_destroy_itemfinders()
      end
   end
end

return { build_start_thinking = build_start_thinking }
