-- Actuator Jog Gcode Buttons

local m = {}
-- m = {}

m.led = require("rmttx_ws2812_v2")
m.jog = require("jog_v3")
m.file = require("gcode_file")
m.touch = require("touch_8pads_jog_ws2812")
m.motor = require("drv8825_driver_v1")
m.endstop = require("hall_endstop_v2")
m.homing = require("homing_v1")
m.gcode = require("rmttx_stepper_queue_v4")
m.pcnt = require("pulsecnt_machine")
m.fan = require("fan_temp_ctrl")
-- dofile("fan_temp_ctrl.lc")

-- in case you need to invert direction pin due to wiring differences
-- on stepper motor
m.isInvert = false 

-- if you want the jog frequency to increment in greater/lower amounts
-- during use of the touch dial, default is 10, 
-- try 20, 30, or 40 for faster
-- for finer control use a lower number like 5
m.jogFreqIncrement = 5

-- setup the microsteps. several libraries need this val.
m.microSteps = 4

m.recordedGcodeFreq = 100 * m.microSteps
m.recordedGcodeAcc = 50 * m.microSteps

-- Pass in table of values:
-- isInvert = true -- to invert the direction pin 
function m.init(tbl)
  
  if tbl ~= nil then
    if tbl.isInvert ~= nil then m.isInvert = tbl.isInvert end 
  end
  
  -- init saving and reading of gcode from Flash memory
  m.file.init()
  
  -- init our LED WS2812 library
  m.led.init()
  
  -- init our motor
  m.motor.init({
    isInvert = m.isInvert, -- invert the dirFwd/dirRev (in case your wiring is reversed)
    microSteps = m.microSteps,
    isDebug = false,
  })
  
  -- init pulse counter library
  m.pcnt.init({
    isInvert = m.isInvert, -- invert the dirFwd/dirRev (in case your wiring is reversed)
    pinDir = m.motor.pinDir,
    pinPulseInput = m.motor.pinPulseInput,
    stepLimitMax = 32767,
    stepLimitMin = -32767
  })

  -- init our jogging
  m.jog.init({
    onJogPause = m.onJogPause,
    microSteps = m.microSteps,
    motor = m.motor, -- in case they passed us a drv8825 lib, nil is safe
  })

  -- init jogging. sets up touch pads, freq generator for stepper,
  -- and drv8825 driver
  m.touch.init({
    jogFreqIncrement = m.jogFreqIncrement, -- ask for touch dial speed
    cbOnCenterBtnTouch=m.onCenterBtnTouch,
    jog = m.jog,
    led = m.led,
    microSteps = m.microSteps,
    isDebug=false
  })
  m.touch.config() -- sets thresholds on pads. don't touch pads during config.
  
  -- init the endstop library
  m.endstop.init({
    onHit = m.onEndstopHit,
    onLeave = m.onEndstopLeave,
    isDebug = false
  })

  -- init the homing library
  m.homing.init({
    motor = m.motor,
    jog = m.jog,
    endstop = m.endstop,
    cbOnHomingStep = m.onHomingStep,
    microSteps = m.microSteps,
    isDebug = false,
  })

  -- init the gcode library which lets us send via RMT hardware the steps
  -- this does bind the RMT hardware to the step GPIO
  -- so need to toggle back jog GPIO
  m.gcode.init({
    cbOnMoveDone = m.onGcodeMoveDone,
    pcnt = m.pcnt,
    motor = m.motor,
    microSteps = m.microSteps,
  })

  -- ok, now that we have the jogging library and gcode library initted
  -- we have to map the step pin to allow inputs from ledc and rmttx
  -- the rmttx is in control right now because it was last instantiated
  

  -- m.gcode.runGcodeAbs({step=100})
  
  -- even though no gcode playing, stop it so that it starts jog listening
  m.gcodeStop()

  -- Home the actuator
  m.homing.home()
  
end

function m.sendStat(isUdp)
  if cayenn ~= nil and cayenn.myip ~= nil and cayenn._tcpClientIp ~= nil and stat ~= nil then
    if isUdp then
      stat.sendUdp()
    else
      stat.send()
    end
  end
end

-- This method lets you understand what the machine state is 
-- You can pivot off of this data to know when/what is allowed
function m.getState()
  local state = {
    State = "",
    -- SubState = "",
    IsJoggingAllowed = false,
    IsGcodeAllowed = false,
    IsHomingAllowed = false,
  }
  
  if m._isGcodePlaying then
    state.State = "GcodePlaying"
    state.IsGcodeAllowed = true
    state.Freq = m.gcode.rmtstep.getSpeed()
  elseif m.homing.getState() ~= "" then
    state.State = "Homing"
    state.SubState = m.homing.getState()
    state.Freq = m.jog.getFreq()
  elseif m.jog._isPaused == false then
    state.State = "Jogging"
    state.Freq = m.jog.getFreq()
    state.IsJoggingAllowed = true 
  else 
    state.State = "Idle"
    state.IsJoggingAllowed = true 
    state.IsGcodeAllowed = true 
    state.IsHomingAllowed = true
  end
  return state
end

function m.onHomingStep(homeStep)
  m.printCoords()
  print("Home step:", homeStep)
  
  if homeStep == "done" then
    m.led.blink(0,0,255, 30,0,30)
    -- m.sendStat()
   
    -- Now that we are done homing, we have to ZeroOut everything
    -- Set machine coords to zero, i.e. pulse counter
    m.pcnt.setMachineCoordsToZero()
    -- Set accel stepper to zero as well
    m.gcode.setMachineCoords(0)
    m.printCoords()
  
  else
    m.led.blink(0,0,40, 0,0,10)
    -- m.sendStat(true) -- as udp (non-guaranteed)
  end
