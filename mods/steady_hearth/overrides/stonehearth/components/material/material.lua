
local Material = class()   -- steady_hearth: changed copy, every base line keeps its number; see the end of the file

local log = radiant.log.create_logger('material')

local SUBSETS_CACHE = {}
local NUM_SUBPARTS = {}; local steady_hearth_generate   -- steady_hearth: set at the end of the file

local generate_subset_cache = function(hash, mat_parts) if steady_hearth_generate and steady_hearth_generate(hash, mat_parts) then return end   -- steady_hearth:
   local num_subparts = 0
   local material_subsets = {}

   local array_indices = {}
   for i = 1, #mat_parts do
      table.insert(array_indices, i)
   end
   local all_sets = radiant.util.power_set(array_indices)

   for _, set in pairs(all_sets) do
      local concat = ''
      table.sort(set)
      for _, index in pairs(set) do
         concat = concat .. '+' .. mat_parts[index]
      end
      material_subsets[radiant.util.hash_str(concat)] = true
      num_subparts = num_subparts + 1
   end
   NUM_SUBPARTS[hash] = num_subparts
   SUBSETS_CACHE[hash] = material_subsets
end

-- material string looks like 'portal', or 'wood food resource'
function Material:__init(material_string)
   self._hash = 0
   self._num_subparts = 0
   self.material_subsets = {} -- accessed directly by inventory's filter functions!!
   self.material_subsets_list = {}
   self._material_string = material_string or ''

   if self._material_string == '' then
      return
   end

   local mat_parts = {}
   if radiant.util.is_string(material_string) then
      material_string = radiant.util.split_string(material_string)
   end
   for _, tag in ipairs(material_string) do
      table.insert(mat_parts, tag)
   end

   table.sort(mat_parts)

   local concat = ''
   for _, s in ipairs(mat_parts) do
      concat = concat .. '+' .. s
   end
   self._hash = radiant.util.hash_str(concat)

   if not SUBSETS_CACHE[self._hash] then
      generate_subset_cache(self._hash, mat_parts)
   end
   
   self.material_subsets = SUBSETS_CACHE[self._hash]
   self.material_subsets_list = radiant.keys(self.material_subsets)  -- In filter functions, we iterate over these, so also make an array for faster access.
   self._num_subparts = NUM_SUBPARTS[self._hash]
end

function Material:get_num_subparts()
   return self._num_subparts
end

function Material:get_id()
   return self._hash
end

function Material:get_string()
   return self._material_string
end

function Material:equals(other_material)
   return self._hash == other_material._hash
end

function Material:contains_all_parts(other_material)
   return rawget(rawget(self, 'material_subsets'), rawget(other_material, '_hash'))  -- hotspot
end

