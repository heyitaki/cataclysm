-- mousejail: supervises the mousejail helper (built from main.swift), which
-- confines the cursor to a game's window while it is frontmost. The helper
-- watches game focus and window geometry itself; this file only starts and
-- stops it, and running it as a Hammerspoon child lets it inherit
-- Hammerspoon's Accessibility grant. cmd+alt+L toggles. A helper that dies
-- abnormally triggers an automatic cursor release, so a crash mid-capture
-- cannot leave the cursor frozen.

local HELPER = hs.configdir .. "/mousejail/mousejail"
local SETTING = "mousejailEnabled"
-- Bundle id of the game to confine the cursor to; nil uses the helper's
-- default (League of Legends's game client).
local BUNDLE = nil

local M = { task = nil, enabled = hs.settings.get(SETTING) ~= false }

local function start()
  if M.task and M.task:isRunning() then return end
  -- Kill any helper orphaned by a previous Hammerspoon exit (it would
  -- double-process every mouse event alongside the new instance) and wait for
  -- it to actually die: cursor association is global last-writer-wins state,
  -- so a dying predecessor's cleanup would undo the successor's capture. The
  -- pattern is anchored so a compiler or editor holding the path in its argv
  -- is not killed too.
  hs.execute("pkill -f '^" .. HELPER .. "( |$)'")
  for _ = 1, 20 do
    if hs.execute("pgrep -f '^" .. HELPER .. "( |$)'") == "" then break end
    hs.timer.usleep(20000)
  end
  local t
  t = hs.task.new(HELPER, function(exitCode, _, stdErr)
    -- a stale callback from a superseded task must not clobber the live one
    if M.task == t then M.task = nil end
    if exitCode ~= 0 then
      -- an abnormal death (crash, SIGKILL) can skip the helper's own cleanup
      -- and leave the cursor disconnected; --release restores it
      hs.task.new(HELPER, nil, { "--release" }):start()
      local detail = (stdErr and #stdErr > 0) and stdErr:gsub("%s+$", "")
          or ("exit code " .. exitCode)
      hs.alert.show("mousejail: " .. detail)
    end
  end, BUNDLE and { BUNDLE } or {})
  if not t or t:start() == false then
    hs.alert.show("mousejail failed to launch")
    return
  end
  M.task = t
end

local function stop()
  if M.task then M.task:terminate() end
  M.task = nil
end

hs.hotkey.bind({ "cmd", "alt" }, "l", function()
  M.enabled = not M.enabled
  hs.settings.set(SETTING, M.enabled)
  if M.enabled then start() else stop() end
  hs.alert.show("mousejail: " .. (M.enabled and "on" or "off"))
end)

local prevShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
  if prevShutdown then prevShutdown() end
  stop()
end

if M.enabled then start() end

return M
