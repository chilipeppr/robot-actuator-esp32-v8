-- RMT TX Test Code for ws2812 LED

local m = {}
-- m = {}
m.tx = nil

m._cb = nil

m.red = 0
m.green = 0
m.blue = 0

m.memBlocks = 1
m.memBytes = m.memBlocks * 64 -- size we can send in during initial writeRaw()
m.memBytesHalf = m.memBytes / 2 -- size we can send in during fillRaw

m._isInitted = false

m.isDebug = false

function m.onEvent(channel, flag, thres)
  -- print("channel:", channel, "flag:", flag, "thres:", thres)
  
  if flag == 2 then
    -- threshold event. we can fill more memory
    if m.isDebug then print("Got ws2812 thres event") end
  elseif flag == 1 then 
    
    m.isSending = false
    
    -- end event
    -- m.startTimer()
    if m.isDebug then print("Got ws2812 end event") end
    
    if m._isBlink == true then
      -- we need to set the 2nd color now
      m.blink2nd()
      return
    end
    
    -- do callback if they want it
    if m._cb ~= nil then
      node.task.post(node.task.LOW_PRIORITY, m._cb)
    end
    
  end
end

-- You can pass in a callback to be called on done sending ws2812 data
m._cb = nil
function m.init(cb)
  
  if m._isInitted then
    print("LED lib already initted")
    return
  end
  
  m._isInitted = true
  
  m._cb = cb
  
  -- Smallest tick is 12.5 ns (clkDiv=1) and highest tick is 3187.5 ns (clkDiv=255) 
  -- rmttx.getClkDivForNsPerTick(100) -- Pass in nanosecond value, get back best clkDiv

  m.tx = rmttx.create({
    channel = 7, -- 0 thru 7 supported
    gpio = 26, -- The GPIO pin to transmit the pulses on
    cb = m.onEvent, -- Callback for loading more data
    clkDiv = rmttx.getClkDivForNsPerTick(100), -- 100 ns per tick. 80Mhz clock. 
    memBlocks = m.memBlocks, -- Number of memory blocks to use. Defaults to 1. 
    enLoop = false, -- Transmit the data items in a loop. 
    isDebug = false,
  })
  print("Initting ws2812. Using channel 7. GPIO 26. memBlocks "..m.memBlocks)

  -- m.start()
  -- -- Start with writeAsync() which we have to give up to 64 bytes
  -- -- because we asked for memBlocks=1
  -- -- So, start with 1 color and then fill with pauses
  -- local data = m.getColor(m.red, m.green, m.blue)
  -- m.concat(data, {0,0,0,0})

  -- -- m.concat(data, {32767,0,32767,0}, m.memBytes-24)
  -- m.tx:writeRawStart(data)
  -- print("Sent initial ws2812 color")
  m.set(0,255,0)

end

function m.stop()
  m.isStop = true
end

function m.start()
  m.isStop = false
  m.incrementColor()
end

m.isStop = false
function m.startTimer()
  
  if m.isStop then
    -- we are being asked to stop
    return
  end
  
  -- Wait about 200ms to increment color 
  tmr.create():alarm(100, tmr.ALARM_SINGLE, function()
    m.incrementColor()
  end)
end

function m.decrementColor()
  m.incrementColor(true)
end

m.maxColorIntensity = 30
m.color = 1
m.increment = 2
function m.incrementColor(isDecrement)
  
  local increment = m.increment
  if isDecrement then
    increment = m.increment * -1
  end
    
  -- if red
  if m.color == 1 then 
    m.red = m.red + increment 
    if m.red >= 30 or m.red < 0 then 
      
      
      if m.red < 0 then 
        -- rev color
        m.color = 3 -- go to blue
        m.blue = m.maxColorIntensity
      else
        -- fwd color
        m.color = 2 -- go to green
      end 
      
      m.red = 0
    end
  end
  
  -- if green
  if m.color == 2 then 
    m.green = m.green + increment 
    if m.green >= 30 or m.green < 0 then 
      
      
      if m.green < 0 then 
        -- rev color
        m.color = 1
        m.red = m.maxColorIntensity
      else
        -- fwd color
        m.color = 3 
      end 

      m.green = 0
    end
  end
  
  -- if blue
  if m.color == 3 then 
    m.blue = m.blue + increment 
    if m.blue >= 30 or m.blue < 0 then 

     
      if m.blue < 0 then 
        -- rev color
        m.color = 2 -- go to green
        m.green = m.maxColorIntensity
      else
        -- fwd color
        m.color = 1 -- go to red
      end 

      m.blue = 0
    end
  end
  
  m.set(m.red, m.green, m.blue)
end

m.isSending = false
function m.set(r, g, b, isPad)
  
  if m.isSending then 
    if m.isDebug then print("Yielding ws2812 cuz sending") end
    return 
  end
  
  local data = m.getColor(r, g, b) -- 24 bytes
  
  if m.isDebug then print("Blocks used for rgb val:", #data/4) end
  -- if they want a delay, we can pad with the longest
  -- duration allowed by one memBlock
  if isPad then
    -- memblock is 64 blocks, we already chewed up 24 blocks on rgb color
    -- we need 1 byte left for end rmt data
    m.concat(data, {32767,0,32767,0}, (63-(#data/4)))
  end

  -- place in the end RMT signal  
  m.concat(data, {0,0,0,0})
  
  if m.isDebug then print("sending N blocks to rmt for ws2812:", #data/4) end

  -- We are not sending enough data to use more than one block 
  -- or a callback, so this is a clean write 
  m.isSending = true
  m.tx:writeRawStart(data)
end 

-- show one color, then show the other
m.blink2ndVal = nil
function m.blink(r, g, b, r2, g2, b2)
  if r2 == nil or g2 == nil or b2 == nil then
    error("You did not pass in 2nd color")
  end
  m._isBlink = true
  m.blink2ndVal = {r2, g2, b2}
  m.set(r, g, b, true)
  -- we will get callback on done, then set the 2nd color
end

function m.blink2nd()
  m._isBlink = false
  m.set(m.blink2ndVal[1], m.blink2ndVal[2], m.blink2ndVal[3])
  m.blink2ndVal = nil
end

function m.concat(t1,t2,repCnt)
  if repCnt == nil then repCnt = 1 end
  for r=1,repCnt do
    for i=1,#t2 do
      t1[#t1+1] = t2[i]
    end
  end
  return t1
end

-- For ws2812 from datasheet:
-- Reset: When the data line is held low for more than 50µs, the device is reset.
-- 1: 0.8uS (800 ns) high / 0.45uS (450 ns) low.
-- 0: 0.4uS (400 ns) high / 0.85uS (850 ns) low. 
-- You need to pass tx:write() an array of ticks in duration0, lvl0, duration1, lvl1 pairs
function m.getColor(r, g, b)
  
  local d = {}
  local colors = {g,r,b}
  
  for colorItem = 1,3 do
    for i = 8,1,-1 do
      if bit.isset(colors[colorItem], i-1) then 
        m.concat(d, {8,1,5,0}) -- set 1 pulse. 800ns high / 500ns low
      else 
        m.concat(d, {4,1,9,0}) -- set 0 pulse. 400ns high / 900ns low
      end
    end
  end
  
  -- print("color. grb: "..sjson.encode(colors))
  -- print("data: "..sjson.encode(d))
  return d
  
end

return m
