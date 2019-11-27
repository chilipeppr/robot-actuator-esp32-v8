-- TCP Socket
-- Creates connections, manages them, let's you send lots of data
--
-- To use:
-- wifi_util = require("wifi_util")
-- tcp = require("tcp_client")

-- data = {}
-- data[1] = '{"JsonTag":"{\\"MemRemain\\":293300,\\"TransId\\":1,\\"Resp\\":\\"Mem\\"}","MyDeviceId":"chip:0xad30aea4252c-ip:10.0.0.10"}'
-- data[2] = '{"JsonTag":"{\\"MemRemain\\":93300,\\"TransId\\":1,\\"Resp\\":\\"Mem\\"}","MyDeviceId":"chip:0xad30aea4252c-ip:10.0.0.10"}'
-- data[3] = '{"JsonTag":"{\\"MemRemain\\":493300,\\"TransId\\":1,\\"Resp\\":\\"Mem\\"}","MyDeviceId":"chip:0xad30aea4252c-ip:10.0.0.10"}'
  
-- wifi_util.init(function() 
--   print("Got wifi")
--   print("My IP:" .. wifi_util.getIp() )
--   tcp.init("10.0.0.233", 8988)
--   tcp.send(data, function() print("Yay. done!") end)
-- end)

local m = {}
-- m = {}

-- wifi_util = require("wifi_util")

m._dataTable = {}
-- m._cb = nil 
m._sck = nil
m._ip = nil
m._isConnecting = false
m._isDisconnected = true 

m._isDebug = false

function m.init(ip, port)
  m._ip = ip 
  m._port = port 
end

-- data should be a table of strings, i.e. an array of strings
-- we queue it up and then send one after the other
function m.send(dataTable, callback)
  
  -- we need to queue up this dataTable
  if type(dataTable) == "table" then
    -- m._dataTable = dataTable 
  elseif type(dataTable) == "string" then
    dataTable = {dataTable}
  else 
    -- print("You need to pass in a table of strings or a string as 1st param. Returning.")
    return 
  end
  -- m._cb = callback

  -- append to end of queue
  for i,v in ipairs(dataTable) do
    local item = {}
    item.str = dataTable[i] 
    item.cb = nil
    -- see if this is the last send item, if so make it have callback
    -- that way callback only happens on last item sent from this send request
    if i == table.maxn(dataTable) then item.cb = callback end
    table.insert(m._dataTable, item)
  end

  -- see if we have a connection to this ip already open
  if m._sck ~= nil then 
    -- yes, we have a connection already!
    -- trigger the send 
    m.doSend()
  else 
    m.createConnection()
  end 
  
end

function m.createConnection()
  
  if m._isConnecting then
    if m._isDebug then
      print("Already trying to connect. Returning.")
    end
    return 
  end 
  
  m._isConnecting = true
  if m._isDebug then
    print("Connecting to IP: "..m._ip..", port:"..m._port)
  end
  m._sck = net.createConnection(net.TCP)
  -- Wait for connection before sending.
  m._sck:on("connection", m.onConnection)
  m._sck:on("disconnection", m.onConnection)
  m._sck:on("reconnection", m.onConnection)
  m._sck:on("sent", m.onSent)
  m._sck:connect(m._port, m._ip)
  -- after we connect, we get callback, which then calls m.doSend()
end

function m.doSend()

  if m._isDebug then
    print("m.doSend. m._dataTable:",m._dataTable)
  end
  
  if m._dataTable ~= nil and #m._dataTable > 0 then
    
    -- see if we got disconnected 
    if m._isDisconnected then
      if m._isDebug then
        print("Seems like got disconnected. Reconnecting...")
      end
      m.createConnection()
      -- we will get a callback on connection, which will re-call this function
      return 
    end 
    
    if m._isDebug then
      print("Sending. m._dataTable items:"..#m._dataTable)
    end
    
    local item = m._dataTable[1] 
    -- local val = item.str
    if m._isDebug then
      print("Sending: "..item.str)
    end
    
    local result, err = pcall(function() m._sck:send(item.str) end)
    if result == true then 
      -- call was good
      -- remove item from queue
      local qItem = table.remove(m._dataTable, 1)
      -- see if we need to do the callback, if this qItem has one 
      if qItem.cb ~= nil then 
        -- yes, there was a callback. post it.
        -- print("Doing callback.")
        node.task.post(node.task.LOW_PRIORITY, qItem.cb)
      end 
    else 
      -- call was bad, so error
      -- print("Err trying to send. Probably not connected. err:", err)
      -- print("Reconnecting...")
      m.createConnection()
    end
  else
    -- localSocket:close()
    -- m._dataTable = nil
    -- print("Done sending.")
    -- if m._cb ~= nil then 
    --   print("Doing callback.")
    --   node.task.post(node.task.MEDIUM_PRIORITY, m._cb) 
    --   m._cb = nil
    -- end
  end
end

-- sends and removes the first element from the 'response' table
function m.onSent(sck, val)
  -- print("Got onSent. sck:",sck,"val:",val)
  node.task.post(node.task.MEDIUM_PRIORITY, m.doSend)
end

function m.onConnection(sck, val)
  -- it looks like if val is null then got "connection"
  -- if val is 0 got "disconnection" but not sure, so using
  -- the pcall() on send() and the error as my indicator
  -- this is annoying though cuz inconsistent with docs
  
  -- print("Got onConnection. sck:",sck,"val:",val)
  
  if val == 0 then 
    -- this means disconnection 
    -- print("Got disconnected")
    m._isDisconnected = true
  else 
    -- this means got connection
    m._isDisconnected = false
    m._isConnecting = false
    m.doSend()
  end 
  
end

function m.onDisconnection(sck, val)
  -- print("Got onDisconnection. sck:",sck,"val:",val)
  -- local port, ip = sck:getpeer()
  m._sck = nil
end

function m.onReconnection(sck, val)
  -- print("Got onReconnection. sck:",sck,"val:",val)
end 

-- wifi_util.init(function() 
--   print("Got wifi")
--   print("My IP:" .. wifi_util.getIp() )
--   local data = {}
--   data[1] = '{"JsonTag":"{\\"MemRemain\\":193300,\\"TransId\\":1,\\"Resp\\":\\"Mem\\"}","MyDeviceId":"chip:0xad30aea4252c-ip:10.0.0.10"}'
--   data[2] = '{"JsonTag":"{\\"MemRemain\\":93300,\\"TransId\\":1,\\"Resp\\":\\"Mem\\"}","MyDeviceId":"chip:0xad30aea4252c-ip:10.0.0.10"}'
--   m.init("10.0.0.233", 8988)
--   m.send(data, function() print("Yay. done!") end)
-- end)

return m