end

function m.onEndstopHit()
  print("Got endstop hit")
  if m.homing.getState() ~= "" then
    -- we were homing, so call the homing method back so it can do next step
    m.homing.home("hit")

  end
    
end

function m.onEndstopLeave()
  print("Got endstop leave")
  if m.homing.getState() ~= "" then
    -- we were homing, so call the homing method back so it can do next step
    local result = m.homing.home("leave")
    
    
    
  end
end

-- Get callback on center button touched
-- event:0 is touch, event:1 is untouch
-- Return true to preventDefault
function m.onCenterBtnTouch(event, usec)
  print("Got onCenterBtnTouch. event:", event, "usec:", usec)
  
  if event == 0 then
    print("Got center btn touch")
  elseif event == 1 then
    
    local secs = usec / 1000000
    print("Got center btn untouch. secs:", secs, "usec:", usec)
    
    -- see if they long press for more than 10 or 4 seconds
    -- 10 secs wipe gcode
    -- 4 secs record position
    if secs > 12 then
      
      -- do homing
      m.homing.home()
      
    elseif secs > 6 then
      
      m.wipeGcode()
      
    elseif secs > 3  then
      
      m.recordGcode()
      
    elseif secs > 1 then
      
      m.toggleGcodePlayStop()
      
    else
      print("Short tap. Does nothing for now.")
    end
    
  end
end

function m.toggleGcodePlayStop()
  if m._isGcodePlaying then
    print("Asking to stop playing Gcode")
    -- m.gcodeStop()
    m.gcodeAskForStop()
  else
    print("Start playing Gcode")
    m.gcodePlay()
  end
end

function m.recordGcode()
  -- blink green to indicate record
  m.led.blink(255,255,0, 30,0,30)
  
  local gcode = {
    Step=m.pcnt.getMachineCoords(),
    -- fr=m.recordedGcodeFreq,
    -- acc=m.recordedGcodeAcc,
  }
  m.file.write(gcode)
  print("Recording Gcode:", sjson.encode(gcode))
  m.sendStat(true) -- as udp
end

function m.wipeGcode()
  -- go red to indicate wipe
  m.led.blink(255,0,0, 30,0,30)
  m.file.wipe()
  print("Wiped Gcode")
end

function m.printCoords()
  print("Coords. Pcnt:", m.pcnt.getMachineCoords(), "RmtStep:", m.gcode.getMachineCoords())

  -- m.sendStat()
  
end

function m.onJogPause()
  print("Got onJogPause")
  -- we have to update the gcode library that we are at a different position
  m.gcode.setMachineCoords(m.pcnt.getMachineCoords())
  m.printCoords()
  
  -- if homing, send udp, otherwise send tcp
  if m.getState().State == "Homing" then
    m.sendStat(true) -- as udp
  else
    m.sendStat()
  end

end

m._isNonFileMove = false
m._nonFileMove = nil
-- m.gcodeRunOneMove({step=10, fr=200, acc=100})
function m.gcodeRunOneMove(move)
  m._isNonFileMove = true
  m._nonFileMove = move
  m.gcodePlay()
end

function m.gcodeGetNext()
  if m._isNonFileMove then
    -- if entering here with nil move, then it's 2nd re-entrant, which means we're done
    -- so set _isNonFileMove to false
    if m._nonFileMove == nil then m._isNonFileMove = false end
    -- set to nil for so next time re-entering this method we can recognize the step
    local move = m._nonFileMove
    m._nonFileMove = nil 
    return move
  else 
    return m.file.getNext()
  end
end

function m.gcodePlay()
  m._isGcodePlaying = true
  m._isAskedForStop = false
  
  -- show green on led as playing gcode
  m.led.blink(0,255,0, 0,100,0)
  
  -- make sure jogging is off and rebind gcode lib
  m.jog.stop()
  m.gcode.rmtstep.bind()
  
  -- read a line, insert to queue, play the queue
  -- get callback of onGcodeMoveDone() when line done playing
  -- so we can get next
  m.file.close()
  m.file.openRead()
  local qItem = m.gcodeGetNext() --m.file.getNext()
  if qItem ~= nil then
    -- we have a line
    -- if qItem.Fr == nil then qItem.Fr=m.recordedGcodeFreq end
    -- if qItem.Acc == nil then qItem.Acc=m.recordedGcodeAcc end
    m.gcode.runGcodeAbs(qItem)
  else
    print("There was no Gcode to play")
    m.gcodeStop()
  end
end

m._isAskedForStop = false
function m.gcodeAskForStop()
  m._isAskedForStop = true
end

function m.gcodeStop()
  m._isGcodePlaying = false
  m.motor.disable()
  
  -- go purple bright, then purple dim
  m.led.blink(255,0,255, 30,0,30)
  
  -- unbind gcode lib RMT hardware from pinStep
  -- rebind jogging LEDC pwm generator to pinStep
  m.gcode.rmtstep.unbind()
  m.jog.start()

end

function m.onGcodeMoveDone()
  print("Got onGcodeMoveDone")
  m.led.blink(0,30,0, 0,100,0)
  m.printCoords()
  m.sendStat()
  
  if m._isAskedForStop then
    -- don't do next line
    print("User asked to stop gcode, so stopping.")
    m.gcodeStop()
    return
  end
  
  -- do next line
  local qItem = m.gcodeGetNext()
  if qItem ~= nil then
    -- we have a line
    m.gcode.runGcodeAbs(qItem)
  else
    print("Done playing gcode")
    m.gcodeStop()
  end
end

-- m.init()

return m