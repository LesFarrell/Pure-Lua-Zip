-- Test runner for `ziptool.lua` (local repo version)
-- Usage: lua run_tests.lua

local sep = package.config:sub(1,1)

-- Determine the directory containing this test script and use it as the
-- repository root for paths. This avoids embedding user-specific absolute
-- paths and makes the tests portable.
local function script_dir()
  local src = debug.getinfo(1, 'S').source or ''
  local path = src:match('@?(.*[\\/])') or './'
  -- Remove trailing slash if present
  path = path:gsub('[\\/]+$', '')
  return path
end

-- Use the tests script's parent directory as the repository root. If this
-- test file lives in `tests/`, the parent will be the project root where
-- `ziptool.lua` and `zip_cli.lua` live.
local script = debug.getinfo(1, 'S').source or ''
local script_dir = script:match('@?(.*[\\/])') or './'
script_dir = script_dir:gsub('[\\/]+$', '')

-- If the script path is relative (e.g. 'tests/run_tests.lua') then
-- `script_dir` will be something like 'tests' with no directory separators.
-- In that case assume the current working directory is the repository root
-- (the common case when invoking `lua tests/run_tests.lua` from repo root).
local base
if script_dir:find('[\\/]') then
  -- Absolute or multi-component path: strip the final component to get parent
  base = script_dir:gsub('[\\/][^\\/]+$', '')
else
  -- Single component (likely 'tests'): use current working directory
  base = '.'
end

local libpath = base .. (sep == '\\' and '\\ziptool.lua' or '/ziptool.lua')
local cli_path = base .. (sep == '\\' and '\\zip_cli.lua' or '/zip_cli.lua')

local ziptool = dofile(libpath)
local ZipWriter = ziptool.ZipWriter
local unzip_file = ziptool.unzip_file

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read('*a')
  f:close()
  return d
end

local function rm(path)
  if sep == '\\' then
    os.execute('cmd /c rmdir /s /q "' .. path .. '" > nul 2>&1')
    pcall(os.remove, path)
  else
    os.execute('rm -rf ' .. path)
  end
end

local function ok(assertion, msg)
  if not assertion then error(msg or 'assertion failed') end
end

local results = {}

