-- Equivalence test for Steady Hearth's material.lua override (run from the repository root with
-- `lua5.1 tools/tests/lua/material_subsets_test.lua`). Loads the override three times, with the
-- incremental generator on, switched off, and guarded off because radiant.util.hash_str was replaced,
-- and checks that every Material built from a set of pseudo-random tag lists is identical: hash,
-- subset count, subset keys in pairs() order and material_subsets_list order. Then replaces
-- hash_str after loading and checks that new materials match the original code with the replacement.
--
-- radiant.util.power_set and hash_str are the base game's (radiant/lib/util.lua, Stonehearth 1.1.0.949),
-- placed at their shipped lines 60-72 and 75-85 under the chunk name @radiant/lib/util.lua, so the
-- override's guard accepts them as it does in the game.
local OVERRIDE = 'mods/steady_hearth/overrides/stonehearth/components/material/material.lua'

local POWER_SET = [[
function util.power_set(s)
   local t = {{}}
   for i = 1, #s do
      for j = 1, #t do
         t[#t+1] = {s[i],unpack(t[j])}
      end
   end

   if #t > 0 then
      table.remove(t, 1)
   end
   return t
end]]

local HASH_STR = [[
function util.hash_str(text)
  local counter = 1
  local len = string.len(text)
  for i = 1, len, 3 do
    counter = math.fmod(counter*8161, 4294967279) +  -- 2^32 - 17: Prime!
     (string.byte(text,i)*16776193) +
     ((string.byte(text,i+1) or (len-i+256))*8372226) +
     ((string.byte(text,i+2) or (len-i+256))*3932164)
  end
  return math.fmod(counter, 4294967291) -- 2^32 - 5: Prime (and different from the prime in the loop)
end]]

local function util_chunk()
   local source = 'local util = {}' .. string.rep('\n', 59) .. POWER_SET .. '\n\n\n' .. HASH_STR ..
      '\nfunction util.is_string(obj) return type(obj) == "string" end' ..
      '\nfunction util.split_string(str) local t = {} for w in str:gmatch("%S+") do t[#t + 1] = w end return t end' ..
      '\nreturn util\n'
   local util = assert(loadstring(source, '@radiant/lib/util.lua'))()
   local info = debug.getinfo(util.hash_str, 'S')
   assert(info.linedefined == 75 and info.lastlinedefined == 85, 'hash_str fixture lines')
   info = debug.getinfo(util.power_set, 'S')
   assert(info.linedefined == 60 and info.lastlinedefined == 72, 'power_set fixture lines')
   return util
end

-- each copy of the override gets its own globals (radiant, _host, class), as each Lua state does in the game
local function load_material(switch, replace_hash)
   local log = {}
   local env = setmetatable({}, { __index = _G })
   env.radiant = {
      util = util_chunk(),
      log = {
         create_logger = function() return {} end,
         write_ = function(_, _, fmt, ...) log[#log + 1] = string.format(fmt, ...) end,
      },
      keys = function(t)
         local keys = {}
         for k, _ in pairs(t) do
            table.insert(keys, k)
         end
         return keys
      end,
   }
   if replace_hash then
      local hash_str = env.radiant.util.hash_str
      env.radiant.util.hash_str = function(text) return hash_str(text) end
   end
   env._host = { get_config = function(_, key) return switch end }
   env.class = function()
      local c = {}
      return setmetatable(c, { __call = function(cls, ...)
         local o = setmetatable({}, { __index = cls })
         o:__init(...)
         return o
      end })
   end
   local chunk = assert(loadfile(OVERRIDE))
   setfenv(chunk, env)
   return chunk(), log, env
end

-- deterministic tag lists: a linear congruential generator, so every Lua build sees the same input
local seed = 12345
local function rand(n)
   seed = (seed * 1103515245 + 12345) % 2147483648
   return seed % n
end
local function tag()
   local len = rand(5) == 0 and rand(3) or 1 + rand(14)   -- empty, one-, two- and long tags
   local chars = {}
   for i = 1, len do
      chars[i] = string.char(97 + rand(26))
   end
   return table.concat(chars)
end
local cases = { {}, { 'wood' }, { 'a', 'a' }, { '', '' }, { 'wood resource' } }
for _ = 1, 400 do
   local tags = {}
   for i = 1, rand(13) do
      tags[i] = (i > 1 and rand(6) == 0) and tags[rand(i - 1) + 1] or tag()
   end
   cases[#cases + 1] = rand(4) == 0 and table.concat(tags, ' ') or tags
end

local function snapshot(Material, tags)
   local copy = tags
   if type(tags) == 'table' then
      copy = {}
      for i, t in ipairs(tags) do
         copy[i] = t
      end
   end
   local m = Material(copy)
   local keys = {}
   for k in pairs(m.material_subsets) do
      keys[#keys + 1] = string.format('%.0f', k)
   end
   local list = {}
   for i, k in ipairs(m.material_subsets_list) do
      list[i] = string.format('%.0f', k)
   end
   return string.format('%.0f|%.0f|%s|%s', m._hash, m._num_subparts, table.concat(keys, ','), table.concat(list, ','))
end

local on, on_log, on_env = load_material(nil, false)
local off, off_log = load_material(false, false)
local guarded, guarded_log = load_material(nil, true)
assert(on_log[1] == 'material_subsets_incremental: on (file override)', on_log[1])
assert(off_log[1] == 'material_subsets_incremental: disabled', off_log[1])
assert(guarded_log[1]:find('^material_subsets_incremental: skipped'), guarded_log[1])

local failures, subsets = 0, 0
for i, tags in ipairs(cases) do
   local expected = snapshot(off, tags)
   if snapshot(on, tags) ~= expected or snapshot(guarded, tags) ~= expected then
      failures = failures + 1
      if failures <= 5 then
         print('MISMATCH in case ' .. i)
      end
   end
   subsets = subsets + tonumber(expected:match('^[^|]*|(%d+)'))
end
assert(#on_log == 1, 'the incremental generator fell back to the original: ' .. tostring(on_log[2]))

-- a mod that replaces radiant.util.hash_str after the override loaded: new materials must match the
-- original code running with the replacement
local late_off, _, late_off_env = load_material(false, false)
local function plus_one(env)
   local hash_str = env.radiant.util.hash_str
   env.radiant.util.hash_str = function(text) return hash_str(text) + 1 end
end
plus_one(on_env)
plus_one(late_off_env)
local late = { { 'late', 'tags' }, { 'x', 'y', 'z' }, 'one two three four' }
for i, tags in ipairs(late) do
   if snapshot(on, tags) ~= snapshot(late_off, tags) then
      failures = failures + 1
      print('MISMATCH after a late hash_str replacement, case ' .. i)
   end
end
assert(on_log[2] and on_log[2]:find('replaced, using the original'), 'no fallback report after the late replacement')

print(string.format('%d tag lists, %d subsets, %d mismatches', #cases + #late, subsets, failures))
if failures > 0 then
   os.exit(1)
end
