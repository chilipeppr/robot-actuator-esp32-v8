-- Cayenn Protocol for ChiliPeppr
-- This module does udp/tcp sending/receiving to talk with SPJS
-- or have the browser talk direct to this ESP32 device.
-- This module has methods for connecting to wifi, then initting
-- UDP servers, TCP servers, and sending a broadcast announce out.
-- The broadcast announce lets any listening SPJS know we're alive.
-- SPJS then reflects that message to any listening browsers like
-- ChiliPeppr so they know a device is available on the network.
-- Then the browser can send commands back to this device.

-- To use this library do:
-- cayenn = require("cayenn_esp32_v3")

-- json = require("json")
local json = sjson -- attach to esp32 library instead of my previous local json.lua
wifi_util = require("wifi_util_v1")
tcp = require("tcp_client")

local M = {}
-- M = {}

M.ssid = nil
M.password = nil

M.port = 8988
M.myip = nil
M.udpsock = nil
M.tcpsock = nil
M.jsonTagTable = nil

M.isInitted = false

-- When you are initting you can pass in tags to describe your device
-- You should use a format like this:
-- opts = {}
-- opts.Name = "LaserUV"
-- opts.Desc = "Control the BDR209 UV laser"
-- opts.Icon = "https://raw.githubusercontent.com/chilipeppr/widget-cayenn/master/laser.png"
-- opts.Widget = "com-chilipeppr-widget-laser"
-- cayenn.init(opts)
function M.init(jsonTagTable)
  
  -- setup wifi network name/pass
  wifi_util.ssid = M.ssid
  wifi_util.password = M.password
  
  -- save the jsonTagTable
  if jsonTagTable ~= nil then
    M.jsonTagTable = jsonTagTable
  end
  
  if M.isInitted then
    print("Already initted")
    return
  end
  
  print("Init...")

  -- figure out if i have an IP
  -- M.myip = wifi.sta.getip()
  if M.myip == nil then
    
    print("Connecting to wifi.")
    -- M.setupWifi()
    wifi_util.init(function() 
      print("Got wifi") 
      M.myip = wifi_util.getIp()
      -- node.task.post(1, M.init)
      M.init()
    end)

  else 
    print("My IP: " .. M.myip)
    M.isInitted = true

    -- create socket for outbound UDP sending
    M.udpsock = net.createUDPSocket()

    -- create server to listen to incoming udp
    M.initUdpServer()
    
    -- create server to listen to incoming tcp
    M.initTcpServer()
    
    -- send our announce
    M.sendAnnounceBroadcast(M.jsonTagTable)
  
    if M.listenerOnConnected ~= nil then
      M.listenerOnConnected()
    end
  end 
  
end

function M.createAnnounce(jsonTagTable)
  
  if M.myip == nil then
    print("Error doing announce with myip nil")
    return
  end 
  
  local a = {}
  a.Announce = "i-am-a-client"
  a.MyDeviceId = "chip:" .. node.chipid() .. "-ip:" .. M.myip -- .. "-mac:" .. wifi.sta.getmac()
  
  if jsonTagTable.Widget then
    a.Widget = jsonTagTable.Widget
    -- jsonTagTable.Widget = nil
  elseif M.jsonTagTable.Widget then
    a.Widget = M.jsonTagTable.Widget
  else
    a.Widget = "com-chilipeppr-widget-undefined"
  end
  
  -- see if there is a jsontagtable passed in as extra meta
  local jsontag = ""
  if jsonTagTable then
    ok, jsontag = pcall(json.encode, jsonTagTable)
    if ok then
      -- print("Adding jsontagtable" .. jsontag)
    else
      print("fail encode jsontag")
    end
  end

  a.JsonTag = jsontag
  
  local ok, jsonStr = pcall(json.encode, a)
  if ok then
    --print("Encoded json for announce: " .. json)
  else
    print("fail encode json")
  end
  print("Announce: " .. jsonStr)
  return jsonStr
end

-- send announce to broadcast addr so spjs 
-- knows of our existence
function M.sendAnnounceBroadcast(jsonTagTable)
  -- if M.isInitted == false then
  --   -- print("You must init first.")
  --   return 
  -- end
  if M.myip == nil then
    print("Err sending announce broadcast with nil myip")
    return
  end
  
  -- since getbroadcast() is not available on esp32
  -- then just figure it out manually
  local m1, m2, m3, m4 = string.match(M.myip, "(%d+)\.(%d+)\.(%d+)\.(%d+)")
  local bip = m1 .. "." .. m2 .. "." .. m3 .. ".255"
  -- local bip = wifi.sta.getbroadcast()
  -- print("Broadcast addr:" .. bip)
  
  -- if there was no jsonTagTable passed in, then use
  -- stored one 
  if not jsonTagTable then 
    jsonTagTable = M.jsonTagTable
  end 
  
  print("Announce to broadcast ip: " .. bip .. ", port: " .. M.port)
  -- M.sock:connect(M.port, bip)
  -- send 3 times since UDP is not guaranteed
  local announceMsg = M.createAnnounce(jsonTagTable)
  M.udpsock:send(M.port, bip, announceMsg)
  M.udpsock:send(M.port, bip, announceMsg)
  M.udpsock:send(M.port, bip, announceMsg)
  -- M.sock:close()
  
