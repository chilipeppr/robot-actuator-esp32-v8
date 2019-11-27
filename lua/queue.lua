------------------------------------------------
-- Cayenn Queue by using a file
local m = {}
-- m = {}

m.filename = "queue.txt"
m.tmrSend = nil

m.isFileOpen = false

function m.init()

  -- Initialise the pin to see if that lets a timer work
  -- gpio.config( { gpio={2}, dir=gpio.OUT } )
  m.tmrSend = tmr.create()
  m.tmrSend:register(10, tmr.ALARM_SEMI, m.onSend)
  
  -- make sure file exists
  if file.exists(m.filename) then
    -- good to go
  else
    m.wipe()
  end
end

-- Wipe the queue by deleting file, recreating it, and resetting counters
function m.wipe()
  file.remove(m.filename)
  file.open(m.filename, "w+")
  -- file.writeline("")
  -- make sure to reset the GetId so our gets start at top
  m.lastGetId = -1
  m.lastAddId = -1
  file.close()
  m.isFileOpen = false
end

-- Add to the queue
-- It must have an Id in the payload table and Id's must
-- be added in incrementing order
m.lastAddId = -1
function m.add(payload)
  
  -- make sure the id is greater than last id
  if payload.Id > m.lastAddId then
    -- good. we have an incrementing id
  else
    -- bad. we somehow are moving backwards
    print("Error. Got an ID < lastAddId. ID:" .. payload.Id .. ", lastAddId:" .. m.lastAddId)
    return
  end
  
  -- open 'queue.txt' in 'a+' mode to append
  file.open(m.filename, "a+")
  
  -- based on m.lastAddId we need to decide whether to write 
  -- empty lines or not
  if payload.Id == m.lastAddId + 1 then 
    -- we do not need to advance
  else 
    -- we need to write blank lines
    for ctr = m.lastAddId + 1, payload.Id - 1 do
      file.writeline("")
      print("Padded line:", ctr)
    end
  end 
  
  local ok, jsontag = pcall(cjson.encode, payload)
  if ok then
    -- write to the end of the file
    file.writeline(jsontag)
    -- print("Wrote line to file:" .. jsontag)
  else
    -- print("failed to encode jsontag for queue file!")
  end
  file.close()
  m.isFileOpen = false
  m.lastAddId = payload.Id 
end

-- Get queue item by ID
-- Goal is to keep file open so we can just move forward
-- so we don't slow down our retrievals re-opening from
-- the beginning each time
-- The format of our file is one line per id starting at 0
-- That way we just associate lines with ID's for expediency
-- If we get scattered id's, then we place in empty lines
m.lastGetId = -1
m.lastLine = nil
function m.getId(id)
  
  -- make sure file is open
  if m.isFileOpen == false then
    -- we need to open file
    file.open(m.filename, "r")
    m.isFileOpen = true
  end
  
  -- local line

  -- see if we get a lesser id, and if so, start back at -1
  if id < m.lastGetId then
    -- we need to just start back from the beginning
    file.close()
    file.open(m.filename, "r")
    m.isFileOpen = true
    m.lastGetId = -1
  end
  
  if id > m.lastGetId then
    -- advance the line forward to correct one
    for ctr = m.lastGetId + 1, id do
      m.lastLine = file.readline()
      -- print("Line:", id, ctr, line)
    end
  elseif id == m.lastGetId then
    -- don't move forward in file. just use last line
    -- line = m.lastLine
  end
  
  -- m.lastLine = line
  m.lastGetId = id
  
  -- print("Line:", m.lastLine)
  
  if m.lastLine == nil then
    return -1 -- to indicate EOF
  end
  
  -- parse json to table
  local succ, results = pcall(function()
  	return cjson.decode(m.lastLine)
  end)
  
  -- see if we could parse
  if succ then
  	--data = results
  	return results
  else
  -- 	print("Error parsing JSON")
  	return nil
  end
  
end

-- Send queue back to ChiliPeppr
-- this method sends back data slowly
m.lastSendId = 0
m.callback = nil
m.transId = nil
function m.send(callback, transId)
  -- reset ctr
  m.lastSendId = 0
  m.callback = callback
  m.transId = transId
  -- say we are starting
  m.callback({["TransId"] = m.transId, ["Resp"] = "GetQ", ["Start"] = 0})
  -- callback slowly and send q each time
  -- tmr.alarm(m.tmrSend, 2, tmr.ALARM_SEMI, m.onSend)
  -- create timer if not created
  -- m.tmrSend = tmr.create()
  m.tmrSend:start()
end

function m.onSend()
  -- get next line
  local cmd = queue.getId(m.lastSendId)
  if cmd == -1 then
    -- we are at eof
    m.callback({["TransId"] = m.transId, ["Resp"] = "GetQ", ["Finish"] = m.lastSendId})
    return
  end
  
  if cmd ~= nil then
    m.callback({["TransId"] = m.transId, ["Resp"] = "GetQ", ["Q"] = cmd})
  else
    -- if got back nil, it could be empty line
    -- so skip
    --m.callback({["TransId"] = m.transId, ["Resp"] = "GetQ", ["Finish"] = m.lastSendId})
  end
  
  m.lastSendId = m.lastSendId + 1
  -- tmr.start(m.tmrSend)
  m.tmrSend:start()
  
end

-- m.init()
return m
-- queue = m

