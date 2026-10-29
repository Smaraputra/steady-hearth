-- perf_probe (diagnostic only): copy of stonehearth/stonehearth_server.lua (Stonehearth 1.1.0.949) with
-- timing marks, to attribute start-up and load time to services. Marked lines start with
-- `-- perf_probe:`. Every mark is a PERF_PROBE|startup|... log line with the real time in ms since
-- this file ran and the Lua heap in KB. Installed through perf_probe's manifest overrides, so it is
-- active only when perf_probe is enabled.
local perf_probe_t0 = _host:get_realtime()   -- perf_probe:
local function perf_probe_mark(what, extra)   -- perf_probe:
   radiant.log.write_('perf_probe', 0, 'PERF_PROBE|startup|what=%s|ms=%.0f|lua_kb=%d%s', what,
      (_host:get_realtime() - perf_probe_t0) * 1000, math.floor(collectgarbage('count')), extra or '')
end
perf_probe_mark('stonehearth_server_start')   -- perf_probe:

local StonehearthCommon = require 'stonehearth.stonehearth_common'
local LootTable = require 'stonehearth.lib.loot_table.loot_table'

stonehearth = {
   -- perf_probe: absolute path; this copy lives in perf_probe, where the relative 'constants' does not resolve
   constants = require 'stonehearth.constants'
}

-- set the debug flag based on the type of build, or specifc opting in by setting
-- the 'stoneheath.debug' flag
stonehearth.debug = radiant.util.get_config('debug')
if debug == nil then
   -- on by default in developer builds.  off in all other build types.
   stonehearth.debug = radiant.util.get_build_type() == 'developer'
end
if stonehearth.debug then
   radiant.log.write('stonehearth', 0, 'stonehearth.debug is on');
end

local service_creation_order = stonehearth.constants.server.SERVICE_CREATION_ORDER

-- perf_probe: mods.perf_probe.profile_catalog=true profiles the catalog service's creation
local perf_probe_profile_catalog = tostring(_host:get_config('mods.perf_probe.profile_catalog')) == 'true'   -- perf_probe:
-- perf_probe: mods.perf_probe.catalog_detail=true times the catalog's JSON loads and material objects
local perf_probe_catalog_detail = tostring(_host:get_config('mods.perf_probe.catalog_detail')) == 'true'   -- perf_probe:
local perf_probe_lib = require 'perf_probe.lib.probe_lib'   -- perf_probe:

local function create_service(name, path)
   local perf_probe_ms, perf_probe_kb = _host:get_realtime(), collectgarbage('count')   -- perf_probe:
   if perf_probe_profile_catalog and name == 'catalog' then perf_probe_lib.toggle_profiler('catalog_on') end   -- perf_probe:
   -- perf_probe: the paths are relative to the stonehearth mod, and this copy lives in perf_probe
   local perf_probe_path = path:find('^services%.') and ('stonehearth.' .. path) or path   -- perf_probe:
   local perf_probe_detail = perf_probe_catalog_detail and name == 'catalog'   -- perf_probe:
      and perf_probe_lib.catalog_detail_begin(require(perf_probe_path))   -- perf_probe:
   local service = require(perf_probe_path)()   -- perf_probe:

   local saved_variables = stonehearth._sv[name]
   if not saved_variables then
      saved_variables = radiant.create_datastore()
      stonehearth._sv[name] = saved_variables
   end
   service.__saved_variables = saved_variables
   service._sv = saved_variables:get_data()
   saved_variables:set_controller(service)
   saved_variables:set_controller_name('stonehearth:' .. name)
   service:initialize()
   if perf_probe_detail then perf_probe_lib.catalog_detail_finish(perf_probe_detail, 'server') end   -- perf_probe:
   stonehearth[name] = service
   if perf_probe_profile_catalog and name == 'catalog' then perf_probe_lib.toggle_profiler('catalog_off') end   -- perf_probe:
   perf_probe_mark('service', string.format('|name=%s|took_ms=%.1f|kb_delta=%d', name,   -- perf_probe:
      (_host:get_realtime() - perf_probe_ms) * 1000, math.floor(collectgarbage('count') - perf_probe_kb)))   -- perf_probe:
end

local function cleanup_entity(entity)
   StonehearthCommon.destroy_child_entities(entity)
   StonehearthCommon.destroy_entity_forms(entity)
