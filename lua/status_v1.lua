-- Status sending

local m = {}

m.ctrl = nil -- control library (jogging, homing, gcode, etc)
m.cayenn = nil -- cayenn library
m.fan = nil -- fan library

-- Pass in table of values:
-- ctrl = ctrlLib
-- cayenn = cayennLib
-- fan = fanLib
function m.init(tbl)
  if tbl ~= nil then
    if tbl.ctrl ~= nil then m.ctrl = tbl.ctrl end
    if tbl.cayenn ~= nil then m.cayenn = tbl.cayenn end
    if tbl.fan ~= nil then m.fan = tbl.fan end
  end
end

function m.send()
  local tbl = m.get()
  -- send it off to listeners
  m.cayenn.send(tbl)
end

function m.sendUdp()
  local tbl = m.get()
  -- send it off to listeners
  m.cayenn.sendUdp(tbl)
end

function m.round(num, numDecimalPlaces)
  local mult = 10^(numDecimalPlaces or 0)
  return math.floor(num * mult + 0.5) / mult
end

-- Status report loop 
function m.get()
  
  tbl = {}
  local stat = m.ctrl.getState()
  tbl.State = stat.State 
  
  -- We have a freq val during jog or gcode move
  if stat.Freq then
    tbl.Freq = m.round(stat.Freq, 1)
  end 
  
  -- get steps 
  -- These should equal eachother.
  tbl.StepRmt = m.ctrl.gcode.getMachineCoords() -- from accelstepper
  tbl.Step = m.ctrl.pcnt.getMachineCoords() -- from hardware pulse count on step pin
  -- get frequency 
  -- tbl.Freq = ctrl.jog.getFreq()
  -- get temp 
  tbl.Temp, isWarning, isEmergency = m.fan.temp.read(10) -- 10 samples to avg
  if isWarning then tbl.IsTempWarning = true end
  if isEmergency then tbl.IsTempEmergency = true end
  -- get fan 
  tbl.Fan = m.fan.getStatus().Pct --fan.getSpeedPercent()
  -- tbl.State = ctrl.getState()
  return {["Stat"] = tbl}
end 

function m.start()
  if m._tmrStatus and m._tmrStatus:state() then 
    print("Status already running")
    return false
  end 
  
  m._tmrStatus = tmr.create()
  -- TODO only send updates, so keep last status and debounce
  m._tmrStatus:alarm(2000, tmr.ALARM_AUTO, function()
    m.sendUdp()
  end)
  
  return true
end 

function m.stop()
  if m._tmrStatus and m._tmrStatus:state() then 
    m._tmrStatus:unregister()
  end 
end

return m