-- Pulse counter to keep track of machine coordinates

local m = {}

-- Pass these in on init
m.stepLimitMax = nil
m.stepLimitMin = nil

-- Pass in on init. v8
m.pinDir = 0

-- Pass in on init. 
-- m.pinPulseInput = 25 -- orig
m.pinPulseInput = 36 -- v8

-- in case you inverted your direction pin, we need count reverse here
m.isInvert = false 

m.isDebug = false

-- Pass in a table of values:
-- pinDir: direction pin
-- pinPulseInput: which pin has the loopback pulse on it (could use gpiomatrix in future)
function m.init(tbl)

  if tbl ~= nil then
    if tbl.pinDir ~= nil then m.pinDir = tbl.pinDir end
    if tbl.isInvert ~= nil then m.isInvert = tbl.isInvert end
    if tbl.pinPulseInput ~= nil then m.pinPulseInput = tbl.pinPulseInput end
    if tbl.onLimit ~= nil then m._onLimit = tbl.onLimit end
    if tbl.stepLimitMax ~= nil then m.stepLimitMax = tbl.stepLimitMax end
    if tbl.stepLimitMin ~= nil then m.stepLimitMin = tbl.stepLimitMin end
  end
  
  m.pcnt = pulsecnt.create(7, m.onPulseCnt) -- Use unit 7 (0-7 are allowed)
  
  if m.isInvert then 
    -- need to reverse the direction pin pulse counting
    m.pcnt:chan0Config(
      m.pinPulseInput, --pulse_gpio_num
      m.pinDir, --ctrl_gpio_num If no control is desired specify PCNT_PIN_NOT_USED 
      pulsecnt.PCNT_COUNT_INC, --pos_mode PCNT positive edge count mode
      pulsecnt.PCNT_COUNT_DIS, --neg_mode PCNT negative edge count mode
      pulsecnt.PCNT_MODE_KEEP, --lctrl_mode Ctrl low PCNT_MODE_KEEP, PCNT_MODE_REVERSE, PCNT_MODE_DISABLE
      pulsecnt.PCNT_MODE_REVERSE, --hctrl_mode Ctrl high PCNT_MODE_KEEP, PCNT_MODE_REVERSE, PCNT_MODE_DISABLE
      m.stepLimitMin, --counter_l_lim [Range -32768 to 32767]
      m.stepLimitMax  --counter_h_lim [Range -32768 to 32767]
    )
  else 
    -- standard direction pin counting
    m.pcnt:chan0Config(
      m.pinPulseInput, --pulse_gpio_num
      m.pinDir, --ctrl_gpio_num If no control is desired specify PCNT_PIN_NOT_USED 
      pulsecnt.PCNT_COUNT_INC, --pos_mode PCNT positive edge count mode
      pulsecnt.PCNT_COUNT_DIS, --neg_mode PCNT negative edge count mode
      pulsecnt.PCNT_MODE_REVERSE, --lctrl_mode Ctrl low PCNT_MODE_KEEP, PCNT_MODE_REVERSE, PCNT_MODE_DISABLE
      pulsecnt.PCNT_MODE_KEEP, --hctrl_mode Ctrl high PCNT_MODE_KEEP, PCNT_MODE_REVERSE, PCNT_MODE_DISABLE
      m.stepLimitMin, --counter_l_lim [Range -32768 to 32767]
      m.stepLimitMax  --counter_h_lim [Range -32768 to 32767]
    )
  end
  
  -- Clear counting
  m.pcnt:clear()
  
  -- Poll the pulse counter
  print("pcnt:" .. m.pcnt:getCnt())
  
  -- Map RMT peripheral output to GPIO that Pulse Counter listens on 
  -- gpiomatrix.periphOutToGpioIn(
  --   gpiomatrix.RMT_SIG_OUT0_IDX, -- Peripheral
  --   m.pinPulseInput  -- GPIO
  -- )
  
  -- Reset dir pin to be in/out since pulsecnt sets it to input only
  gpio.config({gpio=m.pinDir, dir=gpio.IN_OUT})
end

function m.onPulseCnt(unit, isThr0, isThr1, isLLim, isHLim, isZero)
  
  print("Got pulse counter.")
  print("unit:", unit, "isThr0:", isThr0, "isThr1:", isThr1)
  print("isLLim:", isLLim, "isHLim:", isHLim, "isZero:", isZero)
  
  if isThr0 or isThr1 then
    -- m.disable()
    
    -- if callback from user, then call it
    if m.onLimit ~= nil then
      m.onLimit(isThr0, isThr1)
    end
    
    -- m.pause()
    -- m.stop()
    if isThr0 then
      print("Hit endstop in negative direction")
    else
      print("Hit endstop in positive direction")
    end
  end
  
end

-- If you homed and want to set the pulse counter to zero, i.e.
-- like setting machine coords to zero on a CNC, this is your method
function m.setMachineCoordsToZero()
  m.pcnt:clear()
end

function m.getMachineCoords()
  return m.pcnt:getCnt()
end

return m
