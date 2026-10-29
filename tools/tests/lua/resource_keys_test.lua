-- Test for mods/steady_hearth/patches/resource_keys_common.lua (run from the repository root with
-- `lua5.1 tools/tests/lua/resource_keys_test.lua`): keys_for returns what the original loop over
-- stonehearth.constants.resources returns, in the same order, as a new table on every call; it runs
-- the loop once per uri for items without a stonehearth:material component and every time for items
-- with one.
local calls = 0
_host = { get_config = function() return nil end }
radiant = {
   log = { write_ = function() end },
   entities = {
      -- as radiant/modules/entities.lua: a material component answers for itself, otherwise the
      -- catalog answers by uri (here: the uri's tags contain the material's first word)
      is_material = function(entity, material)
         calls = calls + 1
         local component = entity:get_component('stonehearth:material')
         if component then
            return component.tags:find(material:match('^%S+'), 1, true) ~= nil
         end
         return entity:get_uri():find(material:match('^%S+'), 1, true) ~= nil
      end,
   },
}
stonehearth = { constants = { resources = {} } }
for _, name in ipairs({ 'wood', 'stone', 'clay', 'ore', 'fiber', 'thread', 'gold', 'silver', 'food', 'herb' }) do
   stonehearth.constants.resources[name .. ' resource'] = true
end
package.path = 'mods/?.lua;' .. package.path
local common = dofile('mods/steady_hearth/patches/resource_keys_common.lua')

local function entity(uri, component_tags)
   return {
      get_uri = function() return uri end,
      get_component = function(_, name)
         return name == 'stonehearth:material' and component_tags and { tags = component_tags } or nil
      end,
   }
end

local function original(e)
   local keys = {}
   for material, _ in pairs(stonehearth.constants.resources) do
      if radiant.entities.is_material(e, material) then
         table.insert(keys, material)
      end
   end
   return keys
end

local function same(a, b)
   if #a ~= #b then return false end
   for i = 1, #a do
      if a[i] ~= b[i] then return false end
   end
   return true
end

local failures = 0
local function check(ok, what)
   if not ok then
      failures = failures + 1
      print('FAIL: ' .. what)
   end
end

local uris = { 'mod:wood_log', 'mod:stone_ore_chunk', 'mod:clay_and_wood', 'mod:nothing', 'mod:gold_silver_herb_food' }
for _, uri in ipairs(uris) do
   local e = entity(uri)
   local first = common.keys_for(e)
   calls = 0
   local second = common.keys_for(e)
   check(calls == 0, uri .. ': the second item with the same uri ran the loop again')
   check(first ~= second, uri .. ': two calls returned the same table')
   check(same(first, original(e)) and same(second, first), uri .. ': keys differ from the original loop')
   second[#second + 1] = 'changed by a caller'
   check(same(common.keys_for(e), first), uri .. ': a caller changing its list changed the remembered list')
end

-- an item with a material component takes the original loop every time
local with_component = entity('mod:wood_log', 'stone ore')
calls = 0
local keys = common.keys_for(with_component)
check(calls == 10, 'an item with a material component did not run the original loop')
check(same(keys, original(with_component)), 'material component: keys differ from the original loop')

print(string.format('resource keys: %d failures', failures))
if failures > 0 then
   os.exit(1)
end
