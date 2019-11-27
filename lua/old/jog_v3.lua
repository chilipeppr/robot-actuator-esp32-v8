-- Stepper Jog for DRV8825
-- This library lets you jog your DRV8825 stepper using variable
-- frequency PWM, but it keeps track of your step counter so you
-- know your final position

local m = {}
-- m = {}

-- Pass in on init
m.motor =  nil --require("jog_v2_drv8825")
-- m.pcnt = nil

-- These pins are set in touchjog_jog_drv8825.lua now
-- m.pinStep = 2 -- GPIO22, pin36 on esp32-wroom-32d, Orig 2
-- m.pinDir = 14 -- pin33 on esp32-wroom-32d, Orig 14
-- m.pinSleep = 0 -- ENN pin28 GPIO17 on esp32-wroom-32d, Orig 15 or 0
-- m.pinPulseIn = 36 --2 -- 36 STEP Pulse In (Sens_VP), Pin 24 (Touch2)

m.bits = 9
m.dutyStart = 0 
m.dutyAtRun = (2^m.bits)/2 --256 -- Since using 9bits 2^9=512, so 256 is 50% duty
m.freqStart = 100

m._freq = 100
m._isOn = false 

m.isDebug = false

m._isInitted = false

-- Pass in config vals in table:
-- {
--   motor = motorObj, -- if you instantiated jog_v2_drv8825 lib on your own
-- }
function m.init(tbl)
  
  if m._isInitted then
    print("jog_v3 already initted")
    return
  end
  
  m._isInitted = true
  
  if tbl ~= nil then
    if tbl.motor ~= nil then m.motor = tbl.motor end
    if tbl.onJogPause ~= nil then m.onJogPause = tbl.onJogPause end
    -- if tbl.pcnt ~= nil then m.pcnt = tbl.pcnt end
  end
  
  m.pinStep = m.motor.pinStep

  -- Start the PWM module, but at duty 0 so like it's off
  -- m.start()
  -- Pause it like what we do on joystick at center pos
  -- m.pause()
  
  print("Initted jog library LEDC pwm generator")

end

function m.round(num, numDecimalPlaces)
  local mult = 10^(numDecimalPlaces or 0)
  return math.floor(num * mult + 0.5) / mult
end

m._lastFreq = 0
m._maxDelta = 20
function m.setfreq(fr, isOverrideAccel)

  if fr < 1 then
    print("Err on freq:", fr)
    return
  end
  
  -- Check last freq and don't let them change too fast
  if isOverrideAccel ~= true then
    
    if fr > m._lastFreq then
      -- they want faster
      if fr - m._lastFreq > m._maxDelta then
        local askedFr = fr
        fr = m._lastFreq + m._maxDelta
        print("Dampened accel from fr:",askedFr,"to fr:",fr)
      end
    elseif fr < m._lastFreq then
      -- they want slower
      if m._lastFreq - fr > m._maxDelta then
        local askedFr = fr
        fr = m._lastFreq - m._maxDelta
        print("Dampened decel from fr:",askedFr,"to fr:",fr)
      end
    end
    
  end
  
  -- print("Setting freq to:", fr)
  pcall(m._channel:setfreq(fr))
  m._lastFreq = fr
end

function m.setduty(duty)
  m._channel:setduty(duty)
  -- print("Set duty:", duty)
end

function m.getFreq()
  return m._channel:getfreq()
end

-- function m.getSteps()
--   local steps = m.pcnt:getCnt()
--   print("Steps: "..steps)
--   return steps
-- end


function m.start()
  m._channel = ledc.newChannel({
    gpio=m.pinStep,
    bits=m.bits,
    mode=ledc.HIGH_SPEED,
    timer=ledc.TIMER_1,
    channel=ledc.CHANNEL_1,
    frequency=m.freqStart, -- Hz
    -- 2^11 = 2048
    -- 2^9 = 512
    duty=m.dutyStart --512 -- 2**10 = 1024, so 50% duty is 512
  });
  m._isOn = true
  print("Start jog LEDC hardware. freq:", m.freqStart, "duty", m.dutyStart)
