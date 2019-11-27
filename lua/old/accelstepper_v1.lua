-- Stepper Acceleration/Deceleration for ESP32
-- This library ported from https://www.airspayce.com/mikem/arduino/AccelStepper/

local m = {}
-- m = {}

m.isDebug = false 

-- Direction of motor
m.DIRECTION_CCW = 0 -- Counter-Clockwise
m.DIRECTION_CW  = 1 -- Clockwise

-- MotorInterfaceType
-- Brief Symbolic names for number of pins.
-- Use this in the pins argument the AccelStepper constructor to 
-- provide a symbolic name for the number of pins
-- to use.
m.CALC      = -1 -- Do all normal functions but skip delay test
m.FUNCTION  = 0 -- Use the functional interface, implementing your own driver functions (internal use only)
m.DRIVER    = 1 -- Stepper Driver, 2 driver pins required

-- The target position in steps. The AccelStepper library will move the
-- motor from the _currentPos to the _targetPos, taking into account the
-- max speed, acceleration and deceleration
m._targetPos = 0 -- Steps
-- -- The current interval between steps in microseconds.
-- -- 0 means the motor is currently stopped with m._speed == 0
m._stepInterval = 0 

-- Current direction motor is spinning in
-- Protected because some peoples subclasses need it to be so
m._direction = true -- true == CW

-- Number of pins on the stepper motor. 0 is step/dir. Permits 2 or 4. 2 pins is a
-- bipolar, and 4 pins is a unipolar.
m._interface = 0         -- 0, 1, 2, 4, 8, See MotorInterfaceType

-- Arduino pin number assignments for the 2 or 4 pins required to interface to the
-- stepper motor or driver
m._pin = {1,2,3,4}

-- Whether the _pins is inverted or not
m._pinInverted = {1,2,3,4}

-- The current absolution position in steps.
m._currentPos = 0    -- Steps

-- The target position in steps. The AccelStepper library will move the
-- motor from the _currentPos to the _targetPos, taking into account the
-- max speed, acceleration and deceleration
m._targetPos = 0     -- Steps

-- The current motos speed in steps per second
-- Positive is clockwise
m._speed = 0.0        -- Steps per second

-- The maximum permitted speed in steps per second. Must be > 0.
m._maxSpeed = 0.0

-- The acceleration to use to accelerate or decelerate the motor in steps
-- per second per second. Must be > 0
m._acceleration = 1.0
m._sqrt_twoa = 0.0 -- Precomputed sqrt(2*m._acceleration)

-- The current interval between steps in microseconds.
-- 0 means the motor is currently stopped with m._speed == 0
m._stepInterval = 0

-- The last step time in microseconds
m._lastStepTime = 0

-- The minimum allowed pulse width in microseconds
m._minPulseWidth = 0

-- Is the direction pin inverted?
--/bool           _dirInverted -- Moved to m._pinInverted[1]

-- Is the step pin inverted?
--/bool           _stepInverted -- Moved to m._pinInverted[0]

-- Is the enable pin inverted?
m._enableInverted = false

-- Enable pin for stepper driver, or 0xFF if unused.
m._enablePin = nil

-- The pointer to a forward-step procedure
m._cbForward = nil --void (*_forward)()

-- The pointer to a backward-step procedure
m._cbBackward = nil--void (*_backward)()

-- The step counter for speed calculations
m._n = 0

-- Initial step size in microseconds
m._c0 = 0.0

-- Last step size in microseconds
m._cn = 0.0

-- Min step size in microseconds based on maxSpeed
m._cmin = 0.0 -- at max speed

--- Init.
-- @param interface number
-- @param pin1 number 
-- @param pin1 number 
-- @param pin1 number 
-- @param pin1 number 
-- @param enable boolean 
function m.init(interface, pin1, pin2, pin3, pin4, enable)

  m._interface = interface
  m._currentPos = 0
  m._targetPos = 0
  m._speed = 0.0
  m._maxSpeed = 1.0
  m._acceleration = 0.0
  m._sqrt_twoa = 1.0
  m._stepInterval = 0
  m._minPulseWidth = 1
  m._enablePin = 0xff
  m._lastStepTime = 0
  m._pin[1] = pin1
  m._pin[2] = pin2
  m._pin[3] = pin3
  m._pin[4] = pin4
  m._enableInverted = false
  
  -- NEW
  m._n = 0
  m._c0 = 0.0
  m._cn = 0.0
  m._cmin = 1.0
  m._direction = m.DIRECTION_CCW

  -- Some reasonable default
  m.setAcceleration(1)
  
  if m.isDebug then print("Initted") end
