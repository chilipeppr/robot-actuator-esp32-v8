-- Hall sensor gprio trigger
-- Watch the hall sensor gpio and fire callbacks

-- To use:
-- es = require("hall_endstop")

-- function onHit()
--   print("Got hit")
-- end

-- es.init({
--   onHit = onHit,
--   isDebug = false
-- })

local m = {}
-- m = {}

m.pin = 5 --37

m.isDebug = false

-- callbacks on endstop state
m.onHit = nil
m.onLeave = nil

m._isInitted = false

-- Pass in a table of settings
-- @param tbl.onHit  Callback when hitting the endstop
-- @param tbl.onLeave  Callback when leaving endstop
-- @param tbl.isDebug  Defaults to false. Turn on for extra logging.
-- Example motor.init({initStepDirEnPins=true, })
function m.init(tbl)
  
  if m._isInitted then
    print("Endstop already initted")
    return
  end
  
  m._isInitted = true

  if tbl.isDebug == true then m.isDebug = true end
  if tbl.onHit ~= nil then m.onHit = tbl.onHit end
  if tbl.onLeave ~= nil then m.onLeave = tbl.onLeave end

  gpio.config( { 
    gpio=m.pin, 
    dir=gpio.IN,
    opendrain=1,
    pull=gpio.PULL_UP   --PULL_DOWN --FLOATING --PULL_UP 
  })
  gpio.trig(m.pin, gpio.INTR_UP_DOWN, m.onTrigger)
  
end

function m.getState()
  return gpio.read(m.pin)
end

function m.onTrigger(pin, lvl)
  if m.isDebug then print("trig pin:", pin, "lvl:", lvl) end
  if lvl == 0 then
    -- verify we really are at level 0
    if m.getState() == 0 then
      -- hit endstop
      if m.isDebug then print("Hit endstop") end
      if m.onHit ~= nil then
        node.task.post(node.task.HIGH_PRIORITY, m.onHit)
      end
    else
      -- error("We really did not hit endstop. lvl:0, state:"..m.getState())
    end
  elseif lvl == 256 then
    -- verify we really are at level 1
    if m.getState() == 1 then
      -- left endstop
      if m.isDebug then print("Left endstop") end
      if m.onLeave ~= nil then
        node.task.post(node.task.HIGH_PRIORITY, m.onLeave)
      end
    else
      error("We really did not leave endstop")
    end
  else
    print("Hit endstop trigger state we don't understand.")
  end    
end

-- m.init()

return m