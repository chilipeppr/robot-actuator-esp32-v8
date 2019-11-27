-- Commands for robot
-- Keep in mind these are all globals, not in a module/library

-- Define commands supported by your device. They will appear
-- inside the Cayenn widget in ChiliPeppr as buttons.
cmds = {
  "ResetCtr", "GetCtr", "GetCmds", "GetQ", "WipeQ", "CmdQ", "Mem",
  "TestStart", "TestStop", "DirToggle", "DirFwd", "DirRev", --"Sleep", "Wake",
  "Home", "ZeroOut",
  "StatusGet", "StatusStart", "StatusStop",
  "JogStart {Freq}", "JogStop", "JogFreq {Freq}",
  "SetAsMaster", "SetAsSlave", "GetMasterOrSlave",
  "Play", "Pause", "Stop",
  "Receipt {DeviceId,Ctr}",
  "Home",
  "GcodePlay", "GcodeStop", "GcodePlayStopToggle", "GcodeWipe", "GcodeRecord",
  "Gcode {Step,Fr,Acc}",
  "Restart",
  "LedFill {r,g,b}", "LedPulse {r,g,b}",
  -- 'SetAValue {Hz,Duty} (Max Hz:1000, Max Duty:1023)',
  -- 'SetA2ndValue {Brightness}',
}

function LedFill(payload)
  ctrl.led.fill(payload.r, payload.g, payload.b)
  cayenn.send({TransId = payload.TransId, Resp = payload.Cmd})
end  

function LedPulse(payload)
  ctrl.led.pulse(payload.r, payload.g, payload.b)
  cayenn.send({TransId = payload.TransId, Resp = payload.Cmd})
end

function GcodePlay(payload)
  cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd})
  ctrl.gcodePlay()
end

function GcodeStop(payload)
  cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd})
  ctrl.gcodeAskForStop()
end

function GcodePlayStopToggle(payload)
  cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd})
  ctrl.toggleGcodePlayStop()
end

function GcodeWipe(payload)
  cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd})
  ctrl.wipeGcode()
end

function GcodeRecord(payload)
  cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd})
  ctrl.recordGcode()
end

function Gcode(payload)
  cayenn.send({["TransId"] = payload.TransId, Step=payload.Step, Fr=payload.Fr, Acc=payload.Acc, ["Resp"] = payload.Cmd})
  ctrl.gcodeRunOneMove(payload)
end

function Home(payload)
  cayenn.send({["TransId"] = payload.TransId, ["Desc"] = "Running homing routine", ["Resp"] = payload.Cmd})
  ctrl.homing.home()
end

function ZeroOut(payload)
  cayenn.send({["TransId"] = payload.TransId, ["Desc"] = "Running homing routine", ["Resp"] = payload.Cmd})
  ctrl.pcnt.setMachineCoordsToZero()
  -- Set accel stepper to zero as well
  ctrl.gcode.setMachineCoords(0)
end

function JogStart(payload)
  local desc = "Started jog "
  
  -- see if in state where not allowed to start jogging 
  local state = ctrl.getState()
  if state.IsJoggingAllowed then 
    if payload.Freq ~= nil and payload.Freq > 0 then
      ctrl.motor.dirFwd()
      -- ctrl.jog.jogStart(payload.Freq)
      ctrl.jog.setfreq(payload.Freq, true)
      ctrl.jog.resume()
      desc = desc .. "fwd at "..payload.Freq.."Hz"
    elseif payload.Freq ~= nil and payload.Freq < 0 then
      ctrl.motor.dirRev()
      payload.Freq = math.abs(payload.Freq)
      -- ctrl.jog.jogStart(payload.Freq)
      ctrl.jog.setfreq(payload.Freq, true)
      ctrl.jog.resume()
      desc = desc .. "rev at "..payload.Freq.."Hz"
    else
      desc = "Freq was 0 so did nothing"
    end
  else 
    -- jogging not allowed right now 
    desc = "Jogging not allowed right now. State:"..state.State
  end
  cayenn.send({["TransId"] = payload.TransId, ["Desc"] = desc, ["Resp"] = payload.Cmd})
  ctrl.led.pulse(100,0,0)
  stat.start() -- start sending position updates
end

function JogStop(payload)
  local state = ctrl.getState()
  local desc = ""
  if state.IsJoggingAllowed then 
    -- ctrl.jog.jogStop()
    ctrl.jog.pause()
    desc = "Stopped jog"
  else 
    desc = "Jogging not allowed right now. State:"..state.State 
  end
  cayenn.send({["TransId"] = payload.TransId, ["Desc"] = desc, ["Resp"] = payload.Cmd})
  -- stat.stop() -- stop sending position updates
  -- stat.send()
  ctrl.led.pulse(0,0,55)
end

function JogFreq(payload)
  local state = ctrl.getState()
  local desc = ""
  if state.IsJoggingAllowed then 
    payload.Freq = math.abs(payload.Freq)
    ctrl.jog.setfreq(payload.Freq, true) --override dampen
    desc = "Set jog freq to "..payload.Freq
  else 
    desc = "Jogging not allowed right now. State:"..state.state 
  end
  cayenn.send({["TransId"] = payload.TransId, ["Desc"] = desc, ["Freq"] = payload.Freq, ["Resp"] = payload.Cmd})
  ctrl.led.fill(0,255,0)
end

function StatusGet(payload)
  local tbl = stat.get()
  -- send it off to listeners
  tbl.TransId = payload.TransId
  tbl.Resp = payload.Cmd 
  cayenn.send(tbl)
  ctrl.led.fill(0,10,0)
end

function StatusStart(payload)
  desc = "Started status loop every 1 sec"
  if not stat.start() then
    desc = "Status loop already running"
  end
  cayenn.send({["TransId"] = payload.TransId, ["Desc"] = desc, ["Resp"] = payload.Cmd})
  ctrl.led.fill(0,10,0)
end

function StatusStop(payload)
  stat.stop()
  cayenn.send({["TransId"] = payload.TransId, ["Desc"] = "Stopped status loop", ["Resp"] = payload.Cmd})
  ctrl.led.fill(0,10,0)
end

function GetCmds(payload)
  local resp = {}
  resp.Resp = "GetCmds"
  resp.Cmds = cmds
  resp.TransId = payload.TransId
  cayenn.send(resp)
  ctrl.led.fill(0,10,10)
end

function DirToggle(payload)
  local dir = ctrl.motor.dirToggle()
  cayenn.send({["TransId"] = payload.TransId, Dir=dir, ["Resp"] = payload.Cmd})
  -- print("Toggled direction of stepper")
end

function DirFwd(payload)
  ctrl.motor.dirFwd()
  cayenn.send({["TransId"] = payload.TransId, Dir=ctrl.motor.DIR_FWD, ["Resp"] = payload.Cmd})
  -- print("Stepper dir fwd")
end

function DirRev(payload)
  ctrl.motor.dirRev()
  cayenn.send({["TransId"] = payload.TransId, Dir=ctrl.motor.DIR_REV, ["Resp"] = payload.Cmd})
  -- print("Stepper dir rev")
end