end

-- This method is for m.CALC or m.FUNCTION with callbacks 
-- If you pass m.CALC then no delay occurs and you can use this 
-- to calculate the data for the run.
-- @param interface MotorInterfaceType
function m.initWithCallbacks(interface, cbForward, cbBackward)

  m._interface = interface
  m._currentPos = 0
  m._targetPos = 0
  m._speed = 0.0
  m._maxSpeed = 1.0
  m._acceleration = 0.0
  m._sqrt_twoa = 1.0
  m._stepInterval = 0
  m._minPulseWidth = 1
  m._enablePin = 0xff
  m._lastStepTime = 0
  m._pin[0] = 0
  m._pin[1] = 0
  m._pin[2] = 0
  m._pin[3] = 0
  m._cbForward = cbForward
  m._cbBackward = cbBackward

  -- NEW
  m._n = 0
  m._c0 = 0.0
  m._cn = 0.0
  m._cmin = 1.0
  m._direction = m.DIRECTION_CCW

  local i
  for i = 1,4 do
    m._pinInverted[i] = 0
  end
  
  -- Some reasonable default
  m.setAcceleration(1)
end

--- Absolute position move.
-- @param absolute
-- @return nil 
function m.moveTo(absolute)
  if (m._targetPos ~= absolute) then
	  m._targetPos = absolute
	  m.computeNewSpeed()
  end
end 

--- Relative position move.
-- @param relative
-- @return nil 
function m.move(relative)
  m.moveTo(m._currentPos + relative)
end

-- Implements steps according to the current step interval
-- You must call this at least once per step
-- returns true if a step occurred
function m.runSpeed()
    -- -- Dont do anything unless we actually have a step interval
  if (m._stepInterval == 0) then return false end 

  if m._interface == m.CALC then
    -- we are in calculate only mode, so skip time check 
    
    if (m._direction == m.DIRECTION_CW) then
	    -- Clockwise
	    m._currentPos = m._currentPos + 1
  	else
	    -- Anticlockwise  
	    m._currentPos = m._currentPos - 1
  	end
  	m.step(m._currentPos)
  	return true 
  	
  else 
    -- we are in standard time check mode to not run too fast 
    local timeUs = node.uptime() 
    if (timeUs - m._lastStepTime >= m._stepInterval) then
    	if (m._direction == m.DIRECTION_CW) then
  	    -- Clockwise
  	    m._currentPos = m._currentPos + 1
    	else
    	    -- Anticlockwise  
    	    m._currentPos = m._currentPos - 1
    	end
    	m.step(m._currentPos)
    
    	m._lastStepTime = timeUs -- Caution: does not account for costs in step()
    
    	return true
      
    else
      
    	return false
    	
    end
  
  end
  
end

-- @return long 
function m.distanceToGo()

    return m._targetPos - m._currentPos
end

-- @return long 
function m.targetPosition()

    return m._targetPos
end

-- @return long 
function m.currentPosition()

    return m._currentPos
end

-- Useful during initialisations or after initial positioning
-- Sets speed to 0
-- @param position long
-- @return nil 
function m.setCurrentPosition(position)

  m._targetPos = position
  m._currentPos = position
  m._n = 0
  m._stepInterval = 0
  m._speed = 0.0
end

