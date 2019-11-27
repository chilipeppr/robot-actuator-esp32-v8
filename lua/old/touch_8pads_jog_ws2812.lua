-- Touch sensor for 8 pads
-- Set threshold to 30% of untouched state
-- Print padNum list per callback

local m = {}
-- m = {}

m.led = nil --require("rmttx_ws2812_200ms")
m.jog = nil --require("jog_v2")

m.pad = {2,3,4,5,6,7,8,9} -- 6=GPIO14

-- set length of timer to trigger untouch event (100ms default)
m.msUntilBtnUntouched = 200

m.jogFreqIncrement = 5 --40
m.jogMaxFreq = 500 --* 8

m._tp = nil -- will hold the touchpad obj
m.padState = 0 -- 0 means untouched

m._isInitted = false

-- Pass in table of vals to init with:
-- {
--   cbOnCenterBtnTouch = yourfunc(event, usec), -- event:0 is touch, event:1 is untouch, usec is delta from touch
--   motor = motorObj, -- in case you did your own drv8825 lib
--   isDebug=false
-- }
function m.init(tbl)
  
  if m._isInitted then
    print("Touch already initted")
    return
  end
  
  m._isInitted = true
  
  if tbl ~= nil then
    if tbl.jogFreqIncrement ~= nil then m.jogFreqIncrement = tbl.jogFreqIncrement end
    if tbl.cbOnCenterBtnTouch ~= nil then m._cbOnCenterBtnTouch = tbl.cbOnCenterBtnTouch end
    -- if tbl.motor ~= nil then m.motor = tbl.motor end
    if tbl.led ~= nil then m.led = tbl.led end
    if tbl.jog ~= nil then m.jog = tbl.jog end
    if tbl.isDebug ~= nil then m.isDebug = tbl.isDebug end
  end
  
  m._tp = touch.create({
    pad = m.pad, -- pad = 0 || {0,1,2,3,4,5,6,7,8,9} 0=GPIO4, 1=GPIO0, 2=GPIO2, ...
    cb = m.onTouch, -- Callback will get Lua table of pads/bool(true) that were touched.
    intrInitAtStart = false, -- Turn on interrupt at start. Default to true. 
    -- thres = 720, -- Defaults to 0. All pads set to this thres. 
    thresTrigger = touch.TOUCH_TRIGGER_BELOW, -- TOUCH_TRIGGER_BELOW or TOUCH_TRIGGER_ABOVE. 
    slope = 4, -- Touch sensor charge / discharge speed, 0-7 where 0 is no slope, 
    lvolt = touch.TOUCH_LVOLT_0V5, -- Touch sensor low reference voltage TOUCH_LVOLT_0V4, 
    hvolt = touch.TOUCH_HVOLT_2V7, -- Touch sensor high reference voltage TOUCH_HVOLT_2V4, 
    atten = touch.TOUCH_HVOLT_ATTEN_1V, -- High ref attenuation TOUCH_HVOLT_ATTEN_0V, 
    isDebug = true
  })

  -- pass in callback so we know when done sending, that
  -- way we can keep track of when to block sending or not
  -- m.led.init(m.onDoneSendingToWs2812)

  -- tp:intrEnable()
  
  -- init our jogging
  -- m.jog.init({
  --   motor = tbl.motor, -- in case they passed us a drv8825 lib, nil is safe
  -- })


  -- Setup the tmr for the callback process
  m._tmr = tmr.create()
  m._tmr:register(m.msUntilBtnUntouched, tmr.ALARM_SEMI, m.onTmr)
  
  -- set color purple
  m.led.set(20, 0, 20)
  
end

-- the color for the ws2812 led when we are on a certain index
m.color = {
  [0] = {255,255,255}, -- white
  [1] = {255,0,0}, 
  [2] = {0,255,0}, 
  [3] = {0,0,255}, 
  [4] = {255,255,0}, 
  [5] = {255,0,255}, 
  [6] = {0,255,255}, 
  [7] = {10,0,0}, 
  [8] = {0,10,0}, 
  [9] = {0,0,10}, 
  [10] = {10,10,0}, 
  [11] = {10,0,10}, 
  [12] = {0,10,10}, 
  [13] = {10,10,10}, 
}

