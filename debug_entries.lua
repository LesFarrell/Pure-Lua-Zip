-- Portable debug helper: inspect central directory entries for dbg.zip
local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir
-- Load local test harness (if present) and open the debug zip file relative
-- to the repository. This avoids hard-coded absolute paths.
dofile(base .. sep .. 'test.lua')
local zip = base .. sep .. 'dbg.zip'
local f = io.open(zip, 'rb')
local e,err = find_eocd_and_zip64(f)
print('eocd', e and (e.entries..','..e.cd_size..','..e.cd_offset) or err)
f:seek('set', e.cd_offset)
local cd = f:read(e.cd_size)
print('cd len', #cd)
-- debug_entries.lua
-- Portable debug helper: inspect central directory entries for dbg.zip
local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir

-- Load local test harness (if present) and open the debug zip file relative
-- to the repository. This avoids hard-coded absolute paths.
dofile(base .. sep .. 'test.lua')
local zip = base .. sep .. 'dbg.zip'
local f = io.open(zip, 'rb')
local e,err = find_eocd_and_zip64(f)
print('eocd', e and (e.entries..','..e.cd_size..','..e.cd_offset) or err)
f:seek('set', e.cd_offset)
local cd = f:read(e.cd_size)
print('cd len', #cd)
local i=1
while i <= #cd do
 local sig = cd:sub(i,i+3)
 if sig ~= string.char(0x50,0x4b,0x01,0x02) then break end
 local name_len = le16(cd,i+28)
 local extra_len = le16(cd,i+30)
 local comment_len = le16(cd,i+32)
 local header_offset = le32(cd,i+42)
 local name = cd:sub(i+46, i+45+name_len)
 print('Entry name', name, 'hdr', header_offset, 'comp', le32(cd,i+20), 'size', le32(cd,i+24), 'crc', string.format('%08X', le32(cd,i+16)))
 i = i + 46 + name_len + extra_len + comment_len
end
f:close()
