local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir
-- Load local test harness and set debug zip path relative to repo
dofile(base .. sep .. 'test.lua')
local zip = base .. sep .. 'dbg.zip'
local f = io.open(zip, 'rb')
if not f then print('no zip'); os.exit(1) end
local eocd,err = find_eocd_and_zip64(f)
print('eocd:', eocd and (eocd.entries..','..eocd.cd_size..','..eocd.cd_offset) or tostring(err))
f:seek('set', eocd.cd_offset)
local cd = f:read(eocd.cd_size)
print('cd len', cd and #cd or 'nil')
-- debug_cdparse.lua
-- Parse central directory from dbg.zip (repo-relative)
local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir

dofile(base .. sep .. 'test.lua')
local zip = base .. sep .. 'dbg.zip'
local f = io.open(zip, 'rb')
if not f then print('no zip'); os.exit(1) end
local eocd,err = find_eocd_and_zip64(f)
print('eocd:', eocd and (eocd.entries..','..eocd.cd_size..','..eocd.cd_offset) or tostring(err))
f:seek('set', eocd.cd_offset)
local cd = f:read(eocd.cd_size)
print('cd len', cd and #cd or 'nil')
local i=1
while i <= #cd do
 local sig = cd:sub(i,i+3)
 if sig ~= string.char(0x50,0x4b,0x01,0x02) then break end
 local name_len = le16(cd,i+28)
 local extra_len = le16(cd,i+30)
 local comment_len = le16(cd,i+32)
 local header_offset = le32(cd,i+42)
 local name = cd:sub(i+46, i+45+name_len)
 print('entry:', name, 'hdr_off', header_offset, 'comp', le32(cd,i+20), 'size', le32(cd,i+24), 'crc', string.format('%08X', le32(cd,i+16)))
 i = i + 46 + name_len + extra_len + comment_len
end
f:close()