-- We will get a callback every 8ms or so when touched
m.isOn = true
m._curIndex = -1
m._jogFreq = 0
m._padState = 0 -- 0 means untouched
m._isCenterBtnTouched = false
m._centerBtnTouchStartTs = {}  -- keeps track of secs/usecs on start
function m.onTouch(pads)

  if m._padState == 0 then
    -- we just got touched
    m._padState = 1 -- 1 means touched
    m._tmr:start()
    print("Touch: Got touch")
  else -- m._padState == 1
    -- we will get here on successive callbacks while touched
    -- we get them about every 8ms
    -- so reset the tmr so it doesn't timeout yet
    m._tmr:stop()
    m._tmr:start()
  end

  -- debounce here if still sending. we get callbacks so fast, need this
  -- if m.led.isSending then
  --   -- do nothing, ignore touch action
  --   -- print(".")
  --   return
  -- end
  
  -- if center pad, set ws2812 to white and return
  if pads[2] then
    
    if m._isCenterBtnTouched then
      -- we can ignore
    else
      -- it wasn't touched before
      print("Touch: Center btn touched")
      m._centerBtnTouchStartTs.sec, m._centerBtnTouchStartTs.usec = time.get()
      m._isCenterBtnTouched = true
      -- m.isSending = true
      m.led.set(255, 255, 255)
      
      -- do callback if user asked us
      if m._cbOnCenterBtnTouch ~= nil then
        node.task.post(node.task.LOW_PRIORITY, function()
          -- 1 means untouch
          m._cbOnCenterBtnTouch(0)
        end)
      end
      
    end
    
    return
    
  end
  

  -- gets 0 thru 13 (each pad, plus overlap of pads)
  local index = m.getNarrowIndex(pads)
  
  if index == m._curIndex then
    return
  end
  if index == nil then
    -- print("Err. index nil")
    return
  end
  -- print("pads:", pconcat(pads), "index:", index)

  -- set current index
  local lastIndex = m._curIndex
  m._curIndex = index

  -- print(pconcat(pads))
  
  -- set this to true so we don't send again while processing
  -- a previous touch action. we'll get a callback after
  -- the RMT is done sending to the ws2812 that reset this flag to false
  -- m.isSending = true
  
  -- absolute color
  -- local color = m.color[index]
  -- if color == nil then
  --   -- print("Err. no color")
  --   return
  -- end
  -- -- print("color:", sjson.encode(color))
  -- m.led.set(color[1], color[2], color[3])

  -- relative color
  local incr = m.wasIncrOrDecr(lastIndex, index, pads)
  if incr == nil or incr == 0 then
    -- they didn't move or jump was too much
    -- m.isSending = false
    if incr == 0 then
      print("finger didn't move")
    elseif incr == nil then
      print("finger jumped too much")
    end
  elseif incr > 0 then
    m.led.incrementColor()
    
    m._jogFreq = m._jogFreq + m.jogFreqIncrement
    -- print("incr pre-check. freq:", m._jogFreq)
    
    -- if m._jogFreq == 0 then
    --   -- fwd direction
    --   m.jog.motor.dirFwd()
    --   print("jog fwd")
    --   m._jogFreq = 10
    -- end
    
    -- see if have to change motor direction to fwd
    if m._jogFreq > 0 and m.jog.motor._dir ~= m.jog.motor.DIR_FWD then
      m.jog.motor.dirFwd()
      print("jog fwd")
    end

    
    if m._jogFreq > m.jogMaxFreq then m._jogFreq = m.jogMaxFreq end
    print("freq:", m._jogFreq)
    m.jog.setfreq(math.abs(m._jogFreq), true)
    if m.jog._isPaused then m.jog.resume() end
    
  elseif incr < 0 then
    m.led.decrementColor()
    
    m._jogFreq = m._jogFreq - m.jogFreqIncrement
    -- print("decr pre-check. freq:", m._jogFreq)

    -- if m._jogFreq == 0 then 
    --   -- reverse direction
    --   m.jog.motor.dirRev()
    --   print("jog rev")
    --   -- m.jog.pause()
    --   m._jogFreq = -10 
    -- end
    
    -- see if have to change motor direction to fwd
    if m._jogFreq < 0 and m.jog.motor._dir ~= m.jog.motor.DIR_REV then
      m.jog.motor.dirRev()
      print("jog rev")
    end
    
    if m._jogFreq < (m.jogMaxFreq * -1) then m._jogFreq = (m.jogMaxFreq * -1) end
    print("freq:", m._jogFreq)
    m.jog.setfreq(math.abs(m._jogFreq), true)
    if m.jog._isPaused then m.jog.resume() end
    
  else
    print("got state should not")
  end


end