end

function m.stop()
  m._channel:stop(ledc.IDLE_LOW)
  m._channel = nil
  -- m.setfreq(m.freqStart)
  -- m.setduty(0)
  m._isOn = false
  print("Stopped. Unbind jog LEDC from hardware.")
end

m._isPaused = true
function m.pause()
  if m._isOn == false then return end
  -- m.setfreq(10, true) --override dampening
  m.setduty(0)
  m._isPaused = true
  m.motor.disable()
  print("Paused")
  
  if m.onJogPause ~= nil then
    node.task.post(node.task.LOW_PRIORITY, m.onJogPause)
  end
end

function m.resume()
  if m._isOn == false then return end
  if m._isPaused == false then return end
  m.setduty(m.dutyAtRun)
  m._isPaused = false
  m.motor.enable()
  print("Resumed")
end

function m.jogStart(freq)
  if m._isOn == false then return end

  print("jogStart. freq:", freq)
  -- m.motor.dirFwd()
  m.motor.enable()
  m.setfreq(freq, true) --override dampen
  m.resume()
  -- m.motor.readDRV_STATUS()
end

function m.jogStop()
  if m._isOn == false then return end

  m.pause()
  m.motor.disable()
  -- m.getSteps()
  -- m.motor.readDRV_STATUS()
end 

m.testState = 0 -- 0 is run fwd, 1 is rev, 2 is pause
m.testLastState = nil
m.testFreq = 200
m.testLenMs = 1000
m.testPauseMs = 2000

-- Pass in tbl lenMs, pauseMs, freq
function m.testStart(tbl)
  
  if m._isOn == false then return end

  if tbl.freq ~= nil then m.testFreq = tbl.freq end
  if tbl.lenMs ~= nil then m.testLenMs = tbl.lenMs end
  if tbl.pauseMs ~= nil then m.testPauseMs = tbl.pauseMs end
  
  -- Start test where we jog fwd for 1 second
  -- Then we jog rev for 1 second
  m.jogStart(m.testFreq)
  m._testTmr = tmr.create()
  
  print("Starting out test at lenMs:", m.testLenMs, "pauseMs:", m.testPauseMs, "freq:", m.testFreq)
  m._testTmr:alarm(m.testLenMs, tmr.ALARM_SEMI, function()
    
    -- print("Got tmr. testState:", m.testState, "testLastState:", m.testLastState)

    -- check state
    if m.testState == 0 then
      -- we were just going fwd
      -- we are going to a pause state
      print("We are going to pause for ms:", m.testPauseMs)
      m.testLastState = 0
      m.testState = 2
      m.jogStop()
      m._testTmr:interval(m.testPauseMs)
      
    elseif m.testState == 2 then
      -- we were just on a pause
      -- jog again
      m.motor.dirToggle()
      if m.testLastState == 0 then 
        m.testState = 1 
        print("We are going to jog reverse at freq:", m.testFreq, "for ms:", m.testLenMs)
      elseif m.testLastState == 1 then 
        m.testState = 0 
        print("We are going to jog forward at freq:", m.testFreq, "for ms:", m.testLenMs)
      end
      
      m.jogStart(m.testFreq)
      m._testTmr:interval(m.testLenMs)

    elseif m.testState == 1 then
      -- we were just in rev
      -- we are going to a pause state
      print("We are going to pause for ms:", m.testPauseMs)
      m.testLastState = 1
      m.testState = 2
      m.jogStop()
      m._testTmr:interval(m.testPauseMs)
      
    end
    
    -- restart timer
    m._testTmr:start()
  end)
end 

function m.testStop()
  m.jogStop()
  if m._testTmr then
    local running, mode = m._testTmr:state()
    if running then
      m._testTmr:unregister()
    end
  end
end

-- m.init()
-- m.jogStart(100)
-- m.testStart()
-- localTime = time.getlocal()
-- print(string.format("%02d:%02d:%02d",  localTime["hour"], localTime["min"], localTime["sec"]))

return m

