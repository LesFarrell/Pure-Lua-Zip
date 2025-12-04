local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir
local zip = base .. sep .. 'dbg.zip'
local f = io.open(zip, 'rb')
local size=f:seek('end')
local scan = math.min(65536+22, size)
f:seek('end', -scan)
local tail = f:read(scan)
local sig = '\x50\x4b\x05\x06'
local pos = tail:find(sig, 1, true)
print('pos in tail', pos)
local off = size - scan + pos
print('off', off, 'size', size, 'scan', scan)
local e = tail:sub(pos, pos+21)
print('EOCD bytes len', #e)
for i=1,#e do io.write(string.format('%02X ', e:byte(i))) end; print('\n')
local function le16(s,i) i=i or 1; return (s:byte(i) or 0) + (s:byte(i+1) or 0)*256 end
local function le32(s,i) i=i or 1; return (s:byte(i) or 0) + (s:byte(i+1) or 0)*256 + (s:byte(i+2) or 0)*65536 + (s:byte(i+3) or 0)*16777216 end
print('total_entries', le16(e,11))
print('cd_size', le32(e,13))
print('cd_offset', le32(e,17))
f:close()