function m.onTmr()
  -- if we get the timer triggered, it means that we timed out
  -- from touch callbacks, so we presume the touch ended
  m._padState = 0
  -- m.jog.pause()
  -- m._jogFreq = 0
  -- m.jog.motor.dirFwd()
  
  -- make last pad indeterminate
  m._curIndex = -1
  
  if m._isCenterBtnTouched then
    -- we have untouch on center button
    m._isCenterBtnTouched = false
    local sec, usec = time.get()
    -- see how long the button was pressed for
    local deltaSec = sec - m._centerBtnTouchStartTs.sec
    local deltaUsec = usec - m._centerBtnTouchStartTs.usec
    
    deltaUsec = deltaUsec + (deltaSec * 1000000)
    print("Touch: Center btn untouched. len of touch usec:", deltaUsec)
    
    -- do callback if user asked us
    if m._cbOnCenterBtnTouch ~= nil then
      node.task.post(node.task.LOW_PRIORITY, function()
        -- 1 means untouch
        m._cbOnCenterBtnTouch(1, deltaUsec)
      end)
    end
  else
    
    -- else it was a jog dial move that ended
    m.startDecelToZero()
    
  end
  
  -- m.isSending = true
  -- set color purple
  m.led.set(20, 0, 20)
  -- m.led.set(0, 0, 0)
    
  print("Touch: Got untouch")
end

function m.startDecelToZero()
  
  -- Setup the tmr for the callback process
  m._tmrDecel = tmr.create()
  m._tmrDecel:register(50, tmr.ALARM_SEMI, function()
    -- on each callback decrease jog speed
    
    -- see if they resumed touching, if so just drop this whole decel
    if m._padState == 1 then
      -- yup, they touched again. give up. this won't start the timer again
      return
    end

    if m._jogFreq < 0 then
      -- we need to add to it
      m._jogFreq = m._jogFreq + m.jogFreqIncrement
    elseif m._jogFreq > 0 then
      -- we need to subtract from it
      m._jogFreq = m._jogFreq - m.jogFreqIncrement
    end
    
    if m._jogFreq == 0 then 
      -- we are done
      print("decel to zero done")
      m.jog.pause()
    else
      -- print("setting freq:", m._jogFreq)
      m.jog.setfreq(math.abs(m._jogFreq), true)
      m._tmrDecel:start()
      
    end
    
  end)
  m._tmrDecel:start()
  
end

-- returns + or - slots so you can know whether incr + or decr - and how much
function m.wasIncrOrDecr(lastIndex, newIndex, pads)
  
  -- print("lastIndex:", lastIndex, "newIndex:", newIndex)
  
  if lastIndex == nil or lastIndex < 0 then
    -- treat as increment
    return 0
  end
  
  if newIndex == nil or newIndex < 0 then
    -- treat as increment
    return 0
  end
  
  local incr = 0
  
  local debugStr = "x"
  if pads ~= nil then
    debugStr = " pad:" .. pconcat(pads) .. " indx:" .. newIndex
  end
  
  if newIndex == lastIndex then
    -- do nothing
  
  -- Layover increment/decrement states
  -- increments
  -- 13 to 0 (1 step)
  -- 13 to 1 (2 step)
  -- 13 to 2 (3 step)
  -- 12 to 13 (1 step) handled by >
  -- 12 to 0 (2 step)
  -- 12 to 1 (3 step)
  -- 11 to 12 (1 step) handled by >
  -- 11 to 13 (2 step) handled by >
  -- 11 to 0 (3 step)
  -- decrements
  -- 0 to 13 (1 step)
  -- 0 to 12 (2 step)
  -- 0 to 11 (3 step)
  -- 1 to 0 (1 step) handled by <
  -- 1 to 13 (2 step) 
  -- 1 to 12 (3 step)
  -- 2 to 1 (1 step) handled by <
  -- 2 to 0 (2 step) handled by <
  -- 2 to 13 (3 step)
  -- 3 to 2
  -- 3 to 1
  -- 3 to 0
  elseif newIndex == 0 and lastIndex == 13 then
    print("increment layover 13 to 0 (1 step)" .. debugStr)
    incr = 1
  elseif newIndex == 1 and lastIndex == 13 then
    print("increment layover 13 to 1 (2 steps)" .. debugStr)
    incr = 2
  elseif newIndex == 2 and lastIndex == 13 then
    print("increment layover 13 to 2 (3 steps)" .. debugStr)
    incr = 3
  elseif newIndex == 0 and lastIndex == 12 then
    print("increment layover 12 to 0 (2 steps)" .. debugStr)
    incr = 2
  elseif newIndex == 1 and lastIndex == 12 then
    print("increment layover 12 to 1 (3 steps)" .. debugStr)
    incr = 3
  elseif newIndex == 0 and lastIndex == 11 then
    print("increment layover 11 to 0 (3 steps)" .. debugStr)
    incr = 3
  elseif newIndex == 13 and lastIndex == 0 then
    print("decrement layover 0 to 13 (1 step)" .. debugStr)
    incr = -1
  elseif newIndex == 12 and lastIndex == 0 then
    print("decrement layover 0 to 12 (2 step)" .. debugStr)
    incr = -2
  elseif newIndex == 11 and lastIndex == 0 then
    print("decrement layover 0 to 11 (3 step)" .. debugStr)
    incr = -3
  elseif newIndex == 13 and lastIndex == 1 then
    print("decrement layover 1 to 13 (2 step)" .. debugStr)
    incr = -2
  elseif newIndex == 12 and lastIndex == 1 then
    print("decrement layover 1 to 12 (3 step)" .. debugStr)
    incr = -3
  elseif newIndex == 13 and lastIndex == 2 then
    print("decrement layover 2 to 13 (3 step)" .. debugStr)
    incr = -3
  elseif newIndex > lastIndex then
    -- catch all other increments
    incr = newIndex - lastIndex
    print("increment " .. incr .. " step" .. debugStr)
  elseif lastIndex > newIndex then
    -- catch all other decrements
    incr = newIndex - lastIndex
    print("decrement " .. incr .. " step" .. debugStr)
  else
    print("Err. Got incr/decr should not." .. debugStr)
  end
  
  -- throw away increments that are too much
  if incr > 3 or incr < -3 then
    incr = nil
  end
  
  -- invert the value so clockwise is incr and counterclockwise is decr
  if incr ~= nil then
    incr = incr * -1
  end
  
  return incr