-- steady_hearth: Copy of stonehearth/components/material/material.lua (Stonehearth 1.1.0.949), installed through
-- steady_hearth: Steady Hearth's manifest overrides because the catalog builds its material objects inside
-- steady_hearth: stonehearth's own radiant:init, before Steady Hearth's patch installer runs. Every base line keeps
-- steady_hearth: its line number (the changes on lines 2, 7 and 9 are appended to them), so guards that pin these
-- steady_hearth: functions by source and lines still accept them.
-- steady_hearth:
-- steady_hearth: With mods.steady_hearth.patches.material_subsets_incremental on (the default), a new material
-- steady_hearth: builds its subset table incrementally: the same keys in the same insertion order and the same
-- steady_hearth: count as generate_subset_cache, about five times faster in the engine, which saves about 4 s of
-- steady_hearth: every ACE catalog build (docs/experiments/010). The original runs when the switch is off or when
-- steady_hearth: radiant.util.hash_str or radiant.util.power_set is not the shipped function.
-- steady_hearth:
-- steady_hearth: generate_subset_cache takes every subset of the power set (util.power_set lists subset m, for m
-- steady_hearth: from 1 to 2^n - 1, as the set bits of m), joins its parts in index order with '+', hashes the
-- steady_hearth: string and inserts the hashes in that order. Here a depth-first walk extends each subset's string
-- steady_hearth: by '+' and one later part, carrying only util.hash_str's state: the counter after the string's
-- steady_hearth: full 3-byte chunks, the 0 to 2 bytes after them and the length (hash_str's arithmetic stays exact
-- steady_hearth: below 2^53, and only its last, partial chunk depends on the length). Each subset's hash is stored
-- steady_hearth: by m and inserted in ascending m afterwards, so the table gets the same keys in the same order.
-- steady_hearth: The chunk arithmetic is util.hash_str's.
do   -- steady_hearth:
   local function is_shipped(fn, first, last)   -- steady_hearth:
      local info = type(fn) == 'function' and debug.getinfo(fn, 'S')   -- steady_hearth:
      local source = info and info.source or ''   -- steady_hearth:
      return source:sub(-#'radiant/lib/util.lua') == 'radiant/lib/util.lua'   -- steady_hearth:
         and info.linedefined == first and info.lastlinedefined == last   -- steady_hearth:
   end   -- steady_hearth:

   local fmod, byte, sub = math.fmod, string.byte, string.sub   -- steady_hearth:

   -- steady_hearth: the state of the string extended by '+' .. part
   local function extend(counter, leftover, len, part)   -- steady_hearth:
      local text = leftover .. '+' .. part   -- steady_hearth:
      local text_len = #text   -- steady_hearth:
      local i = 1   -- steady_hearth:
      while i + 2 <= text_len do   -- steady_hearth:
         counter = fmod(counter*8161, 4294967279) +   -- steady_hearth:
            (byte(text,i)*16776193) +   -- steady_hearth:
            (byte(text,i+1)*8372226) +   -- steady_hearth:
            (byte(text,i+2)*3932164)   -- steady_hearth:
         i = i + 3   -- steady_hearth:
      end   -- steady_hearth:
      return counter, sub(text, i), len + text_len - #leftover   -- steady_hearth:
   end   -- steady_hearth:

   -- steady_hearth: util.hash_str of the string: its last, partial chunk starts at len - #leftover + 1
   local function finish(counter, leftover, len)   -- steady_hearth:
      if leftover ~= '' then   -- steady_hearth:
         local i = len - #leftover + 1   -- steady_hearth:
         counter = fmod(counter*8161, 4294967279) +   -- steady_hearth:
            (byte(leftover,1)*16776193) +   -- steady_hearth:
            ((byte(leftover,2) or (len-i+256))*8372226) +   -- steady_hearth:
            ((byte(leftover,3) or (len-i+256))*3932164)   -- steady_hearth:
      end   -- steady_hearth:
      return fmod(counter, 4294967291)   -- steady_hearth:
   end   -- steady_hearth:

   local shipped_hash_str, shipped_power_set, reported   -- steady_hearth:
   local function generate_incremental(hash, mat_parts)   -- steady_hearth:
      -- steady_hearth: a mod that replaces either function after this file loaded gets the original code
      if radiant.util.hash_str ~= shipped_hash_str or radiant.util.power_set ~= shipped_power_set then   -- steady_hearth:
         if not reported then   -- steady_hearth:
            reported = true   -- steady_hearth:
            radiant.log.write_('steady_hearth', 0, 'material_subsets_incremental: radiant.util.hash_str or power_set replaced, using the original')   -- steady_hearth:
         end   -- steady_hearth:
         return false   -- steady_hearth:
      end   -- steady_hearth:
      local n = #mat_parts   -- steady_hearth:
      local hashes = {}   -- steady_hearth:
      local function visit(mask, counter, leftover, len, first)   -- steady_hearth:
         local bit = 2 ^ (first - 1)   -- steady_hearth:
         for j = first, n do   -- steady_hearth:
            local c, l, ln = extend(counter, leftover, len, mat_parts[j])   -- steady_hearth:
            local m = mask + bit   -- steady_hearth:
            hashes[m] = finish(c, l, ln)   -- steady_hearth:
            visit(m, c, l, ln, j + 1)   -- steady_hearth:
            bit = bit * 2   -- steady_hearth:
         end   -- steady_hearth:
      end   -- steady_hearth:
      visit(0, 1, '', 0, 1)   -- steady_hearth:
      local material_subsets = {}   -- steady_hearth:
      local last = 2 ^ n - 1   -- steady_hearth:
      for m = 1, last do   -- steady_hearth:
         material_subsets[hashes[m]] = true   -- steady_hearth:
      end   -- steady_hearth:
      NUM_SUBPARTS[hash] = last   -- steady_hearth:
      SUBSETS_CACHE[hash] = material_subsets   -- steady_hearth:
      return true   -- steady_hearth:
   end   -- steady_hearth:

   local switch = _host:get_config('mods.steady_hearth.patches.material_subsets_incremental')   -- steady_hearth:
   local state   -- steady_hearth:
   if switch == false or switch == 'false' then   -- steady_hearth:
      state = 'disabled'   -- steady_hearth:
   elseif not is_shipped(radiant.util.hash_str, 75, 85) or not is_shipped(radiant.util.power_set, 60, 72) then   -- steady_hearth:
      state = 'skipped (radiant.util.hash_str or power_set changed)'   -- steady_hearth:
   else   -- steady_hearth:
      shipped_hash_str, shipped_power_set = radiant.util.hash_str, radiant.util.power_set   -- steady_hearth:
      steady_hearth_generate = generate_incremental   -- steady_hearth:
      state = 'on (file override)'   -- steady_hearth:
   end   -- steady_hearth:
   radiant.log.write_('steady_hearth', 0, 'material_subsets_incremental: %s', state)   -- steady_hearth:
end   -- steady_hearth:

return Material