end

-- Workhorse of this library to send broadcast, UDP, or TCP msg back 
-- to SPJS so it can regurgitate to ChiliPeppr
-- Keep in mind that your custom payload is in jsonTagTable 
-- and that gets embedded in the larger JSON packet that
-- describes this device 

function M.sendBroadcast(jsonTagTable)
  M.sendUtility(jsonTagTable, "broadcast")
end

M._tcpClientIp = nil
function M.initTcpSend(ip)
  -- see if we have a tcp_client for this ip 
  if M._tcpClientIp == nil then
    print("Creating tcp_client for ip: "..ip)
    tcp.init(ip, 8988)
    M._tcpClientIp = ip 
  elseif M._tcpClientIp == ip then 
    print("Have tcp_client for ip: "..ip)
  else
    print("Already have tcp_client for other ip: "..M._tcpClientIp.." and you asked for ip: "..ip)
    print("We only support 1 IP for now. Sorry.")
  end
end 

function M.send(jsonTagTable, cb)
  
  if M.myip == nil then
    print("Err sending with myip nil")
    return
  end
  
  local jsonFinal = M.createJsonStrFromJsonTagTable(jsonTagTable)
  
  if M._tcpClientIp == nil then 
    print("You need to call initTcpSend(ip) first.")
    -- M.initTcpSend(ip)
    return
  end 
  
  print("Sending TCP to ip:"..M._tcpClientIp..", msg:"..jsonFinal)
  tcp.send(jsonFinal, function()
    -- print("Yay. Done sending.")
    if cb ~= nil then 
      node.task.post(node.task.MEDIUM_PRIORITY, cb)
    end 
  end)
end

function M.createJsonStrFromJsonTagTable(jsonTagTable)
-- we need to attach deviceid 
  local a = {}
  
  -- see if there is a jsontagtable passed in as extra meta
  local jsontag = ""
  if jsonTagTable then
    ok, jsontag = pcall(json.encode, jsonTagTable)
    if ok then
      -- print("Adding jsontagtable" .. jsontag)
    else
      print("fail encode jsontag")
      jsonTagTable = nil 
      jsontag = nil 
    end
  end

  a.JsonTag = jsontag
  jsontag = nil -- delete from memory
  jsonTagTable = nil -- delete from memory
  
  a.MyDeviceId = "chip:" .. node.chipid() .. "-ip:" .. M.myip --.. "-mac:" .. wifi.sta.getmac()

  local ok, jsonFinal = pcall(json.encode, a)
  if ok then
    --print("Encoded json for announce: " .. json)
  else
    print("fail encode json")
  end
  
  -- a = nil -- delete it 
  return jsonFinal
end 

-- function M.sendViaUdp(jsonTagTable, ip)
--   M.sendUtility(jsonTagTable, "udp", ip)
-- end

-- function M.sendViaTcp(jsonTagTable, ip)
--   M.sendUtility(jsonTagTable, "tcp", ip)
-- end

function M.sendUdp(jsonTagTable, cb)
  
  if M.myip == nil then
    print("Err cannot sendUdp with myip nil")
    return
  end
  
  local jsonFinal = M.createJsonStrFromJsonTagTable(jsonTagTable)
  
  if M._tcpClientIp == nil then 
    print("You need to call initTcpSend(ip) first.")
    -- M.initTcpSend(ip)
    return
  end 
  
  print("Sending UDP to ip: " .. M._tcpClientIp .. ", msg: " .. jsonFinal)
  M.udpsock:send(M.port, M._tcpClientIp, jsonFinal)
  
  if cb ~= nil then 
    node.task.post(node.task.MEDIUM_PRIORITY, cb)
  end 

end