end

-- m.isSending = false
-- function m.onDoneSendingToWs2812()
--   m.isSending = false
-- end

-- Get narrow index returns 0 thru 11 for pad 3, 3/4, 4, 4/5...
function m.getNarrowIndex(pads)

  -- Get narrow index
  -- The design of the touch pad is such that a finger
  -- can be on one pad or two pads (maybe even 3 if wide finger, but we ignore that)
  -- so treat a cross-over touch as its own state, i.e. it's own index

  -- Pad Index
  -- 3   0
  -- 3,4 1
  -- 4   2
  -- 4,5 3
  -- 5   4
  -- 5,6 5
  -- 6   6
  -- 6,7 7
  -- 7   8
  -- 7,8 9
  -- 8   10
  -- 8,9 11
  -- 9   12
  -- 9,3 13   Pad 9 is right next to pad 3 on the PCB so it loops
  local ni = nil
  -- look at cross-over first, then look at individual
  if pads[3] then
    if pads[4] then
      ni = 1
    elseif pads[9] then
      ni = 13
    else
      ni = 0
    end
  elseif pads[4] then
    if pads[5] then
      ni = 3
    else
      ni = 2
    end
  elseif pads[5] then
    if pads[6] then
      ni = 5
    else
      ni = 4
    end
  elseif pads[6] then
    if pads[7] then
      ni = 7
    else
      ni = 6
    end
  elseif pads[7] then
    if pads[8] then
      ni = 9
    else
      ni = 8
    end
  elseif pads[8] then
    if pads[9] then
      ni = 11
    else
      ni = 10
    end
  elseif pads[9] then
    -- if pads[3] then
    --   ni = 13
    -- else
      ni = 12
    -- end
  end
  
  -- return our narrow index
  return ni
    
end

function pconcat(tab)
  local ctab = {}
  local n = 1
  for k, v in pairs(tab) do
      ctab[n] = k
      n = n + 1
  end
  return table.concat(ctab, ",")
end

function m.read()
  local raw = m._tp:read()
  print("Pad", "Val")
  for key,value in pairs(raw) do 
    print(key,value) 
  end
end

function m.config()
  local raw = m._tp:read()
  print("Configuring...")
  print("Pad", "Base", "Thres")
  for key,value in pairs(raw) do 
    if key ~= nil then
    -- reduce by 30%
      local thres = raw[key] - math.floor(raw[key] * 0.3)
      m._tp:setThres(key, thres)
      print(key, value, thres) 
    end
  end
  m._tp:intrEnable()
end

-- m.init()
-- m.read()
-- m.config()

return m
