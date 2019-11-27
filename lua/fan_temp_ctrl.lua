-- Fan control
-- Send out PWM signal to control on/off and speed of fan
-- 10Khz is supported for PWM
-- Set frequency to above or below human audible sound
-- So below 20Hz or above 20khz

-- local fan = {}
fan = {}

-- get tmp36 temperature module
fan.temp = require("tmp36_v2")

-- Create increasing fan speed at certain temperature points
fan.temps = {}
-- tempC = speed
fan.temps[0] = 0
fan.temps[22] = 0
-- fan.temps[23] = 20
-- fan.temps[24] = 30
fan.temps[28] = 40
fan.temps[29] = 50
fan.temps[30] = 60
fan.temps[31] = 80
fan.temps[33] = 100

--   { temp = 20, speed = 10 },
--   { temp = 25, speed = 20 },
--   { temp = 28, speed = 40 },
--   { temp = 30, speed = 60 },
--   { temp = 31, speed = 80 },
--   { temp = 33, speed = 100 },
-- }

fan.pinFan = 25 --25 is new default for v8, 16 is default on pcb --23

fan._timerBits = 12 --12 --6 --12
-- 50% duty is 2^bits, so times by 2 to get 100% duty
fan._dutyMax = (2^fan._timerBits)*2 --64 --64 2^6 --4096 -- 12 bit is 2^12 = 4096
fan._dutyCur = nil -- Holds current duty
fan._freq = 30 -- Hertz 20 seems good
fan._ch = nil -- Holds LEDC object

fan._curSpeed = 0 

fan.isDebug = false

function fan.init()
  
  -- set fan duty to zero to start
  fan._dutyCur = 0
  
  -- Using LEDC library
  fan._ch = ledc.newChannel({
    gpio=fan.pinFan,
    bits=fan.timerBits, --ledc.TIMER_12_BIT,
    mode=ledc.HIGH_SPEED,
    timer=ledc.TIMER_2,
    channel=ledc.CHANNEL_7,
    frequency=fan._freq,
    duty=fan._dutyCur
  })

  -- set fan speed to 0, not on
  fan.speed(100)

  -- order the keys of the temperature / speed table
  fan._ordered_keys = {}

  for k in pairs(fan.temps) do
    table.insert(fan._ordered_keys, k)
  end

  table.sort(fan._ordered_keys)

  for i = 1, #fan._ordered_keys do
    local k, v = fan._ordered_keys[i], fan.temps[ fan._ordered_keys[i] ]
    if fan.isDebug then print("tempC:", k, "speed:", v) end
  end

  -- setup tmp36 library to read temps
  fan.temp.init({ 
    cb=fan.onTempReading, 
    isDebug=false, 
    samplesToRead=10,
    measureIntervalMs=3000
  })
  -- Start temp sensor loop to read each second
  fan.temp.loop()
  
  
  print("Initted fan & temp sensor. Freq:"..fan.getFreq()..", Duty:"..fan.getDuty())
  
end

fan._lastSpeed = -1
fan._speedHasChanged = 3 -- once changed 3 times, actually change
fan._ctrReport = 0
function fan.onTempReading(temp)
  -- print("Fan-TempC:"..temp)
  
  -- see what temp range item we're at 
  -- and if we need to move to a new speed
  
  -- figure out range
  local slot = 0
  local speed = 0
  for i = #fan._ordered_keys,1,-1 do
    local tempSlot, speedSlot = fan._ordered_keys[i], fan.temps[ fan._ordered_keys[i] ]
    if temp > tempSlot then
      slot = tempSlot
      speed = speedSlot
      break
    end
  end
  
  fan._ctrReport = fan._ctrReport + 1
  if fan.isDebug or fan._ctrReport > 3 then 
    fan._ctrReport = 0
    -- print("TempC: " .. temp.." slot: " .. slot .. " speed:", speed) 
  end
  
  -- debounce speed change
  if speed ~= fan._lastSpeed then
    fan._speedHasChanged = fan._speedHasChanged + 1
    if fan.isDebug then print("fan._speedHasChanged:", fan._speedHasChanged) end
    if fan._speedHasChanged > 3 then
      fan.speed(speed)
      -- fan.setduty(fan.calcDutyFromPct(speed))
      -- fan._curSpeed = speed
      fan._lastSpeed = speed
      fan._speedHasChanged = 0
      if fan.isDebug then print("Changed fan speed to:", speed) end
    end
  end
  
end

function fan.calcDutyFromPct(pct)
  -- fan._curSpeed = pct -- this is sort of cheating
  local duty = math.floor((pct / 100) * fan._dutyMax)
  -- print("DutyFromPct. Pct:"..pct..", Duty:"..duty)
  return duty
end

function fan.setduty(duty)
  -- Keep track of current duty we asked for
  -- since the LEDC driver getduty() can be delayed
  fan._dutyCur = duty
  fan._ch:setduty(duty)
end

function fan.speed(pct)
  fan._curSpeed = pct
  fan.setduty(fan.calcDutyFromPct(pct))
  -- fan.setDutyPower(fan.calcDutyFromPct(pct))
  -- fan.getStatus()
end

function fan.getStatus()
  -- since it takes a bit to set the duty on the LEDC subsystem
  -- only spit out status after a wait time
  -- tmr.create():alarm(500, tmr.ALARM_SINGLE, function()
  local stat = {}
  stat.Freq = fan.getFreq()
  stat.Duty = fan._dutyCur
  stat.Pct = fan.getSpeedPercent()
  -- stat.rawduty = fan.getDuty()
  if fan.isDebug then 
    print("Fan Freq:"..stat.freq..", Duty:"..stat.duty..", "..stat.pct.."%, RawDuty:"..fan.getDuty())
  end
  -- end)
  return stat
end

function fan.getSpeedPercent()
  return fan._curSpeed
  -- return math.floor((fan._dutyCur/fan._dutyMax)*100)
end

function fan.getFreq()
  return fan._ch:getfreq()
end

function fan.getDuty()
  return fan._ch:getduty()
end

function fan.setDutyPower(duty)
  
  -- Turn fan on full power, then back down to the duty, because
  -- starting at lower power may not spin it up with enough start force
  -- fan.on()
  fan.speed(100) --fan.setduty(fan.calcDutyFromPct(100))
  print("Setting fan to max duty "..fan._dutyMax.." for 1s")
  if not tmr.create():alarm(1000, tmr.ALARM_SINGLE, function()
    print("Setting fan to " .. duty .. " duty cycle")
    fan.setduty(duty)
    fan.getStatus()
  end)
  then
    print("Err starting fan timer")
  end
  
end


fan.init()
-- fan.speed(50)

return fan
