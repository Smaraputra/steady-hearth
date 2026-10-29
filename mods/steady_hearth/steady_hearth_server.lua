-- Stonehearth Perf: guarded performance patches for the base game and ACE.
--
-- Every patch replaces one method of one module (patch.module, loaded with radiant.mods.require), of
-- one script loaded by alias (patch.script, the way the AI loads actions), or of a global table
-- (patch.global, a path from _G such as { 'radiant', 'entities' }), optionally following
-- patch.path into the loaded table (a compound action keeps its class in _base_action). A patch may
-- list further methods in patch.also ({ method, expect, replacement } each, on the same target unless
-- the part names its own module, script or global, with path). They are installed together only when
-- every one passes its guard. Instead of replacement, a patch or part may give wrap(original), which
-- builds the replacement around the method its guard accepted. patch.requires lists functions of
-- other modules ({ module, method, expect } each) that the patch copies or calls and that must pass
-- the same guard, without being replaced. patch.superseded_by names an earlier patch in PATCHES that
-- replaces the same method and includes this one's change; while it is installed this one is
-- skipped. A patch is installed only when
--   * its toggle mods.steady_hearth.patches.<id> is true (each patch declares its default),
--   * ACE is loaded when the patch targets ACE code (target_ace = true), not loaded when it targets
--     base code that ACE replaces (target_ace = false); target_ace = nil applies in both cases,
--   * the current method still comes from the expected file and line range (debug.getinfo) and,
--     when the patch pins one, its bytecode checksum (Adler-32 of string.dump) still matches, so a
--     changed base game or ACE version leaves the original in place.
-- Patches install after ACE's monkey patches when ACE is present, otherwise on
-- radiant:required_loaded. No patch adds saved state, so saves stay loadable without the mod.
steady_hearth = {}

local PATCHES = {
   'steady_hearth.patches.ace_plan_navgrid_clip',
   'steady_hearth.patches.ace_plan_clone_empty_bounds',
   'steady_hearth.patches.ace_titles_nil_threshold',
   'steady_hearth.patches.base_chunk_node_working_regions',
   'steady_hearth.patches.task_feeder_worker_removed',
   'steady_hearth.patches.task_feeder_departed_cleanup',
   'steady_hearth.patches.task_feeder_safe_unfeed',
   'steady_hearth.patches.grid_location_trace',
   'steady_hearth.patches.ace_nearby_search_extra_predicate',
   'steady_hearth.patches.ace_restock_shared_nearby_filter',
   'steady_hearth.patches.ace_reconsider_clears_search_caches',
   'steady_hearth.patches.base_anywhere_single_output',
   'steady_hearth.patches.ace_anywhere_single_output',
   'steady_hearth.patches.base_fabricate_single_output',
   'steady_hearth.patches.ace_fabricate_single_output',
   'steady_hearth.patches.base_placement_requests_release',
   'steady_hearth.patches.ace_placement_requests_release',
   'steady_hearth.patches.ipf_search_lease_dispatch',
}

local function log(fmt, ...)
   radiant.log.write_('steady_hearth', 0, fmt, ...)
end

local VERSION = '1.0.0'   -- keep in step with CHANGELOG.md

local function enabled(patch)
   local value = _host:get_config('mods.steady_hearth.patches.' .. patch.id)
   if value == nil then
      return patch.default_enabled
   end
   return value == true or value == 'true'
end

-- Adler-32 without bit operations (Lua 5.1 has none); exact for strings of any length.
local function adler32(s)
   local a, b = 1, 0
   for i = 1, #s do
      a = (a + s:byte(i)) % 65521
      b = (b + a) % 65521
   end
   return b * 65536 + a
end

