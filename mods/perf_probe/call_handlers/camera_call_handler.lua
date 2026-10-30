-- perf_probe (diagnostic only): place the game camera, to take in-game screenshots for the Workshop
-- page through the save screenshot (a save writes screenshot.png from the current camera).
-- perf_probe:camera(x, y, z, tx, ty, tz) moves the camera to (x, y, z) and turns it to look at
-- (tx, ty, tz), through the client camera service, as its own controllers do.
local Point3 = _radiant.csg.Point3

local CameraCallHandler = class()

function CameraCallHandler:camera(session, response, x, y, z, tx, ty, tz)
   local ok, err = pcall(function()
      stonehearth.camera:set_position(Point3(x, y, z))
      stonehearth.camera:look_at(Point3(tx, ty, tz))
   end)
   response:resolve({ ok = ok, error = err and tostring(err) })
end

return CameraCallHandler
