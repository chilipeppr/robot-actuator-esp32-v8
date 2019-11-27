-- RMT TX library for driving a stepper motor

local m = {}
-- m = {}

m.astep = require("accelstepper_v1")

-- the pulsecnt library needs to be passed in during init
-- this lets us read machine coords (pulse count)
m.pcnt = nil

-- the motor (drv8825) library needs to be passed in during init
-- this lets us do fwd/rev
m.motor = nil

m.tx = nil

m.channel = 0 -- make sure to not interfere with other channels being used. 0 to 7.
m.memBlocks = 2
m.memBytes = m.memBlocks * 64 -- size we can send in during initial writeRaw()
m.memBytesHalf = m.memBytes / 2 -- size we can send in during fillRaw

m.clkDiv = 255 
m.nsPerTick = rmttx.getNsPerTickForClkDiv(m.clkDiv)
m.usPerTick = m.nsPerTick / 1000
m.msPerTick = m.usPerTick / 1000

m.minStepperPulse = 2 -- in microseconds. DRV8825 needs 2uS per high and low (4us total)

m.isDebug = false

m.cbOnDone = nil 

-- Pass in a table of values:
-- pinStep: the pin the RMT TX hardware will send steps on
-- pcnt: the pulsecnt library so can get machine coords
-- motor: the motor library so can enable/disable
function m.init(tbl)
  
  if tbl ~= nil then
    if tbl.pinStep ~= nil then m.pinStep = tbl.pinStep end
    if tbl.cbOnDone ~= nil then m.cbOnDone = tbl.cbOnDone end 
    if tbl.pcnt ~= nil then m.pcnt = tbl.pcnt end
    if tbl.motor ~= nil then m.motor = tbl.motor end
  end 

  -- Actually turns on the RMT TX hardware and binds to pinStep
  m.bind()

  -- Start with writeRaw() which we have to give up to 64 bytes
  -- because we asked for memBlocks=1
  -- So, start with 64 rmt items 
  m.astep.initWithCallbacks(m.astep.CALC, nil, nil)
  m.astep.isDebug = false 
  
  m.astep.setMaxSpeed(400*m.motor.microSteps) -- steps per second
  m.astep.setAcceleration(100*m.motor.microSteps) -- The desired acceleration in steps per second

  -- m.sendMove(48)
  
end

-- Unbind. This removes the RMT TX hardware from being attached
-- to the step pin.
m._isBound = false
function m.unbind()
  m.isBound = false
  m.tx = nil
  print("Unbinding RMT TX hardware")
end

function m.bind()
  
  if m.isBound then 
    print("RMT TX hardware alreayd bound")
    return 
  end
  
  m.isBound = true
  m.tx = rmttx.create({
    channel = 0, -- 0 thru 7 supported
    gpio = m.motor.pinStep, -- The GPIO pin to transmit the pulses on
    cb = m.onEvent, -- Callback for loading more data
    clkDiv = 255, -- 100 ns per tick. 80Mhz clock. clkDiv of 255 is 80,000,000/255 = 313,725 Hz = 0.0031875 ms per tick (3187.5 ns)
    memBlocks = m.memBlocks, -- Number of memory blocks to use. Defaults to 1. 8 blocks available.
    enLoop = false, -- Transmit the data items in a loop. memBlocks must fit entire data when looping.
    isDebug = false,
  })
  print("Binding RMT TX hardware")
end

-- Set the max speed in steps per second 
function m.setMaxSpeed(speed)
  m.astep.setMaxSpeed(speed*m.motor.microSteps) -- steps per second
end 

-- Set the acceleration in steps per second 
function m.setAcceleration(accel)
  m.astep.setAcceleration(accel*m.motor.microSteps) -- The desired acceleration in steps per second
end 

-- Absolute move
function m.sendMoveAbs(steps)
  -- get current position, then check it against steps
  -- to calc relative position, then call sendMove()
  local curPos = m.astep.currentPosition()
  local relSteps = steps - curPos
  m.sendMove(relSteps)
end

