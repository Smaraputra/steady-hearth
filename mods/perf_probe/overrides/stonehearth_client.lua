-- perf_probe (diagnostic only): copy of stonehearth/stonehearth_client.lua (Stonehearth 1.1.0.949) with
-- timing marks, to attribute client start-up and load time to client services (the client builds its
-- own catalog). Marked lines start with `-- perf_probe:`. Every mark is a PERF_PROBE|client_startup|...
-- log line with the real time in ms since this file ran and the Lua heap in KB. Installed through
-- perf_probe's manifest overrides, so it is active only when perf_probe is enabled.
local perf_probe_t0 = _host:get_realtime()   -- perf_probe:
local function perf_probe_mark(what, extra)   -- perf_probe:
   radiant.log.write_('perf_probe', 0, 'PERF_PROBE|client_startup|what=%s|ms=%.0f|lua_kb=%d%s', what,
      (_host:get_realtime() - perf_probe_t0) * 1000, math.floor(collectgarbage('count')), extra or '')
end
perf_probe_mark('stonehearth_client_start')   -- perf_probe:

local StonehearthCommon = require 'stonehearth.stonehearth_common'

stonehearth = {
   -- perf_probe: absolute path; this copy lives in perf_probe, where the relative 'constants' does not resolve
   constants = require 'stonehearth.constants'
}

-- For services that handle input, make sure you load them in the order
-- that you want input to be handled (i.e. xz-region-selection gets priority
-- over unit-selection/orders.)
local service_creation_order = stonehearth.constants.client.SERVICE_CREATION_ORDER

-- perf_probe: mods.perf_probe.catalog_detail=true times the client catalog's JSON loads
local perf_probe_catalog_detail = tostring(_host:get_config('mods.perf_probe.catalog_detail')) == 'true'   -- perf_probe:
local perf_probe_lib = require 'perf_probe.lib.probe_lib'   -- perf_probe:

local function create_service(name, path)
   local perf_probe_ms, perf_probe_kb = _host:get_realtime(), collectgarbage('count')   -- perf_probe:
   -- perf_probe: the paths are relative to the stonehearth mod, and this copy lives in perf_probe
   local perf_probe_path = path:find('^services%.') and ('stonehearth.' .. path) or path   -- perf_probe:
   local perf_probe_detail = perf_probe_catalog_detail and name == 'catalog_client'   -- perf_probe:
      and perf_probe_lib.catalog_detail_begin(require(perf_probe_path))   -- perf_probe:
   local service = require(perf_probe_path)()   -- perf_probe:

   local saved_variables = stonehearth._sv[name]
   if not saved_variables then
      saved_variables = radiant.create_datastore()
      stonehearth._sv[name] = saved_variables
   end
   service.__saved_variables = saved_variables
   saved_variables:set_controller(service)
   service._sv = saved_variables:get_data()
   service:initialize()
   if perf_probe_detail then perf_probe_lib.catalog_detail_finish(perf_probe_detail, 'client') end   -- perf_probe:
   stonehearth[name] = service
   perf_probe_mark('service', string.format('|name=%s|took_ms=%.1f|kb_delta=%d', name,   -- perf_probe:
      (_host:get_realtime() - perf_probe_ms) * 1000, math.floor(collectgarbage('count') - perf_probe_kb)))   -- perf_probe:
end

local function cleanup_entity(entity)
   StonehearthCommon.destroy_child_entities(entity)
   StonehearthCommon.destroy_entity_forms(entity)
end

local function update_ui_screen()
   local current_ui_screen = _radiant.client.get_current_ui_screen()

   local default_route_lookup = {
      ['game_screen'] = 'game',
      ['title_screen'] = 'shell/title',
      ['mod_sync_screen'] = 'mod_sync',
   }

   radiant.ui.on_screen_changed(current_ui_screen, default_route_lookup[current_ui_screen])
end

radiant.events.listen(stonehearth, 'radiant:init', function()
   perf_probe_mark('radiant_init')   -- perf_probe:
   radiant.terrain.initialize(false)

   stonehearth._sv = stonehearth.__saved_variables:get_data()
      for _, record in ipairs(service_creation_order) do
         for name, path in pairs(record) do
            create_service(name, path)
         end
      end
      perf_probe_mark('services_created')   -- perf_probe:

      radiant.events.listen(radiant, 'radiant:entity:destroy', function(e)
            radiant.xpcall(function()
                  cleanup_entity(e.entity)
               end)
         end)

      radiant.events.listen(radiant, 'radiant:client:server_ready', function()
         for _, record in ipairs(service_creation_order) do
            for name, _ in pairs(record) do
               if stonehearth[name].on_server_ready then
                  stonehearth[name]:on_server_ready()
               end
            end
         end

         if _radiant.client.is_authenticated_as_host() then
            -- If we are the host, clear pause requests when we refresh the browser.
            -- There could be a problem if we generate pause requests & refresh before
            -- we successsfully connect here. -ayazar
            radiant.events.listen(radiant, 'radiant:client:ui_reloaded', function()
               _radiant.call('stonehearth:dm_clear_pause_requests')
            end)

            -- If we are the host, set our state to connected
            _radiant.call_obj('stonehearth.presence', 'set_connection_state_command', stonehearth.constants.multiplayer.connection_state.CONNECTED)
            _radiant.call_obj('stonehearth.client_state', 'set_default_storage_filter_none_command', radiant.util.get_config('default_storage_filter_none', false))
         end
      end)

      radiant.events.listen(radiant, 'radiant:client:game_joined', function()
            _radiant.call_obj('stonehearth.population', 'is_camp_placed_command')
               :done( function(o)
                     if o.camp_placed then
                        radiant.ui.navigate('game');
                        _radiant.call('radiant:reload_browser');
                        _radiant.call_obj('stonehearth.town', 'continue_town_command')
                     else
                        radiant.ui.navigate('shell/select_game_story');
                        _radiant.call('radiant:reload_browser');
                     end

                     _radiant.call_obj('stonehearth.presence', 'set_connection_state_command', stonehearth.constants.multiplayer.connection_state.CONNECTED)
                     _radiant.call_obj('stonehearth.client_state', 'set_default_storage_filter_none_command', radiant.util.get_config('default_storage_filter_none', false))
                  end)
               :fail(function(o)
                  radiant.log.write('stonehearth_client', 0, 'is_camp_placed_command failed')
               end)
         end)

      update_ui_screen()
      radiant.events.listen(radiant, 'radiant:client:ui_screen_changed', update_ui_screen)
   end)

return stonehearth
