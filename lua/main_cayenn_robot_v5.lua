-- Main entry point for ChiliPeppr Robot Actuator
-- Stepper jogging/homing, Fan control, Temperature
-- We also report back status on a 1 second interval (temperature, fan, steps, current)

-- init cayenn
cayenn = require("cayenn_esp32_v4")

-- **** User Defined Variables **********
cayenn.ssid = "NETGEAR-main"
cayenn.password = "****"

-- opts = {
--   Name = "Wrist3",
--   Icon = "https://raw.githubusercontent.com/chilipeppr/widget-robot-axes/master/Wrist3.jpg",
--   Desc = "Actuator controller",
--   IsInvert = true,
-- }

opts = {
  Name = "Wrist2",
  Icon = "https://raw.githubusercontent.com/chilipeppr/widget-robot-axes/master/Wrist2.jpg",
  Desc = "Actuator controller",
  IsInvert = false,
}

ignoreIp = "10.0.0.56"
-- **** End User Defined Variables **********

-- init libraries
cayenn = require("cayenn_esp32_v4")
json = sjson -- map sjson to json
queue = require("queue") -- Command queue
ctrl = require("gcode_jog_btns_v2") -- gets you led, motor, jog, endstop, etc.
dofile("commands_v1.lc") -- include the command list

-- Init the control library which contains all hardware control
ctrl.init({
  isInvert = opts.IsInvert
})

-- Store SPJS server ip's (can be more than one)
servers = {}

-- we can be set as master from ChiliPeppr
-- if we are, it's our job to send the signal wire high/lows
-- we should also get all the receipts back from each slave device 
-- for each command so we know we can send the signal for the next cmd 
isMaster = false

-- This is called when an incoming cmd comes in
-- from the network, i.e. from SPJS. These are TCP commands so
-- they are guaranteed to come in (vs UDP which could drop and has
-- its own callback function further down.)
function onCmd(payload)
  
  if (type(payload) == "table") then
    
    if payload.Cmd ~= nil then
      print("Got incoming Cayenn cmd: " .. payload.Cmd .. ", JSON: " .. json.encode(payload))
      -- see if we have a function to handle this. _G has all global functions in it
      if _G[payload.Cmd] then
        _G[payload.Cmd](payload)
        -- print("Handled by global func")
        return
      end
    else 
      print("Got incoming Cayenn with no cmd. JSON: " .. json.encode(payload))
    end 
    
    -- These are your custom commands you are implementing
    -- for this Cayenn device
    if payload.Cmd == "SetAsMaster" then
      -- If we are master, we have to get a "Play" command,
      -- a "Pause" command, and a "Stop" command.
    
    elseif payload.Cmd == "Restart" then
      cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd})
      node.restart()
    elseif payload.Cmd == "TestStart" then
    
      -- Start loop on stepper 
      ctrl.jog.testStart()
      -- cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd, ["Hz"] = payload.Hz, ["Duty"] = actualDuty})
      cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd})
      print("Started loop test on stepper")
      
    elseif payload.Cmd == "TestStop" then
    
      ctrl.jog.testStop()
      cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd})
      print("Stopped loop test on stepper")

    -- Below are more standard commands you should always support
    elseif payload.Cmd == "ResetCtr" then
      -- cnc.resetIdCounter()
      cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd, ["Ctr"] = cnc.getIdCounter()})
    elseif payload.Cmd == "GetCtr" then
      cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd, ["Ctr"] = cnc.getIdCounter()})
    elseif payload.Cmd == "GetQ" then
      -- this method will send slowly as not to overwhelm
      -- queue.send(function(t) cayenn.send(t); end, payload.TransId)
    elseif payload.Cmd == "WipeQ" then
      queue.wipe()
      cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd})
    elseif payload.Cmd == "CmdQ" then
      -- queuing cmd. we must have ID.
      if payload.Id == nil then
        -- print("Error queuing command. It must have an ID")
        return
      end
      if payload.RunCmd == nil then
        -- print("Error queuing command. It must have a RunCmd like RunCmd:{Cmd:AugerOn,Speed:10}.")
        return
      end
      -- wipe the peerIp cuz don't need it
      payload.peerIp = nil
      -- print("Queing command")
      --queue[payload.Id] = payload.RunCmd
      payload.RunCmd.Id = payload.Id
      queue.add(payload.RunCmd)
      -- print("New queue: " .. cjson.encode(queue))
      cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd, ["Id"] = payload.Id})
    elseif payload.Cmd == "Mem" then
      cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd, ["MemRemain"] = node.heap()})
    elseif payload["Announce"] ~= nil then
      -- do nothing. 
      if payload.Announce == "i-am-your-server" then
        -- store this ip
        -- so we know what our SPJS server is
        
        -- we should get a ServerIp, but should also get peerIp
        -- see if they are the same. latest nodemcu firmware seems
        -- to give us a peerIp now.
        local ip = payload.ServerIp
        if ip == nil then
          ip = payload.peerIp
        end
        if ip == nil then
          print("Err: Did not get ip from server.")
        else
          -- see if in ignore list
          if (ip == ignoreIp) then
            print("Got server to ignore: "..ip)
          else
            
            -- we got a server we want, see if we already
            -- got this server and initted our TCP connection back 
            if servers[ip] then 
              print("We are already connected back to this server.")
            else 
              servers[ip] = true
              print("Got a server:" .. json.encode(servers))
              -- connect tcp_client back to the server 
              cayenn.initTcpSend(ip)
              
              -- start sending status
              -- statusStart()
              ctrl.led.pulse(0,0,80)
            end
          end
        end
      end
    else
      cayenn.send({["TransId"] = payload.TransId, ["Resp"] = payload.Cmd, ["Err"] = "Unsupported cmd"})
      -- print("Got cmd we do not understand. Huh?")
    end
  else
    -- If we are sent Cayenn commands that aren't JSON, they
    -- will get here. However, JSON should always be used.
    -- print("is string")
    -- print("Got incoming Cayenn cmd. str: ", payload)
  end
  
