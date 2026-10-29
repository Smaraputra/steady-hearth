-- ACE titles: no error for players without a connected client (finding X7).
--
-- TitlesComponent:add_title compares tonumber(<client gameplay setting>) with a number. A player
-- without a connected client (AI towns, other players in multiplayer) has no gameplay settings, so
-- the setting is nil and the comparison raises "attempt to compare nil with number" every time one
-- of that player's citizens earns a title. The title itself is already recorded at that point; only
-- the new-title bulletin follows. This copy is identical except that it skips the bulletin when the
-- threshold setting is missing (there is no client to show it to).
local function add_title(self, title, rank)
   if not self:has_title(title, rank) then
      rank = rank or 1
      self._sv.titles[title] = rank
      self._sv.latest_title = title
      self._sv.renown = self._sv.renown + (self:_get_title_renown(title, rank) - (self:_get_title_renown(title, (rank - 1)) or 0))
      self.__saved_variables:mark_changed()

      -- even if we're not selecting a new title now, we need to ensure that the entity has a custom name
      local unit_info = self._entity:add_component('stonehearth:unit_info')
      unit_info:ensure_custom_name()

      -- update component info details
      self:_update_component_info()

      self:_select_new_title(nil, title)

      local player_id = self._entity:get_player_id()
      if stonehearth.client_state:get_client_gameplay_setting(player_id, 'stonehearth_ace', 'show_new_title_notification', true) then
         local threshold = tonumber(stonehearth.client_state:get_client_gameplay_setting(player_id, 'stonehearth_ace', 'new_title_notification_threshold'))
         if threshold and threshold <= self:_get_title_renown(title, rank) then
            self:_show_bulletin(title, rank)
         end
      end
   end
end

return {
   id = 'ace_titles_nil_threshold',
   default_enabled = true,    -- correctness repair: only removes the error path
   target_ace = true,
   module = 'stonehearth_ace.components.titles.titles_component',
   method = 'add_title',
   expect = {
      source_suffix = 'stonehearth_ace/components/titles/titles_component.lua',
      linedefined = 126,
      lastlinedefined = 147,
   },
   replacement = add_title,
}
