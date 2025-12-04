-- inspect_cd.lua
-- Read the central directory signature position from dbg.zip (repo-relative)
local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir
local dbg_zip = base .. sep .. 'dbg.zip'
local f = io.open(dbg_zip, 'rb')
local d = f:read('*a')
f:close()
local pos = d:find('\x50\x4b\x01\x02')
print('cd pos', pos)
if not pos then return end
local function le32(s,i)
 i=i or 1
 return (s:byte(i) or 0) + (s:byte(i+1) or 0)*256 + (s:byte(i+2) or 0)*65536 + (s:byte(i+3) or 0)*16777216
end
local header_offset = le32(d,pos+42)
print('header_offset (from cd):', header_offset)
print('local sig at that offset:', string.format('%02X%02X%02X%02X', d:byte(header_offset+1), d:byte(header_offset+2), d:byte(header_offset+3), d:byte(header_offset+4)))
