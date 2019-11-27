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

m._microSteps = 1

m._maxFr = 400
m._maxAcc = 100
m._defaultFr = 400
m._defaultAcc = 100 

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
    if tbl.microSteps ~= nil then m._microSteps = tbl.microSteps end
    if tbl.maxFr ~= nil then m._maxFr = tbl.maxFr end 
    if tbl.maxAcc ~= nil then m._maxAcc = tbl.maxAcc end
    if tbl.defaultFr ~= nil then m._defaultFr = tbl.defaultFr end 
    if tbl.defaultAcc ~= nil then m._defaultAcc = tbl.defaultAcc end
  end 

  -- Actually turns on the RMT TX hardware and binds to pinStep
  m.bind()

  -- Start with writeRaw() which we have to give up to 64 bytes
  -- because we asked for memBlocks=1
  -- So, start with 64 rmt items 
  m.astep.initWithCallbacks(m.astep.CALC, nil, nil)
  m.astep.isDebug = false 
  
  m.astep.setMaxSpeed(m._defaultFr) -- steps per second
  m.astep.setAcceleration(m._defaultAcc) -- The desired acceleration in steps per second

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
    enOutputIdle = false,
    idleLvl = 0,
    isDebug = false,
  })
  print("Binding RMT TX hardware")
end

-- Current speed during accel/decel or continuous
function m.getSpeed()
  return m.astep._speed
end 

-- Current maximum speed on gcode move, may not be actual speed during accel/decel
function m.getMaxSpeed()
  return m.astep._maxSpeed
end 

-- Set the max speed in steps per second 
function m.setMaxSpeed(speed)
  m.astep.setMaxSpeed(speed) -- steps per second
end 

-- Set the acceleration in steps per second 
function m.setAcceleration(accel)
  m.astep.setAcceleration(accel) -- The desired acceleration in steps per second
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
  
  print("sendMove:", steps, "fr:", m.astep.maxSpeed(), "acc:", m.astep._acceleration)
  m.getStepCtr()
  m.motor.enable()

  -- set direction
  if steps < 0 then
    m.motor.dirRev()
  else 
    m.motor.dirFwd()
  end

  m.astep.move(steps)
  
  -- write out our first batch
  -- This will call writeRawFill() to fill the memBlocks fully
  m.runTo(m.memBytes, true) -- fill the buffer, specify isStart
  
  -- Now start the RMT sending. This sets up interrupt for
  -- callbacks, threshold event, and starts the send.
  m.tx:writeRawFillStart()
  
  -- print("Done initial send")
end

-- This method calls the accel stepper run() method which calculates
-- the next step. We do this over and over for the amount of steps 
-- we were asked to generate or until done with move.
m.isSavedEndMove = false
m.totalDurMs = 0
m.isRmtEndSentYet = false
function m.runTo(maxSteps, isStart)
  
  -- Fill our RMT tick array with our step moves
  local ctr = 0
  
  m.totalDurMs = 0
  
  -- local d = {duration0=0,level0=0,duration1=0,level1=0}
  local d = {0,0,0,0}
  
  -- fill the maxSteps, i.e. fill the memory block
  local isRmtEnd = false
  while ctr < maxSteps and isRmtEnd == false do
    ctr = ctr + 1
  
    -- see if we have steps left
    if (m.astep.distanceToGo() ~= 0) then
    
      -- print("we have more distanceToGo:", m.astep.distanceToGo())
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
      d[1] = dur    -- duration0
      d[2] = 1      -- level0
      d[3] = dur    -- duration1
      d[4] = 0      -- level1
      
      if isStart then
        -- if this is a starting fill, need to set offset to 0
        m.tx:writeRawFill(d, 0)
        isStart = false
        -- print("rawFill at offset 0. d:", sjson.encode(d))
      else
        m.tx:writeRawFill(d)
        -- print("rawFill. d:", sjson.encode(d))
      end
      
      -- call accel stepper to calc interval for next step
      m.astep.run()
    
    else
      
      -- print("We have no more distanceToGo(). Sending RMT end.")
      
      -- just fill with RMT end, or blank data
      isRmtEnd = true
      
      d[1] = 0
      d[2] = 0
      d[3] = 0
      d[4] = 0
      
      if isStart then
        -- if this is a starting fill, need to set offset to 0
        m.tx:writeRawFill(d, 0)
        print("Wrote RMT end at offset 0. Rare??? d:", sjson.encode(d))
        isStart = false
      else
        m.tx:writeRawFill(d)
        -- print("Wrote RMT end. d:", sjson.encode(d))
      end
      -- m.concat(t, {0,0,0,0})

    end 
    
  end
  
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
    
    -- local stepData = m.runTo(m.memBytesHalf) -- fill the buffer
    -- Call runTo() where it writes teh data on its own
    m.runTo(m.memBytesHalf) -- fill the buffer
  
    -- if #stepData > 0 then
    --   -- write out our next batch
    --   m.tx:writeRawFill(stepData)
    --   -- print("writeRawFill", #stepData/4)
    -- else 
    --   --print("we got thres, but no data")
    -- end

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