-- Relative move
function m.sendMove(steps)
  
  print("sendMove:", steps, "microsteps:", m.motor.microSteps)
  m.motor.enable()

  -- set direction
  if steps < 0 then
    m.motor.dirRev()
  else 
    m.motor.dirFwd()
  end

  m.astep.move(steps*m.motor.microSteps)
  
  -- write out our first batch
  local stepData = m.runTo(m.memBytes) -- fill the buffer
  m.tx:writeRawStart(stepData)
  
  -- print("writeRawStart", #stepData/4)
  
  -- write entire block of moves
  -- local stepData = m.runTo(steps) -- fill the buffer
  -- m.tx:writeAsync(stepData)

  -- print("Done initial send")
end

-- This method calls the accel stepper run() method which calculates
-- the next step. We do this over and over for the amount of steps 
-- we were asked to generate or until done with move.
m.isSavedEndMove = false
m.totalDurMs = 0
function m.runTo(maxSteps, isCalcTime)
  
  -- store our RMT tick array here to return to caller
  local t = {}
  local ctr = 0
  
  m.totalDurMs = 0
  
  -- if m.isSavedEndMove then
  --   -- last time in here we saved our end move. use it now.
  --   m.concat(t, {0,0,0,0})
  --   ctr = ctr + 1 
  --   m.isSavedEndMove = false
  --   print("just returning saved end RMT")
  --   -- print("RMT "..(#t/4))
  --   return t
  -- end 

  -- fill the maxSteps, i.e. fill the memory block
  local isRmtEnd = false
  while ctr < maxSteps and isRmtEnd == false do
    ctr = ctr + 1
  
    -- see if we have steps left
    if (m.astep.distanceToGo() ~= 0) then
    
      -- call accel stepper to calc interval for next step
      -- m.astep.run()
      
      local interval = m.astep._stepInterval
      
      -- check to make sure interval is > minStepperPulse
      -- this happens on the last step where the interval is zero 
      -- but we still need to make it step at the end to cap off the move 
      if interval < m.minStepperPulse * 2 then
        interval = m.minStepperPulse * 2 
        print("increased the interval from:"..m.astep._stepInterval.." to "..interval)
      end
  
      -- we get back an interval in microseconds, so convert to ticks 
      -- then divide by 2 since we're doing a 50% duty cycle
      -- meaning half high / half low 
      local dur = math.floor(interval / m.usPerTick / 2)
      
      -- make sure no zero durations here
      -- should not happen though
      if (dur <= 1) then 
        print("got dur <= 1. ERR.")
        dur = 2 
      end
      
      -- make sure we don't overflow our RMT max
      if dur > 32767 then 
        print("got dur > 32767. was: "..dur)
        dur = 32767 
      end 
      
      -- append to our RMT tick data array
      local d = {dur,1,dur,0}
      -- print(sjson.encode(d))
      m.concat(t, d)
      
      -- call accel stepper to calc interval for next step
      m.astep.run()
    
    else
      
      -- just fill with RMT end, or blank data
      isRmtEnd = true
      m.concat(t, {0,0,0,0})
    end 
    
  end
  
  -- see if we are at the end of our move. if we are, 
  -- we need to append an ending RMT indicator of {0,0,0,0}
  -- needed to do this to fill the block or got weird behavior
  -- if isRmtEnd then
  --   -- change the last block item to RMT end 
  --   t[#t-3] = 0
  --   t[#t-2] = 0
  --   t[#t-1] = 0
  --   t[#t] = 0
  -- end

  -- -- see if we are at the end of our move. if we are, 
  -- -- we need to append an ending RMT indicator of {0,0,0,0}
  -- if m.astep._stepInterval == 0 then 
  --   -- we need to check if we are beyond the amount of moves 
  --   -- we are being asked for, otherwise we'll overflow
  --   if ctr >= maxSteps then 
  --     -- yes, we are over. save for next entry.
  --     m.isSavedEndMove = true
  --     print("saving end RMT for next entry")
  --   else
  --   -- print("we are at end of our move")
  --     m.isSavedEndMove = false
  --     m.concat(t, {0,0,0,0})
  --     print("appended end RMT")
  --   end
  -- end
  
  -- for i=1,#t,4 do
  --   print((i+3)/4,t[i],t[i+1],t[i+2],t[i+3])
  -- end
  
  -- print("Doing "..(#t/4).." RMT items")
  -- print("RMT "..(#t/4))
  -- print("steps", #t/4, "m.totalDurMs", m.totalDurMs)
  
  return t
end

m.lastDur = 32767
-- m.cbCtr = 0
function m.onEvent(channel, flag, thres)
  -- if m.cbCtr % 10 == 0 then print(m.cbCtr) end
  -- m.cbCtr = m.cbCtr + 1
  -- print("channel:", channel, "flag:", flag, "thres:", thres)
  
  -- Flag of 2 is threshold event.
  if flag == 2 then
    -- threshold event. we can fill more memory
    -- print("got thres event")
    
    local stepData = m.runTo(m.memBytesHalf) -- fill the buffer
  
    if #stepData > 0 then
      -- write out our next batch
      m.tx:writeRawFill(stepData)
      -- print("writeRawFill", #stepData/4)
    else 
      --print("we got thres, but no data")
    end

    -- You have to fill half of your memBlocks size
    -- memBlocks=1 means we have 64 bytes total, so fill 32 bytes
    -- local data = {}
    -- m.lastDur = m.lastDur - (200 * 32)
    -- if m.lastDur < 5000 then m.lastDur = 5000 end 
    -- local dur = m.lastDur --math.floor(32767/100)
    -- concat(data, {dur,1,dur,0}, m.memBytesHalf)
  
    -- m.tx:fillRaw(data)
  elseif flag == 1 then 
    print("We got done event")
    --m.disable()
    -- print("_maxSpeed", m.astep._maxSpeed)
    -- print("_acceleration", m.astep._acceleration)
    m.getStepCtr()
    -- print("_currentPos:", m.astep._currentPos, "pcnt:", m.pcnt:getCnt())
    -- Poll the pulse counter
    -- print("pcnt:" .. m.pcnt:getCnt())
    
    -- do callback if they asked for one
    if m.cbOnDone ~= nil then
      node.task.post(node.task.MEDIUM_PRIORITY, m.cbOnDone) -- medium priority
    end 
    
  end
end

m.lastDelta = 0
function m.getStepCtr()
  local delta = m.astep._currentPos -  m.pcnt.getMachineCoords() --m.pcnt:getCnt()
  local broadDelta = m.lastDelta - delta
  print("_currentPos:", m.astep._currentPos, "pcnt:", m.pcnt.getMachineCoords(), "delta:", delta, "broadDelta:", broadDelta)
  m.lastDelta = delta
end 

function m.concat(t1,t2,repCnt)
  if repCnt == nil then repCnt = 1 end

  local durMs

  for r=1,repCnt do

    durMs = 0
    
    for i=1,#t2 do
      t1[#t1+1] = t2[i]
      if i == 1 or i == 3 then
        --we are on a duration length
        durMs = durMs + (m.msPerTick * t2[i])
      end
    end

    -- print(sjson.encode(t2),"dur:",durMs)
    m.totalDurMs = m.totalDurMs + durMs

  end
  return t1
end

-- m.init( {pinStep=2, cbOnDone=mycallback} )
-- tx = nil
return m
