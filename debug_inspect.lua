-- debug_inspect.lua
-- Create a small dbg.zip in the repo and inspect its central directory
local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir

-- If a project test harness exists, run it (non-fatal)
pcall(function() dofile(base .. sep .. 'test.lua') end)

local outzip = base .. sep .. 'dbg.zip'
pcall(function() os.remove(outzip) end)
local zw, err = ZipWriter.new(outzip, {compress = false})
if not zw then print('create failed', err); os.exit(1) end
zw:add_data('hello.txt','Hello World')
zw:close()

local f = io.open(outzip,'rb')
local data = f:read('*a')
f:close()

local pos = data:find('\x50\x4b\x01\x02')
if not pos then print('central not found') os.exit(1) end
print('central at', pos)
local name_len = (data:byte(pos+28) or 0) + ((data:byte(pos+29) or 0)*256)
print('name_len', name_len)
local name = data:sub(pos+46, pos+45+name_len)
print('name bytes:', #name, name)
print('hexdump of central start:', (data:sub(pos, pos+100)))
-- debug_inspect.lua
-- Create a small dbg.zip in the repo and inspect its central directory
local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir

-- If a project test harness exists, run it (non-fatal)
pcall(function() dofile(base .. sep .. 'test.lua') end)

-- debug_inspect.lua
-- Create a small dbg.zip in the repo and inspect its central directory
local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir

-- If a project test harness exists, run it (non-fatal)
pcall(function() dofile(base .. sep .. 'test.lua') end)

local outzip = base .. sep .. 'dbg.zip'
pcall(function() os.remove(outzip) end)
local zw, err = ZipWriter.new(outzip, {compress = false})
if not zw then print('create failed', err); os.exit(1) end
zw:add_data('hello.txt','Hello World')
zw:close()

local f = io.open(outzip,'rb')
local data = f:read('*a')
f:close()

local pos = data:find('\x50\x4b\x01\x02')
if not pos then print('central not found') os.exit(1) end
print('central at', pos)
local name_len = (data:byte(pos+28) or 0) + ((data:byte(pos+29) or 0)*256)
print('name_len', name_len)
local name = data:sub(pos+46, pos+45+name_len)
print('name bytes:', #name, name)
print('hexdump of central start:', (data:sub(pos, pos+100)))
local outzip = base .. sep .. 'dbg.zip'
