-- zip_cli.lua - thin, readable CLI wrapper for ziptool.lua

-- Try to load the library via require, then fallback to a local file.
local ziptool
do
	local ok, mod = pcall(require, 'ziptool')
	if ok and mod then ziptool = mod end
	if not ziptool then
		local src = debug.getinfo(1).source or ''
		local dir = src:match('@?(.*[\\/])') or './'
		local ok2, mod2 = pcall(dofile, dir .. 'ziptool.lua')
		if ok2 and mod2 then ziptool = mod2 end
	end
	if not ziptool then
		error('could not load ziptool module; ensure ziptool.lua is next to this script or available on package.path')
	end
end

-- Export a couple globals that some tests expect.
ZipWriter = ziptool.ZipWriter
unzip_file = ziptool.unzip_file

-- Small utility helpers --------------------------------------------------
local function usage()
	io.stderr:write('Usage:\n')
	io.stderr:write('  Create:  lua zip_cli.lua [-z|--deflate] [-l|--level N] out.zip in1 [in2 ...]\n')
	io.stderr:write('  Extract: lua zip_cli.lua -x|--extract archive.zip [out_dir]\n')
	io.stderr:write('  List:    lua zip_cli.lua -t|--list archive.zip\n')
end

local function file_exists(path)
	local f = io.open(path, 'rb')
	if f then f:close(); return true end
	return false
end

local function shell_quote(s)
	if not s then return '""' end
	return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

local function is_dir(path)
	local is_windows = package.config:sub(1,1) == '\\'
	if is_windows then
		local p = io.popen('cmd /c if exist ' .. shell_quote(path .. '\\*') .. ' (echo d)')
		if not p then return false end
		local line = p:read()
		p:close()
		return line == 'd'
	else
		local p = io.popen('test -d ' .. shell_quote(path) .. ' >/dev/null 2>&1; echo $?')
		if not p then return false end
		local out = p:read()
		p:close()
		return out == '0'
	end
end

-- Argument parsing ------------------------------------------------------
local function parse_args(args)
	local opts = {
		compress = false,
		level = 6,
		dir_like = false,
		force_flag = false,
		debug = false,
		extract = false,
		list_only = false,
	}
	local idx = 1
	while idx <= #args and args[idx]:sub(1,1) == '-' do
		local a = args[idx]
		if a == '-t' or a == '--list' then
			opts.list_only = true; idx = idx + 1
		elseif a == '-x' or a == '--extract' then
			opts.extract = true; idx = idx + 1
		elseif a == '-z' or a == '--deflate' then
			opts.compress = true; idx = idx + 1
		elseif a == '--force-compress' or a == '--force' then
			opts.force_flag = true; idx = idx + 1
		elseif a == '--debug' then
			opts.debug = true; idx = idx + 1
		elseif a == '-l' or a == '--level' then
			if args[idx+1] then opts.level = tonumber(args[idx+1]) or opts.level; idx = idx + 2 else return nil, 'missing level' end
		else
			return nil, 'unknown option: ' .. tostring(a)
		end
	end
	return opts, idx
end

-- Listing helpers -------------------------------------------------------
local method_name_map = { [0] = 'STORE', [8] = 'DEFLATE' }
local function method_name(m)
	return method_name_map[m] or ('M' .. tostring(m))
end

local function format_mtime(t)
	if not t then return '----' end
	return string.format('%04d-%02d-%02d %02d:%02d:%02d', t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function run_list(archive)
	local entries, err = ziptool.list_zip(archive)
	if not entries then io.stderr:write('List failed: ' .. tostring(err) .. '\n'); return end
	print(string.format('%-40s  %-8s  %10s  %10s  %s', 'Name', 'Method', 'Size', 'Compressed', 'MTime'))
	print(string.rep('-', 100))
	for _, e in ipairs(entries) do
		print(string.format('%-40s  %-8s  %10d  %10d  %s', e.name, method_name(e.method or 0), e.size or 0, e.comp or 0, format_mtime(e.mtime)))
	end
end

-- Extract handler ------------------------------------------------------
local function run_extract(archive, outdir)
	local ok, err = unzip_file(archive, outdir)
	if not ok then io.stderr:write('Extract failed: ' .. tostring(err) .. '\n') else print('Extracted to', outdir) end
end

-- Create handler -------------------------------------------------------
local function run_create(out, paths, opts)
	if not opts.compress then
		for _, p in ipairs(paths) do
			if is_dir(p) then
				opts.compress = true
				opts.dir_like = true
				break
			end
		end
	end

	local force_deflate = false
	if opts.force_flag or opts.dir_like then
		force_deflate = true
	end

	if opts.debug then
		io.stderr:write(string.format('DEBUG: CLI compress=%s dir_like=%s force_flag=%s force_deflate=%s\n', tostring(opts.compress), tostring(opts.dir_like), tostring(opts.force_flag), tostring(force_deflate)))
		ziptool.debug = true
	end

	local zw, err = ZipWriter.new(out, {compress = opts.compress, level = opts.level, force_deflate = force_deflate})
	if not zw then io.stderr:write('Error creating ' .. out .. ': ' .. tostring(err) .. '\n'); return end

	for _, p in ipairs(paths) do
		local ok, add_err
		if file_exists(p) then
			ok, add_err = zw:add_file(p, p:gsub('^.*[\\/]', ''))
		else
			ok, add_err = zw:add_tree(p, p:gsub('^.*[\\/]', ''))
		end
		if not ok then io.stderr:write('Error adding ' .. p .. ': ' .. tostring(add_err) .. '\n'); return end
	end

	local ok, close_err = zw:close()
	if not ok then io.stderr:write('Error finalizing ' .. out .. ': ' .. tostring(close_err) .. '\n'); return end
	print('Wrote', out)
end

-- Main CLI entry -------------------------------------------------------
local function run_cli(args)
	if #args < 1 then usage(); return end
	local opts, idx_or_err = parse_args(args)
	if not opts then io.stderr:write('Error: ' .. tostring(idx_or_err) .. '\n'); usage(); return end
	local idx = idx_or_err

	if opts.extract then
		local archive = args[idx]
		if not archive then usage(); return end
		return run_extract(archive, args[idx+1] or '.')
	end

	if opts.list_only then
		local archive = args[idx]
		if not archive then usage(); return end
		return run_list(archive)
	end

	local out = args[idx]
	if not out then usage(); return end
	local paths = {}
	for i = idx + 1, #args do paths[#paths+1] = args[i] end
	return run_create(out, paths, opts)
end

if type(arg) == 'table' and #arg > 0 then
	local argv = {}
	for i = 1, #arg do argv[i] = arg[i] end
	run_cli(argv)
end
