-- Record Gcode and play it back

local m = {}
-- m = {}

m.fileName = "gcode.txt"

m._isFileAppend = false
m._isFileRead = false

function m.init()
  
  -- m.wipe()
  m.openAppend()
  
end

function m.openAppend()
  if m._isFileAppend then return end
  
  if m._isFileRead then
    -- need to close file so we can re-open for append
    m.close()
  end

  if file.open(m.fileName, "a") then
    print("Apppending")
    m._isFileAppend = true
  else
    print("Err opening file")
  end
  
  print("Initted Gcode file save/retrieve")
  
end

function m.openRead()
  if m._isFileRead then return end
  
  if file.open(m.fileName, "r") then
    print("Reading")
    m._isFileRead = true
  else
    print("Err opening file")
  end
  
end

function m.close()
  file.close()
  m._isFileAppend = false
  m._isFileRead = false
end

function m.write(line)
  
  if type(line) == "table" then
    line = sjson.encode(line)
  end
  
  m.openAppend()
  file.writeline(line)
end

function m.wipe()
  file.open(m.fileName, "w+")
  file.close()
  m._isFileAppend = false
end

function m.getNext()
  -- get the next line in the file
  if m._isFileAppend then
    -- we are in writing mode. need to seek back to start of file
    m.close()
    m.openRead()
  end
  
  local line = file.readline()
  print("line:", line)
  local obj = nil
  local err, msg
  if line ~= nil then
    isSuccess, obj = pcall(sjson.decode, line)
    if isSuccess then
      -- print("Good parse")
    else
      print("Got err parsing json. msg:", obj)
      obj = nil
    end
  end
  -- print("obj:", obj)
  return obj
end

-- m.init()
-- -- m.write('x')
-- m.write('{"step":100, "fr":200, "acc":50}')
-- m.write('{"step":-100, "fr":300, "acc":150}')
-- m.write('{"step":100, "fr":100, "acc":250}')
-- m.write('{"step":-100, "fr":400, "acc":350}')
-- -- m.close()
-- print(sjson.encode(m.getNext()))
-- m.write('{"step":-100, "fr":400, "acc":350}')

return m
