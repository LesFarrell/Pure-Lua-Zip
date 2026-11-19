-- Test runner for ziptool.lua and zip_cli.lua.
-- Usage: lua tests/run_tests.lua

local sep = package.config:sub(1,1)
local src = debug.getinfo(1, 'S').source or ''
local dir = src:match('@?(.*[\\/])') or './'
dir = dir:gsub('[\\/]+$', '')
local base = dir:find('[\\/]') and dir:gsub('[\\/][^\\/]+$', '') or '.'

local function P(...)
  local parts = {...}
  local prefix = base
  for i = 1, #parts do
    if parts[i] and parts[i] ~= '' then prefix = prefix .. sep .. parts[i] end
  end
  return prefix
end

local ziptool = dofile(P('ziptool.lua'))
local ZipWriter, unzip_file = ziptool.ZipWriter, ziptool.unzip_file
local cli_path = P('zip_cli.lua')

local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function u32(n) return string.char(n % 256, math.floor(n/256)%256, math.floor(n/65536)%256, math.floor(n/16777216)%256) end
local function u64(n) return u32(n % 4294967296) .. u32(math.floor(n / 4294967296)) end

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read('*a')
  f:close()
  return d
end

local function write_file(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end

local function rm(path)
  if sep == '\\' then
    os.execute('cmd /c rmdir /s /q "' .. path .. '" >nul 2>&1')
    pcall(os.remove, path)
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end

local function mkdir(path)
  if sep == '\\' then os.execute('cmd /c mkdir "' .. path .. '" >nul 2>&1')
  else os.execute('mkdir -p "' .. path .. '"') end
end

local function ok(assertion, msg)
  if not assertion then error(msg or 'assertion failed') end
end

-- Build a minimal ZIP with the given entries: {name=, data=, method=, crc=}.
local function build_zip(entries)
  local locals, centrals, offset = {}, {}, 0
  for _, e in ipairs(entries) do
    local data, name = e.data or '', e.name
    local crc = e.crc or ziptool.crc32(data)
    local method = e.method or 0
    local lh = 'PK\x03\x04' .. u16(20) .. u16(0) .. u16(method) .. u16(0) .. u16(0x21)
      .. u32(crc) .. u32(#data) .. u32(#data) .. u16(#name) .. u16(0) .. name
    locals[#locals+1] = lh
    locals[#locals+1] = data
    centrals[#centrals+1] = 'PK\x01\x02' .. u16(20) .. u16(20) .. u16(0) .. u16(method)
      .. u16(0) .. u16(0x21) .. u32(crc) .. u32(#data) .. u32(#data)
      .. u16(#name) .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(0) .. u32(offset) .. name
    offset = offset + #lh + #data
  end
  local cd = table.concat(centrals)
  local eocd = 'PK\x05\x06' .. u16(0) .. u16(0) .. u16(#entries) .. u16(#entries)
    .. u32(#cd) .. u32(offset) .. u16(0)
  return table.concat(locals) .. cd .. eocd
end

local results = {}

local function test_basic()
  local outzip, outdir = P('test_basic.zip'), P('out_basic')
  pcall(os.remove, outzip); rm(outdir)
  local zw, err = ZipWriter.new(outzip, {compress = false})
  ok(zw, 'failed to create ZipWriter: ' .. tostring(err))
  ok(zw:add_data('hello.txt', 'Hello World'))
  ok(zw:close())
  local ok2, err2 = unzip_file(outzip, outdir)
  ok(ok2, 'unzip failed: ' .. tostring(err2))
  ok(read_file(P('out_basic', 'hello.txt')) == 'Hello World', 'contents mismatch')
  rm(outdir); os.remove(outzip)
  results[#results+1] = 'test_basic: PASS'
end

local function test_deflate()
  local outzip, outdir = P('test_deflate.zip'), P('out_deflate')
  pcall(os.remove, outzip); rm(outdir)
  local data = string.rep('ABCDEF0123456789', 1024)
  local zw = assert(ZipWriter.new(outzip, {compress = true, level = 6}))
  ok(zw:add_data('big.txt', data))
  ok(zw:close())
  local ok2, err2 = unzip_file(outzip, outdir)
  ok(ok2, 'unzip failed: ' .. tostring(err2))
  ok(read_file(P('out_deflate', 'big.txt')) == data, 'deflate roundtrip mismatch')
  rm(outdir); os.remove(outzip)
  results[#results+1] = 'test_deflate: PASS'
end

local function test_deflate_bytes()
  -- Fixed-Huffman literal blocks match zlib byte-for-byte.
  local function hex(s)
    return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
  end
  ok(hex(ziptool.deflate_lz77('a', 6)) == '4b0400', 'non-standard deflate output for literal')
  ok(hex(ziptool.deflate_lz77('', 6)) == '0300', 'non-standard deflate output for empty input')
  results[#results+1] = 'test_deflate_bytes: PASS'
end

local function test_deflate_roundtrips()
  local samples = {'a', 'ab', 'abc', 'aaaa', string.rep('abc', 50), string.rep('hello world ', 20), string.char(0,1,255,128)}
  for _, data in ipairs(samples) do
    for _, level in ipairs({1, 6, 9}) do
      local comp = ziptool.deflate_lz77(data, level)
      local out, err = ziptool.inflate_deflate(comp)
      ok(out == data, 'deflate roundtrip failed for len ' .. #data .. ' level ' .. tostring(level) .. ': ' .. tostring(err))
    end
  end
  results[#results+1] = 'test_deflate_roundtrips: PASS'
end

local function test_inflate_edge_cases()
  local out, err = ziptool.inflate_deflate('')
  ok(out == nil and err, 'empty deflate stream must fail, not hang')
  out = ziptool.inflate_deflate('\x01\x03\x00\xfc\xffabc')
  ok(out == 'abc', 'stored deflate block failed')
  results[#results+1] = 'test_inflate_edge_cases: PASS'
end

local function test_cli_force_deflate_dirs()
  local outzip, srcdir = P('test_cli_force.zip'), P('test_src_dir')
  pcall(os.remove, outzip); rm(srcdir); rm(P('out_cli_force'))
  mkdir(srcdir)
  write_file(P('test_src_dir', 'tiny.txt'), 'x')
  os.execute('lua "' .. cli_path .. '" --force-compress "' .. outzip .. '" "' .. srcdir .. '"')
  local entries = assert(ziptool.list_zip(outzip))
  local found
  for _, e in ipairs(entries) do
    if e.name:match('tiny.txt$') then found = e; break end
  end
  ok(found, 'tiny.txt not found in archive')
  ok(found.method == 8, 'tiny.txt was not DEFLATE (method=' .. tostring(found.method) .. ')')
  rm(srcdir); os.remove(outzip)
  results[#results+1] = 'test_cli_force_deflate_dirs: PASS'
end

local function test_zip_dir_vs_cli()
  local base_dir, out_cli, out_lib = P('test_dir_compare'), P('out_cli.zip'), P('out_lib.zip')
  rm(base_dir); pcall(os.remove, out_cli); pcall(os.remove, out_lib)
  mkdir(base_dir); mkdir(P('test_dir_compare', 'sub'))
  write_file(P('test_dir_compare', 'a.txt'), 'hello')
  write_file(P('test_dir_compare', 'sub', 'b.txt'), 'world')
  os.execute('lua "' .. cli_path .. '" "' .. out_cli .. '" "' .. base_dir .. '"')
  ok(ziptool.zip_dir(out_lib, base_dir, {compress = true, level = 6}))
  local e_cli = assert(ziptool.list_zip(out_cli))
  local e_lib = assert(ziptool.list_zip(out_lib))
  local map = {}
  for _, e in ipairs(e_lib) do map[e.name] = e.method end
  for _, e in ipairs(e_cli) do
    ok(map[e.name] ~= nil, 'entry missing in lib zip: ' .. tostring(e.name))
    ok(map[e.name] == e.method, 'method mismatch for ' .. e.name)
  end
  rm(base_dir); os.remove(out_cli); os.remove(out_lib)
  results[#results+1] = 'test_zip_dir_vs_cli: PASS'
end

local function test_store_when_larger()
  local forced, unforced = P('forced.zip'), P('unforced.zip')
  pcall(os.remove, forced); pcall(os.remove, unforced)
  local zw = assert(ZipWriter.new(forced, {compress = true, force_deflate = true}))
  ok(zw:add_data('x.txt', 'x')); ok(zw:close())
  zw = assert(ZipWriter.new(unforced, {compress = true}))
  ok(zw:add_data('x.txt', 'x')); ok(zw:close())
  ok(ziptool.list_zip(forced)[1].method == 8, 'force_deflate must use DEFLATE')
  ok(ziptool.list_zip(unforced)[1].method == 0, 'incompressible data should be stored')
  os.remove(forced); os.remove(unforced)
  results[#results+1] = 'test_store_when_larger: PASS'
end

local function test_streamed_methods()
  local src, zipped, outdir = P('big.bin'), P('big.zip'), P('out_big')
  local data = string.rep('0123456789abcdef', 70000)
  write_file(src, data); rm(outdir); pcall(os.remove, zipped)
  local zw = assert(ZipWriter.new(zipped, {compress = true, level = 6}))
  ok(zw:add_file(src, 'big.bin')); ok(zw:close())
  local lh = read_file(zipped):sub(1, 30)
  ok(lh:byte(9) + lh:byte(10) * 256 == 8, 'local header method must be DEFLATE')
  ok(ziptool.list_zip(zipped)[1].method == 8, 'central directory method must be DEFLATE')
  ok(unzip_file(zipped, outdir))
  ok(read_file(P('out_big', 'big.bin')) == data, 'streamed roundtrip mismatch')

  -- Incompressible data should be stored even when compression is requested.
  math.randomseed(12345)
  local noise = {}
  for i = 1, 70000 * 16 do noise[i] = string.char(math.random(0, 255)) end
  write_file(src, table.concat(noise))
  pcall(os.remove, zipped); rm(outdir)
  zw = assert(ZipWriter.new(zipped, {compress = true}))
  ok(zw:add_file(src, 'big.bin')); ok(zw:close())
  lh = read_file(zipped):sub(1, 30)
  ok(lh:byte(9) + lh:byte(10) * 256 == 0, 'local header must be patched to STORE')
  ok(ziptool.list_zip(zipped)[1].method == 0, 'incompressible stream must be stored')
  ok(unzip_file(zipped, outdir))
  ok(read_file(P('out_big', 'big.bin')) == table.concat(noise), 'stored stream roundtrip mismatch')

  pcall(os.remove, zipped); rm(outdir)
  zw = assert(ZipWriter.new(zipped, {compress = false}))
  ok(zw:add_file(src, 'big.bin')); ok(zw:close())
  lh = read_file(zipped):sub(1, 30)
  ok(lh:byte(9) + lh:byte(10) * 256 == 0, 'stored local header method must be 0')
  ok(ziptool.list_zip(zipped)[1].method == 0, 'stored central directory method must be 0')
  rm(src); rm(outdir); os.remove(zipped)
  results[#results+1] = 'test_streamed_methods: PASS'
end

local function test_zip64_locator()
  local path = P('zip64_locator.zip')
  pcall(os.remove, path)
  local content = build_zip({{name = 'z64.txt', data = 'ok'}})
  local cd_pos = content:find('PK\x01\x02', 1, true)
  ok(cd_pos, 'test setup failed')
  local prefix = content:sub(1, cd_pos - 1)
  local cd_and_eocd = content:sub(cd_pos)
  local eocd_pos = cd_and_eocd:find('PK\x05\x06', 1, true)
  local cd = cd_and_eocd:sub(1, eocd_pos - 1)
  local eocd64 = 'PK\x06\x06' .. u64(44) .. u16(45) .. u16(45) .. u32(0) .. u32(0)
    .. u64(1) .. u64(1) .. u64(#cd) .. u64(#prefix)
  local locator = 'PK\x06\x07' .. u32(0) .. u64(#prefix + #cd) .. u32(1)
  local classic = 'PK\x05\x06' .. u16(0) .. u16(0) .. u16(0xFFFF) .. u16(0xFFFF)
    .. u32(0xFFFFFFFF) .. u32(0xFFFFFFFF) .. u16(0)
  write_file(path, prefix .. cd .. eocd64 .. locator .. classic)
  local entries, err = ziptool.list_zip(path)
  ok(entries, 'ZIP64 locator parsing failed: ' .. tostring(err))
  ok(#entries == 1 and entries[1].name == 'z64.txt', 'ZIP64 entry missing')
  os.remove(path)
  results[#results+1] = 'test_zip64_locator: PASS'
end

local function test_zip_slip()
  local path, outdir = P('slip.zip'), P('out_slip')
  rm(outdir); rm(P('escape.txt')); pcall(os.remove, path)
  write_file(path, build_zip({{name = '..\\escape.txt', data = 'bad'}}))
  mkdir(outdir)
  ok(unzip_file(path, outdir))
  ok(read_file(P('escape.txt')) == nil, 'entry escaped the output directory')
  ok(read_file(P('out_slip', 'escape.txt')) == 'bad', 'sanitized entry was not extracted')
  rm(outdir); rm(P('escape.txt')); os.remove(path)
  results[#results+1] = 'test_zip_slip: PASS'
end

local function test_bad_crc()
  local path, outdir = P('badcrc.zip'), P('out_badcrc')
  rm(outdir); pcall(os.remove, path)
  write_file(path, build_zip({{name = 'bad.txt', data = 'X', crc = 1}}))
  mkdir(outdir)
  local result, err = unzip_file(path, outdir)
  ok(result == nil and err, 'bad CRC should be reported')
  ok(read_file(P('out_badcrc', 'bad.txt')) == nil, 'file written before CRC verification')
  rm(outdir); os.remove(path)
  results[#results+1] = 'test_bad_crc: PASS'
end

local tests = {
  {'test_basic', test_basic}, {'test_deflate', test_deflate},
  {'test_deflate_bytes', test_deflate_bytes}, {'test_deflate_roundtrips', test_deflate_roundtrips},
  {'test_inflate_edge_cases', test_inflate_edge_cases},
  {'test_cli_force_deflate_dirs', test_cli_force_deflate_dirs},
  {'test_zip_dir_vs_cli', test_zip_dir_vs_cli},
  {'test_store_when_larger', test_store_when_larger},
  {'test_streamed_methods', test_streamed_methods},
  {'test_zip64_locator', test_zip64_locator},
  {'test_zip_slip', test_zip_slip}, {'test_bad_crc', test_bad_crc},
}

print('Running tests...')
for _, t in ipairs(tests) do
  local ok_run, err = pcall(t[2])
  if not ok_run then
    print(t[1] .. ' FAIL: ' .. tostring(err))
    os.exit(1)
  end
end
print('All tests passed:')
for _, r in ipairs(results) do print('  ' .. r) end
