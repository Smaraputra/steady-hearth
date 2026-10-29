// perf_probe (diagnostic only): load-time marks and the save-load spike.
// Every boot of the UI logs perf_probe:ui_mark lines (module script running, title or game screen
// ready), so stonehearth.log shows when each UI boot finishes. With mods.perf_probe.load_save=<save id>
// the title screen loads that save directly (radiant:client:load_game, the call the load dialog makes
// once the mod list matches), and with mods.perf_probe.exit_after_s=<s> the game exits that long
// after the game screen is ready.
(function () {
   var mark = function (name, detail) {
      radiant.call('perf_probe:ui_mark', name, detail || '');
   };
   var started = Date.now();
   mark('ui_module_loaded', 'page_ms=' + Math.round(performance.now()));

   // Does localStorage survive a UI reload (radiant:reload_browser) and a relaunch? Each boot logs
   // the previous boot's sentinel, then writes its own.
   var storage = null;
   try {
      storage = window.localStorage;
      var previous = storage.getItem('perf_probe_sentinel');
      mark('local_storage', 'previous=' + (previous || 'none'));
      storage.setItem('perf_probe_sentinel', 'boot_' + started);
   } catch (e) {
      storage = null;
      mark('local_storage', 'error=' + e);
   }

   var config = function (key, callback) {
      radiant.call('radiant:get_config', key).done(function (response) {
         callback(response && response[key]);
      });
   };

   // App.getCurrentScreenName() answers 'shell' until the root view's route trace returns, so read
   // the route datastore directly: its first route says which screen this boot is for ('game' after
   // a save load, 'shell' at the title).
   var onScreen = function (screen, route) {
      mark('ui_screen_ready', 'screen=' + screen + '|route=' + route + '|since_module_ms=' +
           (Date.now() - started) + '|page_ms=' + Math.round(performance.now()));

      if (screen === 'shell') {
         config('mods.perf_probe.load_save', function (key) {
            if (!key) {
               return;
            }
            // one load per launch: a token from the launcher, remembered across UI reloads
            config('mods.perf_probe.launch_token', function (token) {
               var marker = key + '@' + (token || 'none');
               if (storage && storage.getItem('perf_probe_load_requested') === marker) {
                  mark('load_skipped', 'already_requested=' + marker);
                  return;
               }
               if (storage) {
                  storage.setItem('perf_probe_load_requested', marker);
               }
               radiant.call('radiant:saved_mods_match_loaded_game', key).always(function (result) {
                  mark('load_requested', 'save=' + key + '|mods_match=' + JSON.stringify(result || {}));
                  radiant.call('radiant:client:load_game', key);
               });
            });
         });
      } else if (screen === 'game') {
         config('mods.perf_probe.exit_after_s', function (value) {
            var seconds = parseFloat(value);
            if (seconds > 0) {
               setTimeout(function () {
                  mark('exit', 'after_s=' + seconds);
                  radiant.call('radiant:exit');
               }, seconds * 1000);
            }
         });
      }
   };

   radiant.call('radiant:get_ui_route_datastore').done(function (o) {
      var seen = false;
      var trace = radiant.trace(o.route_datastore).progress(function (data) {
         var route = data && data.route;
         if (seen || !route) {
            return;
         }
         seen = true;
         if (trace) {
            trace.destroy();
         }
         onScreen(route.split('/')[0], route);
      });
   });
})();