-- @return nil 
function m.computeNewSpeed(isCalc)

  local distanceTo = m.distanceToGo() -- +ve is clockwise from curent location

  local stepsToStop = math.floor((m._speed * m._speed) / (2.0 * m._acceleration)) -- Equation 16

  if (distanceTo == 0 and stepsToStop <= 1) then
  	-- We are at the target and its time to stop
  	m._stepInterval = 0
  	m._speed = 0.0
  	m._n = 0
	  return
  end

  if (distanceTo > 0) then
  	-- We are anticlockwise from the target
  	-- Need to go clockwise from here, maybe decelerate now
  	if (m._n > 0) then
	    -- Currently accelerating, need to decel now? Or maybe going the wrong way?
	    if (stepsToStop >= distanceTo or m._direction == m.DIRECTION_CCW) then
  		  m._n = -stepsToStop -- Start deceleration
	    end
		
  	elseif (m._n < 0) then
	    -- Currently decelerating, need to accel again?
	    if (stepsToStop < distanceTo and m._direction == m.DIRECTION_CW) then
	  	  m._n = -m._n -- Start accceleration
	    end 
  	
  	end

  elseif (distanceTo < 0) then
  	-- We are clockwise from the target
  	-- Need to go anticlockwise from here, maybe decelerate
	  if (m._n > 0) then
	    -- Currently accelerating, need to decel now? Or maybe going the wrong way?
	    if (stepsToStop >= -distanceTo or m._direction == m.DIRECTION_CW) then
		    m._n = -stepsToStop -- Start deceleration
	    end
	
	  elseif (m._n < 0) then
  
	    -- Currently decelerating, need to accel again?
	    if (stepsToStop < -distanceTo and m._direction == m.DIRECTION_CCW) then
		    m._n = -m._n -- Start accceleration
	    end
	
    end
  end 

  -- Need to accelerate or decelerate
  if (m._n == 0) then
  	-- First step from stopped
  	m._cn = m._c0
  	if distanceTo > 0 then
  	  m._direction = m.DIRECTION_CW
    else
  	  m._direction = m.DIRECTION_CCW
  	end
  
  else

  	-- Subsequent step. Works for accel (n is +_ve) and decel (n is -ve).
  	m._cn = m._cn - ((2.0 * m._cn) / ((4.0 * m._n) + 1)) -- Equation 13
  	m._cn = math.max(m._cn, m._cmin)
  end 
  
  m._n = m._n + 1
  m._stepInterval = m._cn
  m._speed = 1000000.0 / m._cn
  if (m._direction == m.DIRECTION_CCW) then
	  m._speed = -m._speed
	end

  if m.isDebug then
    print("_speed", m._speed)
    print("_acceleration", m._acceleration)
    print("_cn", m._cn)
    print("_c0", m._c0)
    print("_n", m._n)
    print("_stepInterval", m._stepInterval)
    print("distanceTo", distanceTo)
    print("stepsToStop", stepsToStop)
    print("-----")
  end 
  
end

-- Run the motor to implement speed and acceleration in order to proceed to the target position
-- You must call this at least once per step, preferably in your main loop
-- If the motor is in the desired position, the cost is very small
-- returns true if the motor is still running to the target position.
-- @return boolean 
function m.run()

  if (m.runSpeed()) then
	  m.computeNewSpeed()
    return m._speed ~= 0.0 or m.distanceToGo() ~= 0
  end
end

-- Alternate version of run that let's you calculate the value 
-- for the computeNewSpeed() so you can feed it into ESP32's RMT TX 
-- tick counter technique.
function m.runCalc()

  m.computeNewSpeed(true)
  return m._speed ~= 0.0 or m.distanceToGo() ~= 0
end

-- @param speed float
-- @return nil 
function m.setMaxSpeed(speed)

  if (speed < 0.0) then
    speed = -speed
  end
  
  if (m._maxSpeed ~= speed) then
    
  	m._maxSpeed = speed
  	m._cmin = 1000000.0 / speed
  	-- Recompute m._n from current speed and adjust speed if accelerating or cruising
  	if (m._n > 0) then
  	    m._n = math.floor((m._speed * m._speed) / (2.0 * m._acceleration)) -- Equation 16
  	    m.computeNewSpeed()
  	end
  end
end

-- @return float   
function m.maxSpeed()

    return m._maxSpeed
end

-- @param acceleration float
-- @return nil 
function m.setAcceleration(acceleration)

    if (acceleration == 0.0) then	return end 
    
    if (acceleration < 0.0) then acceleration = -acceleration end 
    
    if (m._acceleration ~= acceleration) then
    	-- Recompute m._n per Equation 17
    	m._n = m._n * (m._acceleration / acceleration)
    	-- New c0 per Equation 7, with correction per Equation 15
    	m._c0 = 0.676 * math.sqrt(2.0 / acceleration) * 1000000.0 -- Equation 15
    	m._acceleration = acceleration
    	m.computeNewSpeed()
    end
end

function m.clamp(val, lower, upper)
    assert(val and lower and upper, "val or lower or upper nil")
    if lower > upper then lower, upper = upper, lower end -- swap if boundaries supplied the wrong way
    return math.max(lower, math.min(upper, val))
end

-- @param speed float
-- @return nil 
function m.setSpeed(speed)

  if (speed == m._speed) then return end
  
  speed = m.clamp(speed, -m._maxSpeed, m._maxSpeed)
  if (speed == 0.0) then
	  m._stepInterval = 0
  else
  
  	m._stepInterval = math.abs(1000000.0 / speed)
  	
  	if (speed > 0.0) then
  	  m._direction = m.DIRECTION_CW
  	else 
  	  m._direction = m.DIRECTION_CCW
  	end
  	
  end
  
  m._speed = speed
end

-- @return float 
function m.speed()

    return m._speed
end