end

local function create_reconsider_stats_timer()
   local timeout = radiant.util.get_config('reconsider_stats_interval', false)
   if timeout then
      local ALL_REASONS = {}
      local COUNT = 0
      local TOTAL = 0
      stonehearth.ai:on_reconsider_entity('collecting stats', function(msg)
            local reason = msg.reason and tostring(msg.reason) or string.format('no reason for %s', tostring(msg.entity))
            ALL_REASONS[reason] = (ALL_REASONS[reason] or 0) + 1
            COUNT = COUNT + 1
            TOTAL = TOTAL + 1
         end)
      radiant.set_realtime_interval('reconsider stats timer', timeout, function()
            local stats = { { name = 'total', count = TOTAL }}
            for name, count in pairs(ALL_REASONS) do
               table.insert(stats, { name = name, count = count })
            end
            table.sort(stats, function(a, b)
                  return a.count > b.count
               end)
            radiant.log.write('stonehearth', 0, '-- reconsider entity stats ----------------')
            radiant.log.write('stonehearth', 1, ' %10s - %s', 'count', 'reason');
            for _, entry in pairs(stats) do
               radiant.log.write('stonehearth', 1, ' %10d - %s', entry.count, entry.name)
            end
            radiant.log.write('stonehearth', 1, '-- reconsider entity stats (end) ----------')
            stonehearth.ai:dump_reconsider_listeners()
         end)
   end
end

local function create_timer_reasons_timer()
   local timeout = radiant.util.get_config('timer_stats_interval', false)
   if timeout then
      radiant._sv.time_tracker:start_collecting_stats(timeout)
      radiant._sv.game_state_time_tracker:start_collecting_stats(timeout)
      stonehearth.calendar._sv._time_tracker:start_collecting_stats(timeout)
   end
end

radiant.events.listen(stonehearth, 'radiant:init', function()
      perf_probe_mark('radiant_init')   -- perf_probe:
      radiant.terrain.initialize(true)
      stonehearth._sv = stonehearth.__saved_variables:get_data()
      -- now create all the services
      for _, record in ipairs(service_creation_order) do
         for name, path in pairs(record) do
            create_service(name, path)
         end
      end

      perf_probe_mark('services_created')   -- perf_probe:
      radiant.events.trigger_async(radiant, 'radiant:services:init')

      radiant.events.listen(radiant, 'radiant:entity:stop', function(e)
            radiant.xpcall(function()
                  local ai_component = e.entity:get_component('stonehearth:ai')
                  if ai_component then
                     ai_component:stop()
                  end
               end)
         end)

      radiant.events.listen(radiant, 'radiant:entity:destroy', function(e)
            radiant.xpcall(function()
                  cleanup_entity(e.entity)
               end)
         end)

      radiant.events.listen(radiant, 'radiant:headless:init', function()
         radiant.log.write('stonehearth', 0, 'radiant:headless:init')
         local options = radiant.util.get_global_config('multiplayer.server.headless.options', {})
         stonehearth.game_creation:build_world(options)
      end)

      -- Add players when they join for the first time
      radiant.events.listen(radiant, 'radiant:client_joined', function(e)
         radiant.log.write('stonehearth', 0, 'Player \'%s\' joined', e.player_id)

         local players = stonehearth.player:get_players()
         if not players[e.player_id] then
            stonehearth.player:add_player(e.player_id)
         end

         stonehearth.presence:set_connection_state(e.player_id, stonehearth.constants.multiplayer.connection_state.CONNECTING)
      end)

      radiant.events.listen(radiant, 'radiant:client_removed', function(e)
         radiant.log.write('stonehearth', 0, 'Player \'%s\' left', e.player_id)
         stonehearth.presence:set_connection_state(e.player_id, stonehearth.constants.multiplayer.connection_state.DISCONNECTED)

         stonehearth.town:suspend_town(e.player_id)
      end)

      -- xxx: boo!
      create_reconsider_stats_timer()
      create_timer_reasons_timer()
   end)

radiant.events.listen(stonehearth, 'radiant:new_game', function()
      -- stop the calendar service until the user has a chance to
      -- work their way into the actual game.
      stonehearth.calendar:stop()
   end)

return stonehearth
