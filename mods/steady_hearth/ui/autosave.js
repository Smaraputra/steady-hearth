// Steady Hearth: autosave for the base game with an adjustable interval and rotating slots.
//
// The base game saves every 5 minutes into one slot, 'auto_save', shared by every town, so one bad
// save (a crash while saving, a town in a bad state) leaves nothing to go back to. With
// mods.steady_hearth.patches.autosave_rotation on (the default), each autosave goes into a new save
// 'steady_autosave_<time>', and only after it succeeds are the world's older autosaves beyond
// mods.steady_hearth.autosave_slots (default 3) deleted. mods.steady_hearth.autosave_minutes (default 5)
// sets the interval: the base game's 5-minute timer keeps running, and a tick saves only when the chosen
// interval has passed since the last autosave that succeeded. The save dialog gets two selectors beside
// its autosave checkbox to set both. Saves of other worlds, the base 'auto_save' slot and manual saves
// are never touched. The id prefix differs from 'auto_save' because ACE's save list prunes every id
// that starts with it. With ACE loaded none of this runs: ACE has its own interval and slots.
(function () {
   var PREFIX = 'steady_autosave_';
   var MINUTE_CHOICES = [5, 10, 15, 20, 30];
   var SLOT_CHOICES = [1, 2, 3, 5, 10];
   var KEYS = {
      enabled: 'mods.steady_hearth.patches.autosave_rotation',
      minutes: 'mods.steady_hearth.autosave_minutes',
      slots: 'mods.steady_hearth.autosave_slots',
   };
   var settings = { minutes: 5, slots: 3 };
   var lastAutosave = Date.now();   // the interval counts from the start of this UI session

   var nearest = function (value, choices, fallback) {
      var number = parseInt(value, 10);
      if (isNaN(number)) {
         return fallback;
      }
      var best = choices[0];
      $.each(choices, function (i, choice) {
         if (Math.abs(choice - number) < Math.abs(best - number)) {
            best = choice;
         }
      });
      return best;
   };

   var getConfig = function (key) {
      return radiant.call('radiant:get_config', key).then(function (response) {
         return response ? response[key] : undefined;
      });
   };

   // A world's autosaves carry its key in their save metadata (steady_hearth_world): the world seed
   // (kept in the world generation service's saved state) and the town name. Pruning matches that key
   // alone, so two worlds whose towns share a name never prune each other, and a save without the key
   // (manual saves, the base 'auto_save', another world) is never deleted. Renaming the town starts a
   // new chain and leaves the old one as it is.
   var worldKey = function () {
      return radiant.call_obj('stonehearth.world_generation', 'get_world_seed_command').then(function (response) {
         return String(response && response.seed) + '|' + (App.stonehearthClient.settlementName() || '');
      });
   };

   // the world's autosaves beyond the newest `keep`, once the new save is listed
   var prune = function (newId, key, keep) {
      radiant.call('radiant:client:get_save_games').done(function (saves) {
         if (!saves || !saves[newId]) {
            return;
         }
         var mine = [];
         radiant.each(saves, function (id, save) {
            var info = save && save.gameinfo;
            if (id.indexOf(PREFIX) === 0 && info && info.steady_hearth_world === key) {
               mine.push({ id: id, timestamp: info.timestamp || 0 });
            }
         });
         mine.sort(function (a, b) {
            return b.timestamp - a.timestamp;
         });
         $.each(mine.slice(keep), function (i, save) {
            if (save.id !== newId) {
               radiant.call('radiant:client:delete_save_game', save.id);
            }
         });
      });
   };

   // App.SaveView._saveGame's save call (stonehearth/ui/game/save_view/save_view.js), with the
   // autosave name and the world key added to the metadata
   var saveGame = function (id, key) {
      var d = new Date();
      return radiant.call('radiant:client:save_game', id, {
         name: i18n.t('stonehearth:ui.game.save_view.auto_save_prefix'),
         town_name: App.stonehearthClient.settlementName(),
         game_date: App.gameView.getDateTime(),
         timestamp: d.getTime(),
         time: d.toLocaleString(),
         jobs: {
            crafters: App.jobController.getNumCrafters(),
            workers: App.jobController.getNumWorkers(),
            soldiers: App.jobController.getNumSoldiers(),
         },
         steady_hearth_world: key,
      });
   };

   var saving = false;

   // saves into a new id, never one that exists; sent() runs once the save request is on its way
   // (or nothing will be saved), so the caller can resume the game after it, as the base game does
   var autosave = function (saveView, sent) {
      // the same guard as the save dialog's own save action: no autosave while another save
      // operation is running
      if (saving || saveView.get('opInProgress')) {
         sent();
         return;
      }
      saving = true;
      $.when(worldKey(), radiant.call('radiant:client:get_save_games'))
         .done(function (key, saves) {
            var id = PREFIX + Date.now();
            while (saves && saves[id]) {
               id = id + '_';
            }
            var keep = settings.slots;
            saveView._showSaveModal();
            saveGame(id, key)
               .done(function () {
                  // the interval counts from the last autosave that succeeded
                  lastAutosave = Date.now();
                  prune(id, key, keep);
               })
               .always(function () {
                  saving = false;
                  saveView._hideSaveModal();
                  saveView.refreshSavesList(true);
               });
            sent();
         })
         .fail(function () {
            saving = false;
            sent();
         });
   };

   // App.RootController._autoSave, called by the base game's 5-minute timer on the host, with the
   // same checks (autosave checkbox on, Esc menu closed) and the same pause around the save request
   var rotatingAutoSave = function () {
      var saveView = App.stonehearthClient.getSaveView();
      var enabled = saveView.get('auto_save');
      var escMenuView = App.gameView ? App.gameView.getView(App.StonehearthEscMenuView) : null;
      var escMenuVisible = escMenuView ? (!escMenuView.isDestroyed && !escMenuView.isDestroying) : false;

      // the timer ticks every 5 minutes, so allow half a minute of drift
      if (!enabled || escMenuVisible || Date.now() - lastAutosave < settings.minutes * 60000 - 30000) {
         return;
      }
      radiant.call('stonehearth:dm_pause_game')
         .done(function () {
            autosave(saveView, function () {
               radiant.call('stonehearth:dm_resume_game');
            });
         });
   };

   var addSelect = function (container, id, label, choices, current, format, key) {
      var select = $('<select>').attr('id', id);
      $.each(choices, function (i, choice) {
         $('<option>').attr('value', choice).text(format(choice)).appendTo(select);
      });
      select.val(String(current));
      select.on('change', function () {
         var value = parseInt(select.val(), 10);
         settings[key] = value;
         radiant.call('radiant:set_config', KEYS[key], value);
      });
      container.append($('<label>').attr('for', id).text(label)).append(select);
   };

   // two selectors beside the save dialog's autosave checkbox
   var addControls = function (view) {
      var setting = view.$('#autoSaveSetting');
      if (!setting || !setting.length || setting.find('#steadyAutoSave').length) {
         return;
      }
      var container = $('<span>').attr('id', 'steadyAutoSave');
      addSelect(container, 'steadyAutoSaveMinutes',
         i18n.t('steady_hearth:ui.autosave.every', { defaultValue: 'every' }),
         MINUTE_CHOICES, settings.minutes, function (n) {
            return i18n.t('steady_hearth:ui.autosave.minutes', { value: n, defaultValue: n + ' min' });
         }, 'minutes');
      addSelect(container, 'steadyAutoSaveSlots',
         i18n.t('steady_hearth:ui.autosave.keep', { defaultValue: 'keep' }),
         SLOT_CHOICES, settings.slots, function (n) {
            return i18n.t('steady_hearth:ui.autosave.saves', { value: n, defaultValue: n === 1 ? '1 save' : n + ' saves' });
         }, 'slots');
      setting.append(container);
   };

   var install = function () {
      App.RootController.proto()._autoSave = rotatingAutoSave;
      App.SaveView.reopen({
         didInsertElement: function () {
            this._super();
            addControls(this);
         },
      });
      // a save view built before this ran gets its controls when it is next shown
      var existing = App.stonehearthClient && App.stonehearthClient._saveMenu;
      if (existing && existing.$()) {
         addControls(existing);
      }
   };

   // ACE is loaded when any loaded manifest belongs to its namespace (checked by key and by
   // info.namespace, so the check does not depend on how the engine keys the list)
   var aceLoaded = function (manifests) {
      var found = false;
      radiant.each(manifests || {}, function (key, data) {
         if (String(key).indexOf('stonehearth_ace') >= 0 || (data && data.info && data.info.namespace === 'stonehearth_ace')) {
            found = true;
         }
      });
      return found;
   };

   radiant.call('radiant:get_loaded_manifests').done(function (manifests) {
      if (aceLoaded(manifests)) {
         return;
      }
      $.when(getConfig(KEYS.enabled), getConfig(KEYS.minutes), getConfig(KEYS.slots))
         .done(function (enabled, minutes, slots) {
            if (enabled === false || enabled === 'false') {
               return;
            }
            settings.minutes = nearest(minutes, MINUTE_CHOICES, 5);
            settings.slots = nearest(slots, SLOT_CHOICES, 3);
            install();
         });
   });
})();