-- Subclasses can override
-- @param step long
-- @return nil 
function m.step(step)

  if m._interface == m.FUNCTION then
    m.step0(step)
  elseif m._interface == m.DRIVER then
    m.step1(step)
  end 
    
end

-- @param pinTbl {1=1,2=0,3=1,4=0} 0=low, 1=high
-- @return nil 
function m.setOutputPins(pinTbl)

    print("TODO setOutputPins")
end

-- 0 pin step function (ie for functional usage)
-- @param step long
-- @return nil 
function m.step0(step)

  -- (void)(step) -- Unused
  if (m._speed > 0) then
    m._cbForward(step)
  else
    m._cbBackward(step)
  end
end

-- 1 pin step function (ie for stepper drivers)
-- This is passed the current step number (0 to 7)
-- Subclasses can override
-- @param step long
-- @return nil 
function m.step1(step)

    -- (void)(step) -- Unused

    -- m._pin[0] is step, m._pin[1] is direction
    -- m.setOutputPins(m._direction ? 0b10 : 0b00) 
    if (m._direction) then
      -- Set direction first else get rogue pulses
      m.setOutputPins({0,1})
    else 
      m.setOutputPins({0,0})
    end
    
    -- TODO
    -- This is the area where we should just add the data 
    -- to an array 
    print("TODO. step1(). step:", step, "m._minPulseWidth:", m._minPulseWidth)
    -- setOutputPins(m._direction ? 0b11 : 0b01) -- step HIGH
    -- -- Caution 200ns setup time 
    -- -- Delay the minimum allowed pulse width
    -- delayMicroseconds(m._minPulseWidth)
    -- setOutputPins(m._direction ? 0b10 : 0b00) -- step LOW
end


    
-- Prevents power consumption on the outputs
-- @return nil    
function m.disableOutputs()
   
  print("TODO disableOutputs()")
end

-- @return nil    
function m.enableOutputs()

  print("TODO enableOutputs")
end

-- @param minWidth unsigned int
-- @return nil 
function m.setMinPulseWidth(minWidth)

  m._minPulseWidth = minWidth
end

-- @param enablePin uint8_t
-- @return nil 
function m.setEnablePin(enablePin)

  m._enablePin = enablePin

  -- This happens after construction, so init pin now.
  if (m._enablePin ~= 0xff) then
    print("TODO setup setEnablePin()")
  end
end

-- @param directionInvert bool 
-- @param stepInvert bool 
-- @param enableInvert bool
-- @return nil 
function m.setPinsInverted(directionInvert, stepInvert, enableInvert)

    m._pinInverted[0] = stepInvert
    m._pinInverted[1] = directionInvert
    m._enableInverted = enableInvert
end

-- @return nil 
function m.setPinsInverted2(pin1Invert, pin2Invert, pin3Invert, pin4Invert, enableInvert)
    
    m._pinInverted[0] = pin1Invert
    m._pinInverted[1] = pin2Invert
    m._pinInverted[2] = pin3Invert
    m._pinInverted[3] = pin4Invert
    m._enableInverted = enableInvert
end

-- Blocks until the target position is reached and stopped
-- @return nil 
function m.runToPosition()

  while m.run() do 
    -- nothing 
    print("did run()")
  end

end

-- @return boolean 
function m.runSpeedToPosition()

  if (m._targetPos == m._currentPos) then return false end
  if (m._targetPos >m._currentPos) then
  	m._direction = m.DIRECTION_CW
  else
	  m._direction = m.DIRECTION_CCW
  end 

  return m.runSpeed()
end

-- Blocks until the new target position is reached
-- @param position local 
-- @return nil 
function m.runToNewPosition(position)

  m.moveTo(position)
  m.runToPosition()
end

-- @return nil 
function m.stop()

  if (m._speed ~= 0.0) then
	  
	  local stepsToStop = math.floor((m._speed * m._speed) / (2.0 * m._acceleration)) + 1 -- Equation 16 (+integer rounding)
  	if (m._speed > 0) then
	    m.move(stepsToStop)
  	else
	    m.move(-stepsToStop)
    end

  end
end

-- @return bool 
function m.isRunning()

  if (m._speed == 0.0 and m._targetPos == m._currentPos) then
    return false
  else 
    return true 
  end 
  
end

function m.test()
  -- Change these to suit your stepper if you want
  m.setMaxSpeed(100);
  m.setAcceleration(20);
  m.moveTo(10);
  
  while (m.distanceToGo() ~= 0) do
    m.run()
  end
end 

-- function m.init(interface, pin1, pin2, pin3, pin4, enable)
-- m.init(m.DRIVER, 10, 11, nil, nil, true)

return m