local function matches(fn, expect)
   if type(fn) ~= 'function' then
      return false, 'not a function'
   end
   local info = debug.getinfo(fn, 'S')
   local source = info.source or ''
   if source:sub(-#expect.source_suffix) ~= expect.source_suffix then
      return false, 'source ' .. source
   end
   if info.linedefined ~= expect.linedefined or info.lastlinedefined ~= expect.lastlinedefined then
      return false, string.format('lines %s-%s', tostring(info.linedefined), tostring(info.lastlinedefined))
   end
   local ok, dump = pcall(string.dump, fn)
   local checksum = ok and adler32(dump) or nil
   if expect.dump_adler32 and checksum ~= expect.dump_adler32 then
      return false, string.format('bytecode checksum %s', tostring(checksum))
   end
   return true, checksum
end

local function resolve_target(spec)
   local target
   if spec.script then
      local ok, loaded = pcall(radiant.mods.load_script, spec.script)
      target = ok and loaded or nil
   elseif spec.global then
      -- normal indexing: radiant may provide its modules through a metatable
      target = _G
      for _, field in ipairs(spec.global) do
         target = type(target) == 'table' and target[field] or nil
      end
   else
      local ok, loaded = pcall(radiant.mods.require, spec.module)
      target = ok and loaded or nil
   end
   for _, field in ipairs(spec.path or {}) do
      target = type(target) == 'table' and target[field] or nil
   end
   return target
end

local function target_name(spec)
   return spec.script or spec.module or table.concat(spec.global or {}, '.')
end

local function install(ace_loaded)
   log('steady_hearth %s: installing patches (%s)', VERSION, ace_loaded and 'ACE loaded' or 'base game')
   local installed = {}
   for _, module_path in ipairs(PATCHES) do
      -- a patch file that fails to load is skipped; it must not stop the patches after it
      local loaded, patch = pcall(require, module_path)
      if not loaded then
         log('patch %s: failed to load (%s)', module_path, tostring(patch))
      elseif not enabled(patch) then
         log('patch %s: disabled', patch.id)
      elseif patch.target_ace ~= nil and patch.target_ace ~= ace_loaded then
         log('patch %s: skipped (needs %s)', patch.id, patch.target_ace and 'ACE' or 'no ACE')
      elseif patch.superseded_by and installed[patch.superseded_by] then
         log('patch %s: superseded by %s', patch.id, patch.superseded_by)
      else
         -- every part names its target (module, script or global, then path) or shares the patch's
         local parts = { { method = patch.method, expect = patch.expect, replacement = patch.replacement,
                           wrap = patch.wrap, target = resolve_target(patch), name = target_name(patch) } }
         for _, part in ipairs(patch.also or {}) do
            local own = part.module or part.script or part.global
            table.insert(parts, { method = part.method, expect = part.expect, replacement = part.replacement,
                                  wrap = part.wrap, target = own and resolve_target(part) or parts[1].target,
                                  name = own and target_name(part) or parts[1].name,
                                  script = own and part.script, path = own and part.path })
         end
         parts[1].script, parts[1].path = patch.script, patch.path
         local ok, why = true, nil
         local checksums = {}
         for _, part in ipairs(parts) do
            if type(part.target) ~= 'table' then
               ok, why = false, part.name .. ': target not found'
               break
            end
            ok, why = matches(part.target[part.method], part.expect)
            if not ok then
               why = part.name .. '.' .. part.method .. ': ' .. why
               break
            end
            table.insert(checksums, tostring(why))
         end
         if ok then
            for _, req in ipairs(patch.requires or {}) do
               local found, req_target = pcall(radiant.mods.require, req.module)
               ok, why = matches(found and type(req_target) == 'table' and req_target[req.method] or nil, req.expect)
               if not ok then
                  why = 'requires ' .. req.module .. '.' .. req.method .. ': ' .. why
                  break
               end
            end
         end
         if ok then
            -- a part gives its replacement directly, or wrap(original) builds it around the method
            -- the guard just accepted
            for _, part in ipairs(parts) do
               local original = part.target[part.method]
               part.target[part.method] = part.replacement or part.wrap(original)
            end
            installed[patch.id] = true
            local methods = {}
            for i, part in ipairs(parts) do
               table.insert(methods, (i == 1 or part.name ~= parts[1].name) and (part.name .. '.' .. part.method) or part.method)
            end
            log('patch %s: installed on %s (original bytecode checksum %s)', patch.id,
                table.concat(methods, '+'), table.concat(checksums, '+'))
            for _, part in ipairs(parts) do
               if part.script then
                  -- the AI loads actions with load_script too; the patch only reaches it if the loader
                  -- caches the script and returns the same table
                  log('patch %s: script cached = %s', patch.id,
                      tostring(resolve_target({ script = part.script, path = part.path }) == part.target))
               end
            end
         else
            log('patch %s: skipped, original changed (%s)', patch.id, why)
         end
      end
   end
end

-- ACE fires its event from its own radiant:required_loaded handler, which may run before or after
-- ours, so listen for it from load time.
local installed = false
radiant.events.listen_once(radiant, 'stonehearth_ace:server:required_loaded', function()
      if not installed then
         installed = true
         install(true)
      end
   end)
radiant.events.listen_once(radiant, 'radiant:required_loaded', function()
      if not installed and not rawget(_G, 'stonehearth_ace') then
         installed = true
         install(false)
      end
   end)

return steady_hearth