-- Pass in IP of nil for broadcast or 
-- pass in IP addr as string to have UDP just sent there 
-- Or pass in table of IP's, i.e. array of IP's
function M.sendViaUdp(jsonTagTable, ip)
  
  local jsonFinal = M.createJsonStrFromJsonTagTable(jsonTagTable)
  
  
  -- local bip = wifi.sta.getbroadcast()
  if ip == nil then 
    -- they want to broadcast. figure out broadcast addr
    ip = {} 
    -- since getbroadcast() is not available on esp32
    -- then just figure it out manually
    local m1, m2, m3, m4 = string.match(M.myip, "(%d+)\.(%d+)\.(%d+)\.(%d+)")
    local bip = m1 .. "." .. m2 .. "." .. m3 .. ".255"
    print("Using broadcast addr for send. bip: "..bip)
    ip[bip] = true
  elseif type(ip) == "string" then 
    local ipStr = ip 
    ip = {}
    ip[ipStr] = true
  end 

  -- print("Sending UDP msg: " .. json .. " to ip: " .. bip)
  for key,value in pairs(ip) do 
    -- print(key,value) 

    -- UDP approach for viaMethod of UDP or Broadcast
    print("Sending UDP to ip: " .. key .. ", msg: " .. jsonFinal)
    M.udpsock:send(M.port, key, jsonFinal)

  end
  
end

-- this property and method let an external object attach a
-- listener to the incoming UDP cmd
M.listenerOnConnected = nil
function M.addListenerOnConnected(listenerCallback)
  M.listenerOnConnected = listenerCallback
  -- print("Attached listener to incoming UDP cmd")
end

function M.initUdpServer()
  M.udpServer = net.createUDPSocket()
  --M.udpServer:on("connection", M.onUdpConnection)
  M.udpServer:on("receive", M.onUdpRecv) 
  M.udpServer:listen(8988)
  port, ip = M.udpServer:getaddr()
  print(string.format("local UDP socket address / port: %s:%d", ip, port))
  print("UDP Server started on port 8988")
end

function M.onUdpConnection(sck)
  -- print("UDP connection.")
  --ip, port = sck:getpeer()
  --print("UDP connection. from: " .. ip)
end

function M.onUdpRecv(sck, data, port, ip)
  print("UDP Recv " .. data)
  
  print("UDP connection. from IP: " .. ip .. ", from port: " .. port)
  
  if (M.listenerOnIncomingUdpCmd) then
    -- see if json
    if string.sub(data,1,1) == "{" then
      -- catch json errors
      local succ, results = pcall(json.decode, data)
      
      -- see if we could parse
      if succ then
      	data = results --cjson.decode(data)
      	data.port = port 
      	data.ip = ip
        -- data.peerIp = peer
      else
      	print("Err parse JSON")
      	return
      end
      
    end
    M.listenerOnIncomingUdpCmd(data)
  end
end

-- this property and method let an external object attach a
-- listener to the incoming UDP cmd
M.listenerOnIncomingUdpCmd = nil
function M.addListenerOnIncomingUdpCmd(listenerCallback)
  M.listenerOnIncomingUdpCmd = listenerCallback
  -- print("Attached listener to incoming UDP cmd")
end

function M.removeListenerOnIncomingUdpCmd(listenerCallback)
  M.listenerOnIncomingUdpCmd = nil
  -- print("Removed listener on incoming UDP cmd")
end

function M.initTcpServer()
  M.tcpServer = net.createServer(net.TCP)
  M.tcpServer:listen(8988, M.onTcpListen)
  
  print("TCP Server started on port 8988")
end

function M.onTcpListen(conn)
  conn:on("receive", M.onTcpRecv)
end

function M.onTcpConnection(sck)
  -- print("TCP connection.")
  --ip, port = sck:getpeer()
  --print("UDP connection. from: " .. ip)
end

function M.onTcpRecv(sck, data)
  local peerPort, peerIp = sck:getpeer()
  print("TCP Recv " .. data .. ", peerIp:" .. peerIp .. ", peerPort:" .. peerPort)
  if (M.listenerOnIncomingCmd) then
    -- see if json
    if string.sub(data,1,1) == "{" then
      -- catch json errors
      local succ, results = pcall(json.decode, data)
      
      -- see if we could parse
      if succ then
      	data = results --cjson.decode(data)
        data.peerIp = peerIp
      else
      	print("Err parse JSON. results:" .. results)
      	return
      end
      
    end
    M.listenerOnIncomingCmd(data)
  end
end

-- this property and method let an external object attach a
-- listener to the incoming TCP command
M.listenerOnIncomingCmd = nil
function M.addListenerOnIncomingCmd(listenerCallback)
  M.listenerOnIncomingCmd = listenerCallback
  -- print("Attached listener to incoming TCP cmd")
end

function M.removeListenerOnIncomingCmd(listenerCallback)
  M.listenerOnIncomingCmd = nil
  -- print("Removed listener on incoming TCP cmd")
end

-- return M

-- opts = {}
-- opts.Name = "Sample Device"
-- opts.Desc = "Sample description of this device"
-- opts.Icon = "https://raw.githubusercontent.com/chilipeppr/cayenn-laseruv/master/lasericon.jpg"

-- M.init(opts)


return M

