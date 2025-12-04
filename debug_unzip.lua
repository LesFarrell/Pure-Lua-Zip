-- debug_unzip.lua
-- Create a small dbg.zip in the repo and exercise unzip_file.
local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir

-- Optionally load a local test helper if present; ignore errors.
pcall(function() dofile(base .. sep .. 'test.lua') end)

local outzip = base .. sep .. 'dbg.zip'
local outdir = base .. sep .. 'dbg_out'
pcall(function() os.remove(outzip) end)
local zw = ZipWriter.new(outzip, {compress=false})
zw:add_data('hello.txt','Hello World')
zw:close()
local ok, err = unzip_file(outzip, outdir)
print('unzip returned', ok, err)
local f = io.open(outdir..sep..'hello.txt','rb')
if not f then print('extracted file not found') else print('extracted file size', f:seek('end')); f:close() end
