-- Homing library

local m = {}
-- m = {}

m.jog = nil --require("touch_8pads_jog_ws2812")
m.motor = nil -- require("jog_v2_drv8825")
m.endstop = nil --require("hall_endstop")

m.isDebug = true 

m.cbOnHomingStep = nil 

m._homingFreq = 300             -- step 1 find hall
m._homingFreqBackOff = 30       -- step 2 back off hall
m._homingFreqBackOn = 5        -- step 3 back onto hall
m._homingFreqBackOffFinal = 1  -- step 4 slow back off hall for accuracy

m._microSteps = 1

-- Pass in table of vals
-- {
--   jog = jogObj,
--   motor = motorObj,
--   endstop = endstopObj,
--   cbOnHomingStep = yourfunc(homeStep)
--   microSteps
-- }
function m.init(tbl)
  
  if tbl ~= nil then
    if tbl.isDebug ~= nil then m.isDebug = tbl.isDebug end
    if tbl.jog ~= nil then m.jog = tbl.jog end
    if tbl.motor ~= nil then m.motor = tbl.motor end
    if tbl.endstop ~= nil then m.endstop = tbl.endstop end
    if tbl.cbOnHomingStep ~= nil then m.cbOnHomingStep = tbl.cbOnHomingStep end
    if tbl.microSteps ~= nil then m._microSteps = tbl.microSteps end
  end
  
  -- multiply our frequencies by the microsteps
  m._homingFreq = m._homingFreq * m._microSteps 
  m._homingFreqBackOff = m._homingFreqBackOff * m._microSteps
  m._homingFreqBackOn = m._homingFreqBackOn * m._microSteps    
  m._homingFreqBackOffFinal = m._homingFreqBackOffFinal * m._microSteps  
 
  
end

-- m._isHoming = false
m._homingState = "" -- "fwdFast", "backOff", "fwdSlow"
function m.home(hitOrLeave)

  -- for homing do 3 steps: fwdFast, then backOff, then fwdSlow
  -- this should give us most accurate homing off the hall sensor / magnet

  local ret
  
  if hitOrLeave == nil then
    -- we are being asked to start homing from scratch
    m._homingState = ""
    print("Homing: starting...")
  end
  
  -- we will re-enter this method from onEndstopHit method if homing
  if m._homingState == "" then
    -- we weren't homing, so we can start
    m._homingState = "revFast"
    -- go fwd at reasonable speed
    m.motor.dirRev()
    m.jog.setfreq(m._homingFreq, true)
    m.jog.resume()
    -- will get onHit() callback
    if m.isDebug then print("Homing: revFast") end
  elseif m._homingState == "revFast" then
    -- hit endstop (or left endstop), so got called back,
    -- sometimes, depending on position of the motor
    -- we may have actually been over the hall sensor when starting
    -- homing, so we may get here where we left the sensor, so test for that
    m.jog.pause()

    if (hitOrLeave == "leave") then
      -- if we get here and it was a leave operation, then we were
      -- over the hall sensor at the start, but now we are off of it,
      -- so we have to go forward until we hit the sensor again,
      -- and then we can continue in the backOff step
      -- print("Homing: jump back to over hall")
      m._homingState = "jumpBack"
      m.motor.dirFwd()
      m.jog.setfreq(m._homingFreqBackOff)  -- 10
      m.jog.resume()
      -- will get onHit() callback
    elseif (hitOrLeave == "hit") then
      -- print("We are hovering over the hall sensor. Good. That is where we should be.")
      m._homingState = "overHallSensor"
      if m.isDebug then print("Homing: overHallSensor") end
      -- we need to call ourself back just for cleanliness
      -- we will re-enter the method to correctly handle the next step
      m.home("hit")
      return
    else
      error("Homing: Hit state should not")
    end
    
  elseif m._homingState == "jumpBack" or m._homingState == "overHallSensor" then
    -- so go backward until leaving hall sensor
    -- m.jog.setfreq(0, true) -- stop as fast as we can
    m.jog.pause()
    m._homingState = "backOff"
    -- go rev at slow speed
    m.motor.dirFwd()
    m.jog.setfreq(m._homingFreqBackOff, true)  -- 10
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
    m.jog.setfreq(m._homingFreqBackOn, true)  -- 5
    m.jog.resume()
    if m.isDebug then print("Homing: revSlow") end
  elseif m._homingState == "revSlow" then
    -- now that we went slow to the hall sensor, we stop,
    -- reverse dir, and back off slow as well. that's our actual home.
    m.jog.pause()
    -- we are done now
    m._homingState = "backOff2"
    m.motor.dirFwd()
    m.jog.setfreq(m._homingFreqBackOffFinal, true) -- 2
    m.jog.resume()
    if m.isDebug then print("Homing: backOff2") end
  elseif m._homingState == "backOff2" then
    -- now we are done. we backed off the endstop nicely.
    m.jog.pause()
    m._homingState = "settlePeriod"
    -- m.motor.dirFwd()
    if m.isDebug then print("Homing: settlePeriod") end
    -- ret = "settlePeriod"
    
    -- for the settlePeriod we need to do a timer and a callback
    -- to re-enter this method to go to done state. this is because 
    -- we were seeing a homing where step=1 afterwards due to the 
    -- time it takes the LEDC hardware to stop generating pwm signals
    
    tmr.create():alarm(200, tmr.ALARM_SINGLE, function()
      m.home("tmrCallback")
    end)
  
  elseif m._homingState == "settlePeriod" then
    m._homingState = ""
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