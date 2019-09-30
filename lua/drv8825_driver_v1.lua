-- DRV8825 driver
-- Provides config, enable, disable, direction
-- The DVR8825 runs over normal GPIO

local m = {}
-- m = {}

-- Touch uses pins 2, 12, 13, 14, 15, 27, 33, 32
-- Hall uses pin 5
-- Tmp uses pin 35
-- Stepper uses pins 4, 0, 16, 36, 17, 18, 19
-- Fan uses 25

-- For v8 design
-- m.pinStep = 4 -- GPIO22, pin36 on esp32-wroom-32d, Orig 2
-- m.pinDir = 0 -- it is 0 cuz that is bootstrap pin, but inconsequential  --14 -- pin33 on esp32-wroom-32d, Orig 14
-- m.pinSleep = 16 --0 on orig --17 -- ENN pin28 GPIO17 on esp32-wroom-32d, Orig 15 or 0

-- For original 1.0 design
-- m.pinStep = 2 
-- m.pinDir = 14
-- m.pinSleep = 0 --15

-- v8
m.pinDir = 0
m.pinStep = 4 -- set from tbl 
m.pinSleep = 21 -- keep in mind sleep IO16 is hard sleep. want to use en
m.pinSleepHeavy = 16
m.pinReset = 22

-- m.pinRst = 22
-- m.pinEn = 21

-- Microsteps original 1.0 design
-- m.pinM0 = 12
-- m.pinM1 = 13
-- m.pinM2 = 15

-- Microsteps v8
m.pinM0 = 17
m.pinM1 = 18
m.pinM2 = 19

-- Setup microsteps 1, 2, 4, 8, 16 (but RMTTX lib only supports 1 or 2 right now)
m.microSteps = 1

m.isDebug = false

m.isInvert = false

m._isInitted = false
-- m._onLimit = nil

-- Pass in a table of settings
-- @param tbl.isDebug  Defaults to false. Turn on for extra logging.
function m.init(tbl)
  
  if m._isInitted then 
    print("DRV8825 already initted")
    return 
  end
  
  m._isInitted = true
  
  if tbl ~= nil then
    if tbl.isInvert ~= nil then m.isInvert = tbl.isInvert end
    if tbl.isDebug == true then m.isDebug = true end
  end
    
  gpio.config({
    gpio= {
      m.pinStep, m.pinSleep, m.pinDir,
      m.pinM0, m.pinM1, m.pinM2,
      m.pinSleepHeavy, m.pinReset
    },
    dir=gpio.IN_OUT,
    -- pull=gpio.PULL_UP
  })

  -- Make DRV8825 not sleep heavy (this is the sleep pin, not to be confused with en pin)
  gpio.write(m.pinSleepHeavy, 1)
  -- Pull reset high to enable driver
  gpio.write(m.pinReset, 1)

  gpio.write(m.pinStep, 0)
  
  -- gpio.write(m.pinSleep, 0) -- drv8825 low makes sleep / high make active
  
  -- Now make sure the stepper is asleep so it's not cranking current
  -- through it and heating up
  m.disable()
  
  -- gpio.write(m.pinDir, 1)
  m.dirFwd()
  
  -- for full steps, all low
  -- for max micro-stepping, all high
  -- 0,0,0 full step
  -- 1,0,0 1/2 step, 0,1,0 1/4 step, 1,1,0 1/8 step
  if m.microSteps == 1 then
    print("Setting microSteps to 1")
    gpio.write(m.pinM0, 0)
    gpio.write(m.pinM1, 0)
    gpio.write(m.pinM2, 0)
  elseif m.microSteps == 2 then
    print("Setting microSteps to 2")
    gpio.write(m.pinM0, 1)
    gpio.write(m.pinM1, 0)
    gpio.write(m.pinM2, 0)
  elseif m.microSteps == 4 then
    print("Setting microSteps to 4")
    gpio.write(m.pinM0, 0)
    gpio.write(m.pinM1, 1)
    gpio.write(m.pinM2, 0)
  else
    error("Error with unsupported microSteps setting")
  end

end

m.DIR_FWD = 1
m.DIR_REV = 0
m._dir = nil
function m.setDir(dir)
  if dir == m.DIR_FWD then
    if m._dir == m.DIR_FWD then
      -- already set. ignore.
      if m.isDebug then print("Dir fwd already set. Ignoring.") end
      return
    end
    if m.isInvert then
      gpio.write(m.pinDir,0)
    else 
      -- standard
      gpio.write(m.pinDir,1)
    end 
    
    -- use pull up approach so the pulse counter can read this
    -- port value without chewing up a 2nd input port
    -- gpio.config( { gpio=m.pinDir, dir=gpio.IN, pull=gpio.PULL_UP } )
    m._dir = m.DIR_FWD
    if m.isDebug then print("Set dir fwd") end
  else
    if m._dir == m.DIR_REV then
      -- already set. ignore.
      if m.isDebug then print("Dir rev already set. Ignoring.") end
      return
    end
    
    if m.isInvert then
      gpio.write(m.pinDir,1)
    else 
      -- standard
      gpio.write(m.pinDir,0)
    end 
    
    -- use pull up approach so the pulse counter can read this
    -- port value without chewing up a 2nd input port
    -- gpio.config( { gpio=m.pinDir, dir=gpio.IN, pull=gpio.PULL_DOWN } )
    m._dir = m.DIR_REV
    if m.isDebug then print("Set dir rev") end
  end
end

function m.dirFwd()
  m.setDir(m.DIR_FWD)
end

function m.dirRev()
  m.setDir(m.DIR_REV)
end

function m.dirToggle()
  if m._dir == m.DIR_FWD then
    m.dirRev()
  else
    m.dirFwd()
  end
end

function m.disable()
  
  -- drv8825 low makes sleep / high make active
  -- gpio.write(m.pinSleep, 0) -- orig
  gpio.write(m.pinSleep, 1) -- v8
  -- if m.isDebug then 
    print("Sleeping motor (disable)") 
  -- end
end 

function m.enable()
  -- drv8825 low makes sleep / high make active
  -- gpio.write(m.pinSleep, 1) -- orig
  gpio.write(m.pinSleep, 0) -- v8
  if m.isDebug then print("Waking motor (enable)") end
end

return m