-- Test 1: basic create/extract store
local function test_basic()
  local outzip = base .. '\\test_basic.zip'
  local outdir = base .. '\\out_basic'
  pcall(function() os.remove(outzip) end)
  rm(outdir)

  local zw, err = ZipWriter.new(outzip, {compress = false})
  ok(zw, 'failed to create ZipWriter: ' .. tostring(err))
  zw:add_data('hello.txt', 'Hello World')
  zw:close()

  local ok2, err2 = unzip_file(outzip, outdir)
  ok(ok2, 'unzip failed: ' .. tostring(err2))
  local d = read_file(outdir .. sep .. 'hello.txt')
  ok(d == 'Hello World', 'contents mismatch: ' .. tostring(d))
  rm(outdir); os.remove(outzip)
  results[#results+1] = 'test_basic: PASS'
end

-- Test 2: deflate roundtrip
local function test_deflate()
  local outzip = base .. '\\test_deflate.zip'
  local outdir = base .. '\\out_deflate'
  pcall(function() os.remove(outzip) end)
  rm(outdir)

  local data = string.rep('ABCDEF0123456789', 1024) -- compressible
  local zw, err = ZipWriter.new(outzip, {compress = true, level = 6})
  ok(zw, 'failed to create ZipWriter: ' .. tostring(err))
  zw:add_data('big.txt', data)
  zw:close()

  local ok2, err2 = unzip_file(outzip, outdir)
  ok(ok2, 'unzip failed: ' .. tostring(err2))
  local d = read_file(outdir .. sep .. 'big.txt')
  ok(d == data, 'deflate roundtrip mismatch')
  rm(outdir); os.remove(outzip)
  results[#results+1] = 'test_deflate: PASS'
end

-- Test 3: CLI should force DEFLATE for directory inputs (even for tiny files)
local function test_cli_force_deflate_dirs()
  local outzip = base .. '\\test_cli_force.zip'
  local srcdir = base .. '\\test_src_dir'
  pcall(function() os.remove(outzip) end)
  rm(srcdir); rm(base .. '\\out_cli_force')
  -- create source directory and a very small file
  if sep == '\\' then
    os.execute('cmd /c mkdir "' .. srcdir .. '" > nul 2>&1')
  else
    os.execute('mkdir -p "' .. srcdir .. '"')
  end
  local f = io.open(srcdir .. sep .. 'tiny.txt', 'wb')
  ok(f, 'failed to create tiny file')
  f:write('x')
  f:close()

  -- invoke the CLI (zip_cli.lua) to create the archive forcing DEFLATE
  local cmd = 'lua "' .. cli_path .. '" --force-compress "' .. outzip .. '" "' .. srcdir .. '"'
  os.execute(cmd)

  local entries, err = ziptool.list_zip(outzip)
  ok(entries, 'list_zip failed: ' .. tostring(err))
  local found
  for _, e in ipairs(entries) do
    if e.name:match('tiny.txt$') then found = e; break end
  end
  ok(found, 'tiny.txt not found in archive')
  ok(found.method == 8, 'tiny.txt was not DEFLATE (method=' .. tostring(found.method) .. ')')

  -- cleanup
  rm(srcdir); os.remove(outzip)
  results[#results+1] = 'test_cli_force_deflate_dirs: PASS'
end

-- Test 4: ziptool.zip_dir should produce the same central-directory as the CLI for the same directory
local function test_zip_dir_vs_cli()
  local base_dir = base .. '\\test_dir_compare'
  local out_cli = base .. '\\out_cli.zip'
  local out_lib = base .. '\\out_lib.zip'
  rm(base_dir); rm(out_cli); rm(out_lib)
  -- create a small tree
  if sep == '\\' then os.execute('cmd /c mkdir "' .. base_dir .. '" > nul 2>&1') else os.execute('mkdir -p "' .. base_dir .. '"') end
  local f1 = io.open(base_dir .. sep .. 'a.txt', 'wb'); f1:write('hello'); f1:close()
  local sub = base_dir .. sep .. 'sub'
  if sep == '\\' then os.execute('cmd /c mkdir "' .. sub .. '" > nul 2>&1') else os.execute('mkdir -p "' .. sub .. '"') end
  local f2 = io.open(sub .. sep .. 'b.txt', 'wb'); f2:write('world'); f2:close()

  -- create archive with CLI
  local cmd = 'lua "' .. cli_path .. '" "' .. out_cli .. '" "' .. base_dir .. '"'
  os.execute(cmd)

  -- create archive with library helper
  local res, err = ziptool.zip_dir(out_lib, base_dir, {compress = true, level = 6})
  ok(res, 'zip_dir failed: ' .. tostring(err))

  -- list both zips and compare names+methods
  local e_cli, err1 = ziptool.list_zip(out_cli)
  local e_lib, err2 = ziptool.list_zip(out_lib)
  ok(e_cli and e_lib, 'list_zip failed: ' .. tostring(err1 or err2))
  local map_cli = {}
  for _, e in ipairs(e_cli) do map_cli[e.name] = e.method end
  local map_lib = {}
  for _, e in ipairs(e_lib) do map_lib[e.name] = e.method end
  for name, m in pairs(map_cli) do
    ok(map_lib[name] ~= nil, 'entry missing in lib zip: ' .. tostring(name))
    ok(map_lib[name] == m, string.format('method mismatch for %s: cli=%d lib=%d', name, m, map_lib[name]))
  end

  -- cleanup
  rm(base_dir); os.remove(out_cli); os.remove(out_lib)
  results[#results+1] = 'test_zip_dir_vs_cli: PASS'
end

local function run()
  print('Running tests...')
  local s, e = pcall(test_basic)
  if not s then print('test_basic FAIL: ' .. tostring(e)); return end
  s, e = pcall(test_deflate)
  if not s then print('test_deflate FAIL: ' .. tostring(e)); return end
  s, e = pcall(test_cli_force_deflate_dirs)
  if not s then print('test_cli_force_deflate_dirs FAIL: ' .. tostring(e)); return end
  s, e = pcall(test_zip_dir_vs_cli)
  if not s then print('test_zip_dir_vs_cli FAIL: ' .. tostring(e)); return end
  print('Basic tests passed')
  print('All tests passed:')
  for _, r in ipairs(results) do print('  ' .. r) end
end

run()
