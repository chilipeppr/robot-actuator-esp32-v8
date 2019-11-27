-- Homing library

local m = {}
-- m = {}

m.jog = nil --require("touch_8pads_jog_ws2812")
m.motor = nil -- require("jog_v2_drv8825")
m.endstop = nil --require("hall_endstop")

m.isDebug = false 

m.cbOnHomingStep = nil 

-- Pass in table of vals
-- {
--   jog = jogObj,
--   motor = motorObj,
--   endstop = endstopObj,
--   cbOnHomingStep = yourfunc(homeStep)
-- }
function m.init(tbl)
  
  if tbl ~= nil then
    if tbl.isDebug ~= nil then m.isDebug = tbl.isDebug end
    if tbl.jog ~= nil then m.jog = tbl.jog end
    if tbl.motor ~= nil then m.motor = tbl.motor end
    if tbl.endstop ~= nil then m.endstop = tbl.endstop end
    if tbl.cbOnHomingStep ~= nil then m.cbOnHomingStep = tbl.cbOnHomingStep end
  end
  
end

-- m._isHoming = false
m._homingState = "" -- "fwdFast", "backOff", "fwdSlow"
function m.home()

  -- for homing do 3 steps: fwdFast, then backOff, then fwdSlow
  -- this should give us most accurate homing off the hall sensor / magnet

  local ret
  
  -- we will re-enter this method from onEndstopHit method if homing
  if m._homingState == "" then
    -- we weren't homing, so we can start
    m._homingState = "revFast"
    -- go fwd at reasonable speed
    m.motor.dirRev()
    m.jog.setfreq(200, true)
    m.jog.resume()
    -- will get onHit() callback
    if m.isDebug then print("Homing: revFast") end
  elseif m._homingState == "revFast" then
    -- hit endstop, so got called back,
    -- so go backward until leaving hall sensor
    -- m.jog.setfreq(0, true) -- stop as fast as we can
    m.jog.pause()
    m._homingState = "backOff"
    -- go rev at slow speed
    m.motor.dirFwd()
    m.jog.setfreq(10, true)
    m.jog.resume()
    -- will get onLeave() callback
    if m.isDebug then print("Homing: backOff") end
  elseif m._homingState == "backOff" then
    -- left endstop, so now we can stop the motor, go fwd again slowly,
    -- and when hit endstop are at our final position
    -- m.jog.setfreq(0, true) -- stop as fast as we can
    m.jog.pause()
    m._homingState = "revSlow"
    -- go fwd at slow speed
    m.motor.dirRev()
    m.jog.setfreq(5, true)
    m.jog.resume()
    if m.isDebug then print("Homing: revSlow") end
  elseif m._homingState == "revSlow" then
    -- now that we went slow to the hall sensor, we stop,
    -- reverse dir, and back off slow as well. that's our actual home.
    m.jog.pause()
    -- we are done now
    m._homingState = "backOff2"
    m.motor.dirFwd()
    m.jog.setfreq(2, true)
    m.jog.resume()
    if m.isDebug then print("Homing: backOff2") end
  elseif m._homingState == "backOff2" then
    -- now we are done. we backed off the endstop nicely.
    m.jog.pause()
    m._homingState = ""
    -- m.motor.dirFwd()
    if m.isDebug then print("Homing: done") end
    ret = "done"
  end
  
  if ret ~= "done" then
    ret = m._homingState
  end
  
  if m.cbOnHomingStep ~= nil then
    node.task.post(node.task.LOW_PRIORITY, function()
      m.cbOnHomingStep(ret)
    end)
  end
  -- print("Coords:", m.motor.getMachineCoords())
  
  return ret
end

function m.getState()
  return m._homingState
end

-- m.init()

return m