end

-- This callback is called when an incoming UDP broadcast 
-- comes in to this device. Typically this is just for 
-- Cayenn Discover requests to figure out what devices are on 
-- the network
function onIncomingBroadcast(cmd)
  -- print("Got incoming UDP cmd: ", cmd)
  if (type(cmd) == "table") then
    if cmd["Cayenn"] ~= nil then
      if cmd.Cayenn == "Discover" then
        -- somebody is asking me to announce myself
        cayenn.sendAnnounceBroadcast()
      else
        -- print("Do not understand incoming Cayenn cmd")
      end
    -- elseif cmd["Announce"] ~= nil then
    --   if cmd.Announce == "i-am-your-server" then
    --     -- we should store the server address so we can send
    --     -- back TCP
    --     print("Got a server announcement. Cool. Store it.")
    --     print("cmd:" .. json.encode(cmd))
    --     servers[cmd.ip] = true
    --     print("Got a server:" .. json.encode(servers))
    --   else 
    --     -- print("Got announce but not from a server. Huh?")
    --   end 
    -- else 
    --   -- print("Do not understand incoming UDP cmd")
    end
    
  else 
    -- print("Got incoming UDP as string")
  end
end

-- We get this callback when we are Wifi connected
function onConnected()
  print("Got callback after connected.")

  -- start sending status
  -- stat.start()
  
  ctrl.led.pulse(0,80,0)
end

-- Get stat library
stat = require("status_v1")
stat.init({
  ctrl = ctrl,
  cayenn = cayenn,
  fan = fan,
})

cnc = {}
cnc.getIdCounter = function() return 0 end

-- Add listener to incoming Cayenn network commands
cayenn.addListenerOnIncomingCmd(onCmd)
cayenn.addListenerOnIncomingUdpCmd(onIncomingBroadcast)
cayenn.addListenerOnConnected(onConnected)

-- Init Cayenn
cayenn.init(opts)

-- Setup our command queue
queue.init()

print("Mem:" .. node.heap())


