-- TMP36 Temperature Sensor
-- Using part number TMP36GT9Z
-- Temperature Sensor Analog, Local -40°C ~ 125°C 10mV/°C TO-92-3

-- fan = require("fan")
-- fan.off()

local tmp = {}
-- tmp = {}

  -- When using adc.ADC1: 0 to 7. 
  -- 0: GPIO36, 1: GPIO37, 2: GPIO38, 3: GPIO39, 4: GPIO32, 
  -- 5: GPIO33, 6: GPIO34, 7: GPIO35
tmp.adcChannel = 3
tmp.pinTmp = 39 -- old 35

tmp.degCToWarn = 39
tmp.degCToEmergencyStop = 40

tmp.measureIntervalMs = 1000 -- 10 seconds

tmp.adcReadingAt70DegF22DegC = 2970 -- 22 celsius
tmp.adcDegCPer10mv = 10
tmp.adcBits = 10 -- 12 max (4096 max reading)
tmp.adcMaxReading = 1024 -- 2^10 =  2^12 bits = 4096

tmp.isDebug = false

tmp._cb = nil

-- Pass in callback to be called on each temperature loop reading
-- Pass in isDebug for extra debug info
-- { cb=myfunc, isDebug=false, samplesToRead=1, measureIntervalMs=1000 }
function tmp.init(tbl)
   
  if tbl ~= nil then
    if tbl.cb ~= nil then tmp._cb = tbl.cb end
    if tbl.isDebug ~= nil then tmp.isDebug = tbl.isDebug end
    if tbl.samplesToRead ~= nil then tmp.samplesToRead = tbl.samplesToRead end
    if tbl.measureIntervalMs ~= nil then tmp.measureIntervalMs = tbl.measureIntervalMs end
  end
  
  -- adc.ATTEN_0db The input voltage of ADC will be reduced to about 1/1 (1.1V when VDD_A=3.3V)
  -- adc.ATTEN_2_5db The input voltage of ADC will be reduced to about 1/1.34 (1.5V when VDD_A=3.3V)
  -- adc.ATTEN_6db The input voltage of ADC will be reduced to about 1/2 (2.2V when VDD_A=3.3V)
  -- adc.ATTEN_11db The input voltage of ADC will be reduced to about 1/3.6 (3.9V when VDD_A=3.3V, maximum voltage is limited by VDD_A)
  adc.setup(adc.ADC1, tmp.adcChannel, adc.ATTEN_0db)
  
  -- bits One of 9/10/11/12.
  adc.setwidth(adc.ADC1, tmp.adcBits)
  
  if isDebug == true then 
    tmp.isDebug = true
  end
  
  -- tmp.loop()
end

function tmp.toCelsius(f)
    return (f - 32) * 5 / 9
end

function tmp.toFahrenheit(c)
    return c * 9 / 5 + 32
end

function tmp.round(num, numDecimalPlaces)
  local mult = 10^(numDecimalPlaces or 0)
  return math.floor(num * mult + 0.5) / mult
end

tmp.samplesToRead = 1
-- @return tempDegC
function tmp.read(samples)
  
  -- see if they wanted to override number of samples
  if samples == nil then
    samples = tmp.samplesToRead
  end 
  
  -- since this is a 12bit read, the max val is 4096
  -- with 0db atten we max at 1.1v, but the Tmp36 could go above that
  -- for really high temps
  local total = 0
  for i=1,samples do
    total = total + adc.read(adc.ADC1, tmp.adcChannel)
  end
  local val = total / samples
  
  local volts = val/tmp.adcMaxReading -- normalize by the maximum temperature raw reading range. we are using 12bits so 2^12 = 4096
  -- calculate temperature celsius from voltage as per the equation found on the sensor spec sheet.
  local temp = (volts - 0.46) * 100 -- (Should use 0.5, but calibrated) 
  -- print("Tmp36: " .. val, "Volts:", tmp.round(volts,3))
  if tmp.isDebug == true then 
    print("TempC:",tmp.round(temp,1),"TempF:",tmp.round(tmp.toFahrenheit(temp), 1))
  end
  
  -- local degCDeltamv = val - tmp.adcReadingAt70DegF22DegC
  -- local degCDelta = degCDeltamv / tmp.adcDegCPer10mv
  -- local degC = 22 + degCDelta
  -- print("DegCDelta:", tmp.round(degCDelta,1), "DegC:", tmp.round(degC,1), "DegF:", tmp.round(tmp.toFahrenheit(degC), 1))
  
  local isTempEmergency = false
  local isTempWarning = false
  if temp > tmp.degCToEmergencyStop then 
    isEmergency = true
    print("Motor is over tempearature. Stopping.")
    -- localTime = time.getlocal()
    -- print(string.format("%02d:%02d:%02d",  localTime["hour"], localTime["min"], localTime["sec"]))

    if m and type(m.jogStop) == "function" then 
      m.jogStop()
    end
    -- print motor status
    -- if m and m.motor and type(m.motor.readDRV_STATUS) == "function" then
    --   m.motor.readDRV_STATUS()
    -- end
  elseif temp > tmp.degCToWarn then 
    isTempWarning = true
    print("Motor warning. Running hot.")
    -- localTime = time.getlocal()
    -- print(string.format("%02d:%02d:%02d",  localTime["hour"], localTime["min"], localTime["sec"]))
    
  end
  
  return tmp.round(temp,1), isTempWarning, isTempEmergency
end

function tmp.loop()
  tmp.tmr = tmr.create():alarm(tmp.measureIntervalMs, tmr.ALARM_AUTO, function()
    local tempDegC = tmp.read()
    -- print("Temp Celsius:", tempDegC)
    if tmp._cb ~= nil then
      node.task.post(node.task.LOW_PRIORITY, function()
        tmp._cb(tempDegC)
      end)
    end
  end)
end

function tmp.stop()
  tmp.tmr:unregister()
end

-- tmp.init(true)
-- tmp.loop()

return tmp

