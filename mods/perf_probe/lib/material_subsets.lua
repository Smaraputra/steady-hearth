-- perf_probe (diagnostic only): material subset generation, measured in the engine.
-- `original` is stonehearth/components/material/material.lua's generate_subset_cache with
-- radiant.util.power_set and radiant.util.hash_str (Stonehearth 1.1.0.949), copied verbatim apart
-- from returning its results. `incremental` builds the same table in the same insertion order
-- (the power set lists subset m as the set bits of m): util.hash_str reads 3-byte chunks from the
-- start with exact integer arithmetic (below 2^53), so a subset's hash state extends to the subset
-- with one more, later part; the hashes are stored by m and inserted in ascending m.
local material_subsets = {}

local function power_set(s)
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
end

local function hash_str(text)
  local counter = 1
  local len = string.len(text)
  for i = 1, len, 3 do
    counter = math.fmod(counter*8161, 4294967279) +  -- 2^32 - 17: Prime!
     (string.byte(text,i)*16776193) +
     ((string.byte(text,i+1) or (len-i+256))*8372226) +
     ((string.byte(text,i+2) or (len-i+256))*3932164)
  end
  return math.fmod(counter, 4294967291) -- 2^32 - 5: Prime (and different from the prime in the loop)
end

function material_subsets.original(mat_parts)
   local num_subparts = 0
   local subsets = {}

   local array_indices = {}
   for i = 1, #mat_parts do
      table.insert(array_indices, i)
   end
   local all_sets = power_set(array_indices)

   for _, set in pairs(all_sets) do
      local concat = ''
      table.sort(set)
      for _, index in pairs(set) do
         concat = concat .. '+' .. mat_parts[index]
      end
      subsets[hash_str(concat)] = true
      num_subparts = num_subparts + 1
   end
   return subsets, num_subparts
end

local fmod, byte, sub = math.fmod, string.byte, string.sub

-- the hash state of a joined string extended by '+' .. part: counter after the full 3-byte chunks,
-- the 0 to 2 bytes after them, the length
local function extend(counter, leftover, len, part)
   local text = leftover .. '+' .. part
   local text_len = #text
   local i = 1
   while i + 2 <= text_len do
      counter = fmod(counter*8161, 4294967279) +
         (byte(text,i)*16776193) +
         (byte(text,i+1)*8372226) +
         (byte(text,i+2)*3932164)
      i = i + 3
   end
   return counter, sub(text, i), len + text_len - #leftover
end

local function finish(counter, leftover, len)
   if leftover ~= '' then
      local i = len - #leftover + 1
      counter = fmod(counter*8161, 4294967279) +
         (byte(leftover,1)*16776193) +
         ((byte(leftover,2) or (len-i+256))*8372226) +
         ((byte(leftover,3) or (len-i+256))*3932164)
   end
   return fmod(counter, 4294967291)
end

-- the algorithm Steady Hearth ships (overrides/stonehearth/components/material/material.lua): a
-- depth-first walk carrying the hash state, each subset's hash stored by m and inserted in ascending m
function material_subsets.incremental(mat_parts)
   local n = #mat_parts
   local hashes = {}
   local function visit(mask, counter, leftover, len, first)
      local bit = 2 ^ (first - 1)
      for j = first, n do
         local c, l, ln = extend(counter, leftover, len, mat_parts[j])
         local m = mask + bit
         hashes[m] = finish(c, l, ln)
         visit(m, c, l, ln, j + 1)
         bit = bit * 2
      end
   end
   visit(0, 1, '', 0, 1)
   local subsets = {}
   local last = 2 ^ n - 1
   for m = 1, last do
      subsets[hashes[m]] = true
   end
   return subsets, last
end

-- Material:__init's parts: a string is split on spaces, a table is copied, then both are sorted
function material_subsets.parts_of(material_string)
   local parts = {}
   if type(material_string) == 'string' then
      material_string = radiant.util.split_string(material_string)
   end
   for _, tag in ipairs(material_string or {}) do
      table.insert(parts, tag)
   end
   table.sort(parts)
   return parts
end

-- true when both tables have the same keys in the same pairs() order
function material_subsets.same_order(a, b)
   local ka, kb = next(a), next(b)
   while ka ~= nil or kb ~= nil do
      if ka ~= kb then
         return false
      end
      ka, kb = next(a, ka), next(b, kb)
   end
   return true
end

return material_subsets
