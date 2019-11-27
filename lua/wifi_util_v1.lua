-- Wifi Utility
-- 
-- To use:
-- wifi_util = require("wifi_util")
-- wifi_util.init(function() 
--   print("Got wifi")
--   print("My IP:" .. wifi_util.getIp() )
-- end)

local M = {}
-- M = {}

M.ssid = nil
M.password = nil

-- my ip will be set here once connected
M.myip = nil 

M.callbackOnConnect = nil

function M.init(callbackOnConnect)
  
  M.callbackOnConnect = callbackOnConnect
  
  -- see if already connected
  if M.myip ~= nil then
    print("We are already connected.")
    if M.callbackOnConnect ~= nil then
      node.task.post(1, M.callbackOnConnect)
    end
    return
  end 
  
  --register callback
  wifi.sta.on("got_ip", M.gotip)
  wifi.sta.on("connected", M.onConnected)
  wifi.sta.on("disconnected", M.onDisconnected)
  
  -- set as station
  wifi.mode(1)
  -- start wifi
  wifi.start()
   
  --connect to Access Point (DO save config to flash)
  station_cfg={}
  station_cfg.ssid = M.ssid 
  station_cfg.pwd = M.password 
  wifi.sta.config(station_cfg, true)
  -- print("Saved wifi name/password")
  
end

function M.onConnected()
  print("onConnected")
end

function M.onDisconnected()
  print("onDisconnected. Setting myip to nil.")
  M.myip = nil
end

function M.getIp()
  return M.myip
end

function M.gotip(ev, info)
  
  print("WiFi connected to " .. M.ssid .. ". IP: " .. info.ip .. ", Netmask: " .. info.netmask .. ", GW: " .. info.gw)
  M.myip = info.ip
  
 --unregister callback
  wifi.sta.on("got_ip", nil)
  
  -- if callback, call it
  if M.callbackOnConnect then 
    node.task.post(node.task.MEDIUM_PRIORITY, M.callbackOnConnect)
  end
  
end

return M
