-- Send multiple steps into the RMTTX stepper driver

local m = {}
-- m = {}

m.rmtstep = require("rmttx_stepper_v2")

m.pcnt = nil -- pass in pulsecnt library
m.motor = nil -- pass in motor library

m.fr = 100 -- default feedrate
m.maxFr = 300 -- max speed allowed
m.accel = 100 -- default steps per second
m.maxAccel = 10000 -- max acceleration

m.q = {} -- holds gcode queue

m._cbOnMoveDone = nil -- if you want callback on each move when it's done

-- Pass in table of values:
-- cbOnMoveDone: the callback you get when move is done (per queue item, or after single send)
-- pinStep: the pin the RMT TX hardware will send steps on
-- pcnt: the pulsecnt library so can get machine coords
-- motor: the motor library so can enable/disable
function m.init(tbl)
  
  if tbl ~= nil then
    if tbl.cbOnMoveDone ~= nil then m._cbOnMoveDone = tbl.cbOnMoveDone end 
    if tbl.pcnt ~= nil then m.pcnt = tbl.pcnt end
    if tbl.motor ~= nil then m.motor = tbl.motor end
  end 
  
  m.rmtstep.init({
    cbOnDone = m.onMoveDone,
    pcnt = m.pcnt,
    motor = m.motor,
  })
  
  -- set defaults
  m.rmtstep.setAcceleration(m.accel)
  m.rmtstep.setMaxSpeed(m.fr)
  
  -- Create queue of moves to do in order
  -- m.q = {}
  
  -- m.q[#m.q+1] = {step=100, fr=200}
  -- m.q[#m.q+1] = {step=100, fr=200}

  -- print(sjson.encode(m.q))
  
  -- onNextItem()
end

-- keep track if just doing 1 line of gcode rather than queue
m._lastMoveWasSingleGcode = false

-- Instead of using the queue, you can just pass 1 line
-- You will still get a callback on move done
function m.runGcodeAbs(qItem)
  
  m._lastMoveWasSingleGcode = true
  
  if qItem.fr ~= nil then
    
    local fr = qItem.fr 
    
    -- check if beyond our allowed max feed
    if fr > m.maxFr then fr = m.maxFr end 
    
    m.rmtstep.setMaxSpeed(fr)
    -- print("max speed: "..fr)
  end
  
  if qItem.acc ~= nil then
    local acc = qItem.acc
    if acc > m.maxAccel then acc = m.maxAccel end
    m.rmtstep.setAcceleration(acc)
  end
  
  -- print("step: "..qItem.step)
  -- m.motor.enable()
  m.rmtstep.sendMoveAbs(qItem.step)
end

function m.runGcodeRel()
  print("todo")
end

m.curItem = 0
function m.onNextItem()
  
  if m.isStop then 
    print("User asking us to stop")
    m.motor.disable() -- turn off motor power
    m.isStop = false
    return
  end
  
  m.curItem = m.curItem + 1 
  
  if m.curItem > #m.q then
    print("No more items in queue")
    m.motor.disable()
    -- rs.getStepCtr()
    m.start()
    return
  end
  
  local qItem = m.q[m.curItem]
  if qItem.fr ~= nil then
    
    local fr = qItem.fr 
    
    -- check if beyond our allowed max feed
    if fr > m.maxFr then fr = m.maxFr end 
    
    m.rmtstep.setMaxSpeed(fr)
    -- print("max speed: "..fr)
  end
  
  -- print("step: "..qItem.step)
  m.rmtstep.sendMove(qItem.step)
  
end

function m.start()
  m.curItem = 0 
  m.onNextItem()
end

m.isStop = false
function m.stop()
  m.isStop = true
end

function m.onMoveDone()
  
  print("Got onMoveDone in queue lib")
  
  if m._lastMoveWasSingleGcode == true then
    -- operate a bit differently when one line of gcode
    print("last move was single line of gcode")
    
    -- set to false so clean for re-entrant methods
    -- will get reset to true if they call single line gcode move again
    m._lastMoveWasSingleGcode = false

    -- see if user callback
    if m._cbOnMoveDone ~= nil then
      
      local result = m._cbOnMoveDone()
    end
    
  else
    -- scenario of running in-memory queue
    
    -- see if user callback
    if m._cbOnMoveDone ~= nil then
      
      local result = m._cbOnMoveDone()
      if result == true then 
        -- they wanted to prevent default
        print("Not doing onNextItem(). Call manually.")
      else
        m.onNextItem()
      end
    else
      -- print("Move is done")
      m.onNextItem()
    end
  end
end

-- This sets the accel stepper library to a hard position
-- useful if you jogged using pwm and need to update the library
-- on where you're at
function m.setMachineCoords(steps)
  m.rmtstep.astep.setCurrentPosition(steps)
end

function m.getMachineCoords()
  return m.rmtstep.astep.currentPosition()
end

-- m.init()
-- m.start()

return m
