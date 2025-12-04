-- call_find_eocd.lua
-- Minimal helper: call find_eocd_and_zip64 on repo-relative dbg.zip
local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir

pcall(function() dofile(base .. sep .. 'test.lua') end)
local path = base .. sep .. 'dbg.zip'
local f = io.open(path, 'rb')
if not f then print('dbg.zip not found in repo root'); return end
local res = find_eocd_and_zip64(f)
for k,v in pairs(res or {}) do print(k,v) end
-- call_find_eocd.lua
-- Minimal helper: call find_eocd_and_zip64 on repo-relative dbg.zip
local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir

pcall(function() dofile(base .. sep .. 'test.lua') end)
local path = base .. sep .. 'dbg.zip'
local f = io.open(path, 'rb')
if not f then print('dbg.zip not found in repo root'); return end
local res = find_eocd_and_zip64(f)
for k,v in pairs(res or {}) do print(k,v) end
f:close()
  local res = find_eocd_and_zip64(f)
