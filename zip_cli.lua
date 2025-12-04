-- zip_cli.lua - thin, readable CLI wrapper for ziptool.lua

-- Try to load the library via require, then fallback to a local file.
local ziptool
do
	local ok, mod = pcall(require, 'ziptool')
	if ok and mod then ziptool = mod end
	if not ziptool then
		local src = debug.getinfo(1).source or ''
		local dir = src:match('@?(.*[\\/])') or './'
		local impl = dir .. 'ziptool.lua'
		local ok2, mod2 = pcall(dofile, impl)
		if ok2 and mod2 then ziptool = mod2 end
	end
	if not ziptool then
		error("could not load ziptool module; ensure ziptool.lua is next to this script or available on package.path")
	end
end

-- Export a couple globals that some tests expect.
ZipWriter = ziptool.ZipWriter
unzip_file = ziptool.unzip_file

-- Small utility helpers --------------------------------------------------
local function usage()
	-- Print a concise usage summary to stderr. Kept intentionally short so
	-- the CLI can be used as a library (documented elsewhere) and tests can
	-- parse output easily.
	io.stderr:write("Usage:\n")
	io.stderr:write("  Create:  lua zip_cli.lua [-z|--deflate] [-l|--level N] out.zip in1 [in2 ...]\n")
	io.stderr:write("  Extract: lua zip_cli.lua -x|--extract archive.zip [out_dir]\n")
	io.stderr:write("  List:    lua zip_cli.lua -t|--list archive.zip\n")
end

local function file_exists(path)
	-- Return true if the given path is a readable file. We open in binary
	-- mode to avoid text-transform issues on some platforms. This intentionally
	-- does not attempt to check for directories (see `is_dir`).
	local f = io.open(path, 'rb')
	if f then f:close(); return true end
	return false
end

local function shell_quote(s)
	-- Minimal shell-quoting helper used when invoking small platform probes.
	-- We intentionally keep this tiny and conservative: it's not a robust
	-- cross-shell quoting library, but it handles typical file names used in
	-- tests (spaces and quotes). Used by `is_dir` below.
	if not s then return '""' end
	return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

local function is_dir(path)
	-- Cross-platform directory probe. Lua's standard library doesn't provide
	-- a single canonical is_dir function that works across versions/hosts,
	-- so we shell out to a tiny platform-specific probe.
	--
	-- On Windows we use `cmd /c if exist <path>\*` which returns true for
	-- directories. On Unix-like systems we call `test -d` and observe the
	-- exit code. This approach is simple and effective for our test-suite
	-- and CLI needs; it avoids adding external dependencies.
	local is_windows = package.config:sub(1,1) == '\\'
	if is_windows then
		local testpath = path .. '\\*'
		local p = io.popen('cmd /c if exist ' .. shell_quote(testpath) .. ' (echo d)')
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
	-- Simple, linear option parser. We intentionally don't attempt to be a
	-- feature-complete getopt replacement; this keeps the code short and
	-- makes the mapping from flags to `opts` explicit and easy to read.
	while idx <= #args and args[idx]:sub(1,1) == '-' do
		local a = args[idx]
		if a == '-t' or a == '--list' then
			-- List archive contents and exit
			opts.list_only = true; idx = idx + 1
		elseif a == '-x' or a == '--extract' then
			-- Extract archive contents
			opts.extract = true; idx = idx + 1
		elseif a == '-z' or a == '--deflate' then
			-- Explicitly request DEFLATE compression for created entries
			opts.compress = true; idx = idx + 1
		elseif a == '--force-compress' or a == '--force' then
			-- Force DEFLATE even when compressed bytes would not be smaller
			opts.force_flag = true; idx = idx + 1
		elseif a == '--debug' then
			-- Enable verbose debug logging (also sets library debug flag)
			opts.debug = true; idx = idx + 1
		elseif a == '-l' or a == '--level' then
			-- Compression level argument expects a numeric parameter
			if args[idx+1] then opts.level = tonumber(args[idx+1]) or opts.level; idx = idx + 2 else return nil, 'missing level' end
		else
			-- Unknown option: bail with an error so callers/tests can detect misuse
			return nil, 'unknown option: ' .. tostring(a)
		end
	end
	return opts, idx
end

-- Listing helpers -------------------------------------------------------
local localize_method = {
	[0] = 'STORE',
	[8] = 'DEFLATE',
}
local function method_name(m)
	return localize_method[m] or ('M' .. tostring(m))
end
local function format_mtime(t)
	if not t then return '----' end
	return string.format('%04d-%02d-%02d %02d:%02d:%02d', t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function run_list(archive)
	-- Query the library for a list of central-directory entries. The library
	-- returns a table of entry tables with fields such as `name`, `method`,
	-- `size`, `comp` (compressed size) and `mtime` (DOS/time table). We keep
	-- the formatting human readable but stable so tests can parse it when
	-- needed.
	local entries, err = ziptool.list_zip(archive)
	if not entries then io.stderr:write('List failed: ' .. tostring(err) .. '\n'); return end
	-- Header row for columns: name, method, uncompressed size, compressed size, timestamp
	print(string.format('%-40s  %-8s  %10s  %10s  %s', 'Name', 'Method', 'Size', 'Compressed', 'MTime'))
	print(string.rep('-', 100))
	for _, e in ipairs(entries) do
		local mname = method_name(e.method or 0)
		local mtime = format_mtime(e.mtime)
		-- Use fixed-width columns for readability. We coerce nil sizes to 0
		-- which matches how the library reports missing numeric fields.
		print(string.format('%-40s  %-8s  %10d  %10d  %s', e.name, mname, e.size or 0, e.comp or 0, mtime))
	end
end

-- Extract handler ------------------------------------------------------
local function run_extract(archive, outdir)
	-- Call into the library's `unzip_file` which performs extraction and
	-- basic safety checks (zip-slip protection, CRC verification). We simply
	-- forward errors to stderr and print a success message on completion.
	local ok, err = unzip_file(archive, outdir)
	if not ok then io.stderr:write('Extract failed: ' .. tostring(err) .. '\n') else print('Extracted to', outdir) end
end

-- Create handler -------------------------------------------------------
local function run_create(out, paths, opts)
	-- If the user didn't explicitly request deflate (-z) we still enable
	-- compression for directory-like inputs. This is a convenience so that
	-- creating an archive of a folder will compress its files by default.
	if not opts.compress then
		for _, p in ipairs(paths) do
			if is_dir(p) then
				-- Mark that we saw a directory-like input so downstream
				-- logic can decide whether to force DEFLATE for tiny files.
				opts.compress = true
				opts.dir_like = true
				break
			end
		end
	end

	-- Compute `force_deflate` which controls whether we will write DEFLATE
	-- method entries even when the compressed output isn't smaller. Priority
	-- is: explicit --force flag > auto-detected directory input > default
	-- compression behavior.
	local force_deflate = false
	if opts.force_flag then
		force_deflate = true
	elseif opts.dir_like then
		force_deflate = true
	elseif opts.compress then
		force_deflate = false
	end

	-- If the user requested debug output, enable the library's debug gate as
	-- well. The debug output is intentionally verbose and intended for
	-- developers, not end users.
	if opts.debug then
		io.stderr:write(string.format('DEBUG: CLI compress=%s dir_like=%s force_flag=%s force_deflate=%s\n', tostring(opts.compress), tostring(opts.dir_like), tostring(opts.force_flag), tostring(force_deflate)))
		ziptool.debug = true
	end

	-- Create a new ZipWriter with the computed options. The ZipWriter will
	-- handle per-file compression decisions (including forced DEFLATE when
	-- requested).
	local zw, err = ZipWriter.new(out, {compress = opts.compress, level = opts.level, force_deflate = force_deflate})
	if not zw then io.stderr:write('Error creating ' .. out .. ': ' .. tostring(err) .. '\n'); return end

	-- Add each path. If the path is a file we add it directly with a base
	-- name; otherwise we treat it as a tree and let the writer recurse.
	for _, p in ipairs(paths) do
		if file_exists(p) then
			-- Use only the final path component as the stored name in the zip
			local name = p:gsub('^.*[\\/]', '')
			zw:add_file(p, name)
		else
			-- For directories or non-regular paths, use the same base name as
			-- the top-level entry inside the zip and recurse into the tree.
			local base = p:gsub('^.*[\\/]', '')
			zw:add_tree(p, base)
		end
	end

	-- Finalize and close the archive then print a concise success message.
	zw:close()
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
		local outdir = args[idx+1] or '.'
		return run_extract(archive, outdir)
	end

	if opts.list_only then
		local archive = args[idx]
		if not archive then usage(); return end
		return run_list(archive)
	end

	-- Create
	local out = args[idx]
	if not out then usage(); return end
	local paths = {}
	for i = idx + 1, #args do table.insert(paths, args[i]) end
	return run_create(out, paths, opts)
end

-- When executed as a script, build args from `arg` and run the CLI.
if type(arg) == 'table' and #arg > 0 then
	local argv = {}
	for i = 1, #arg do argv[i] = arg[i] end
	run_cli(argv)
end
-- If the separate module `ziptool.lua` wasn't available above we'd embed
-- a single-file implementation. If we successfully loaded `ziptool` then
-- skip the embedded copy to avoid duplicate definitions.
if not ziptool then
-- Pure-Lua ZIP tool (single file)
--
-- Capabilities:
--  - Create ZIP archives (stored or DEFLATE) and extract them.
--  - Pure Lua implementation (no external C libraries). Works cross-platform.
--  - DEFLATE: simple pure-Lua LZ77 + fixed-Huffman encoder (compression levels 0-9).
--    Note: streaming compression API buffers per-file and compresses on finish
--    (there is not a fully online/stateful deflater that emits compressed
--    bytes as chunks arrive).
--  - Unzip supports reading classic ZIP and ZIP64 (reads ZIP64 EOCD locator
--    and ZIP64 EOCD to obtain 64-bit counts/offsets). Central-directory
--    per-entry ZIP64 extra fields are parsed when present.
--  - Integrity: CRC32 is calculated and verified on extraction.
--  - Safety: extraction sanitizes entry names to avoid zip-slip (removes
--    absolute paths and '..' segments).
--
-- Usage: lua test.lua [-z|--deflate] [-l|--level N] out.zip in1 [in2 ...]
-- Extract: lua test.lua -x|--extract archive.zip [out_dir]

local io_open = io.open
local os_time = os.time
local os_date = os.date
local tostring = tostring
local type = type

-- Little-endian pack helpers
local function u16(n)
	n = n % 65536
	return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
	n = n % 4294967296
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function u64(n)
	-- pack 64-bit little-endian (n may be larger than 32-bit)
	n = n % 18446744073709551616
	local lo = n % 4294967296
	local hi = math.floor(n / 4294967296) % 4294967296
	return u32(lo) .. u32(hi)
end

local function le64(s, i)
	i = i or 1
	local a = s:byte(i) or 0
	local b = s:byte(i+1) or 0
	local c = s:byte(i+2) or 0
	local d = s:byte(i+3) or 0
	local e = s:byte(i+4) or 0
	local f = s:byte(i+5) or 0
	local g = s:byte(i+6) or 0
	local h = s:byte(i+7) or 0
	-- combine little-endian bytes into a (Lua number, may lose precision >2^53)
	return a + b * 256 + c * 65536 + d * 16777216 + e * 4294967296 + f * 1099511627776 + g * 281474976710656 + h * 72057594037927936
end

local MAX32 = 0xFFFFFFFF
local MAX16 = 0xFFFF

-- Basic utility functions used by the writer/CLI
ZipWriter = {}
ZipWriter.__index = ZipWriter

local function shell_quote(s)
	if not s then return '""' end
	-- simple quoting for shells (works reasonably on Windows/Unix)
	return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

local function zip_path(name)
	-- normalize to forward slashes and remove leading drive letters
	name = tostring(name or '')
	name = name:gsub('\\', '/')
	name = name:gsub('^%a:%/*', '')
	name = name:gsub('^/*', '')
	return name
end

local function dos_datetime(t)
	-- t is a table from os.date('*t')
	local year = t.year or 1980
	if year < 1980 then year = 1980 end
	local month = t.month or 1
	local day = t.day or 1
	local hour = t.hour or 0
	local min = t.min or 0
	local sec = math.floor((t.sec or 0) / 2) -- DOS stores seconds/2
	-- compute without bitwise operators: pack into 16-bit words
	local dos_time = hour * 2^11 + min * 2^5 + sec
	local dos_date = (year - 1980) * 2^9 + month * 2^5 + day
	return u16(dos_time), u16(dos_date)
end

-- CRC32 implementation
-- Bitwise helpers for Lua 5.1 compatibility
-- Build CRC table once and provide crc32 and incremental crc_update
local function build_crc_table()
	local poly = 0xEDB88320
	local tbl = {}
	for i = 0, 255 do
		local c = i
		for j = 1, 8 do
			if (c & 1) ~= 0 then
				c = poly ~ (c >> 1)
			else
				c = c >> 1
			end
		end
		tbl[i] = c
	end
	return tbl
end

local __crc_table = build_crc_table()
local function crc32(data)
	local crc = 0xFFFFFFFF
	for i = 1, #data do
		local b = data:byte(i)
		crc = (__crc_table[(crc ~ b) & 0xFF] ~ (crc >> 8)) & 0xFFFFFFFF
	end
	return (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
end
local function crc_update(crc, data)
	crc = crc or 0xFFFFFFFF
	for i = 1, #data do
		local b = data:byte(i)
		crc = (__crc_table[(crc ~ b) & 0xFF] ~ (crc >> 8)) & 0xFFFFFFFF
	end
	return crc
end

-- Bitwise helpers for Lua 5.1 compatibility
local has_bit = (bit32 ~= nil) or (jit and jit.bit) or false
local function bor(a,b) return (a|b) end
local function band(a,b) return (a&b) end
local function bxor(a,b) return (a~b) end
local function rshift(a,b) return (a>>b) end
local function lshift(a,b) return (a<<b) end
-- Try to use native operators; if they error, fallback to bit32 if present

-- Fallbacks for bit ops when native bitwise operators are not available.
-- Prefer native operators, then bit32; if neither is available provide
-- simple arithmetic-based fallbacks (limited but sufficient for this code).
do
	local ok = pcall(function() local _ = 1 & 1 end)
	if not ok then
		if bit32 then
			bor = bit32.bor; band = bit32.band; bxor = bit32.bxor; rshift = bit32.rshift; lshift = bit32.lshift
		else
			bor = function(a,b) return a + b end
			band = function(a,b) return a % 256 end
			bxor = function(a,b) return a + b end
			rshift = function(a,b) return math.floor(a / 2^b) end
			lshift = function(a,b) return a * 2^b end
		end
	end
end

-- Emit a DEFLATE block using fixed Huffman codes that simply writes literal
-- bytes (no LZ77 matches). Used as a fallback for empty input or simple
-- blocks. This keeps compatibility with DEFLATE readers without requiring
-- external zlib libraries.
local function deflate_fixed_literals(data)
	local out = {}
	local bitbuf = 0
	local bitlen = 0
	local function emit_bit(b)
		bitbuf = bitbuf + (b * (2 ^ bitlen))
		bitlen = bitlen + 1
		if bitlen == 8 then table.insert(out, string.char(bitbuf)); bitbuf = 0; bitlen = 0 end
	end
	local function emit_bits(val, n)
		for i = 0, n-1 do
			local bit = math.floor(val / (2 ^ i)) % 2
			emit_bit(bit)
		end
	end
	local function fixed_code(sym)
		if sym >= 0 and sym <= 143 then
			return sym + 48, 8
		elseif sym >= 144 and sym <= 255 then
			return sym + 256, 9
		elseif sym >= 256 and sym <= 279 then
			return sym - 256, 7
		elseif sym >= 280 and sym <= 287 then
			return sym - 88, 8
		end
		return nil
	end
	-- header: BFINAL=1, BTYPE=01 (fixed Huffman)
	emit_bits(1, 1)
	emit_bits(1, 2)
	for i = 1, #data do
		local sym = data:byte(i)
		local code, l = fixed_code(sym)
		emit_bits(code, l)
	end
	local code, l = fixed_code(256)
	emit_bits(code, l)
	if bitlen > 0 then table.insert(out, string.char(bitbuf)) end
	return table.concat(out)
end

-- Simple LZ77 + DEFLATE fixed Huffman encoder (pure Lua)
local function deflate_lz77(data, level)
	level = tonumber(level) or 6
	local n = #data
	if n == 0 then
		-- empty deflate block: BFINAL=1,BTYPE=01 then end code
		return deflate_fixed_literals("")
	end
	local window_sizes = {256,512,1024,2048,4096,8192,16384,32768,32768}
	local chain_limits = {4,8,16,32,64,128,256,512,1024}
	local max_window = window_sizes[math.min(math.max(level,1),9)]
	local max_chain = chain_limits[math.min(math.max(level,1),9)]

	-- helper to emit bits LSB-first
	local out = {}
	local bitbuf = 0
	local bitlen = 0
	local function emit_bit(b)
		bitbuf = bitbuf + (b * (2 ^ bitlen))
		bitlen = bitlen + 1
		if bitlen == 8 then table.insert(out, string.char(bitbuf)); bitbuf = 0; bitlen = 0 end
	end
	local function emit_bits(val, n)
		for i = 0, n-1 do
			local bit = math.floor(val / (2 ^ i)) % 2
			emit_bit(bit)
		end
	end

	-- length and distance base tables (RFC 1951)
	local length_base = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
	local length_extra = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
	local dist_base = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
	local dist_extra = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}

	-- fixed huffman code helper (reuse earlier logic)
	local function fixed_code(sym)
		if sym >= 0 and sym <= 143 then
			return sym + 48, 8
		elseif sym >= 144 and sym <= 255 then
			return sym + 256, 9
		elseif sym >= 256 and sym <= 279 then
			return sym - 256, 7
		elseif sym >= 280 and sym <= 287 then
			return sym - 88, 8
		end
		return nil
	end

	-- Build a simple index of previous positions for two-byte prefixes to limit search
	local heads = {}
	local function add_head(pos)
		if pos >= n then return end
		local b1 = data:byte(pos)
		local b2 = data:byte(pos+1) or 0
		local key = b1 * 256 + b2
		local list = heads[key] or {}
		table.insert(list, pos)
		heads[key] = list
	end

	local i = 1
	-- write header: BFINAL=1, BTYPE=01
	emit_bits(1,1); emit_bits(1,2)
	while i <= n do
		local best_len = 0
		local best_dist = 0
		if i < n then
			local b1 = data:byte(i)
			local b2 = data:byte(i+1) or 0
			local key = b1 * 256 + b2
			local list = heads[key]
			if list then
				-- search from end (most recent)
				local checked = 0
				for li = #list, 1, -1 do
					local pos = list[li]
					local dist = i - pos
					if dist > max_window then break end
					checked = checked + 1
					if checked > max_chain then break end
					-- match forward
					local max_len = math.min(258, n - i + 1)
					local len = 0
					while len < max_len and data:byte(pos + len) == data:byte(i + len) do len = len + 1 end
					if len > best_len and len >= 3 then best_len = len; best_dist = dist end
					if best_len >= 258 then break end
				end
			end
		end
		if best_len >= 3 then
			-- emit length code (257..285)
			local len = best_len
			local li = 1
			while li <= #length_base and not (len >= length_base[li] and (li == #length_base or len < length_base[li+1])) do li = li + 1 end
			local code = 256 + li
			local codeval, codelen = fixed_code(code)
			emit_bits(codeval, codelen)
			local extra = len - length_base[li]
			if length_extra[li] and length_extra[li] > 0 then emit_bits(extra, length_extra[li]) end
			-- distance
			local dist = best_dist
			local di = 1
			while di <= #dist_base and not (dist >= dist_base[di] and (di == #dist_base or dist < dist_base[di+1])) do di = di + 1 end
			emit_bits(di-1, 5) -- distance code (5 bits)
			local dext = dist - dist_base[di]
			if dist_extra[di] and dist_extra[di] > 0 then emit_bits(dext, dist_extra[di]) end
			-- add heads for the matched bytes
			for k = 0, best_len-1 do add_head(i + k) end
			i = i + best_len
		else
			-- emit literal
			local sym = data:byte(i)
			local codeval, codelen = fixed_code(sym)
			emit_bits(codeval, codelen)
			add_head(i)
			i = i + 1
		end
	end
	-- end of block
	local codeval, codelen = fixed_code(256)
	emit_bits(codeval, codelen)
	if bitlen > 0 then table.insert(out, string.char(bitbuf)) end
	return table.concat(out)
end

function ZipWriter.new(outpath, opts)
	local f, err = io_open(outpath, 'wb')
	if not f then return nil, err end
	opts = opts or {}
	local self = setmetatable({f = f, entries = {}, offset = 0, compress = not not opts.compress, level = tonumber(opts.level) or 6}, ZipWriter)
	return self
end

function ZipWriter:_write(s)
	self.f:write(s)
	self.offset = self.offset + #s
end

-- Add a file from disk; arcname is optional
function ZipWriter:add_file(path, arcname)
	arcname = arcname or path
	arcname = zip_path(arcname)
	local f, err = io_open(path, 'rb')
	if not f then return nil, err end
	local sz = f:seek('end')
	f:seek('set', 0)
	-- stream if > 1MB
	if sz > 1024*1024 then
		self:start_file_stream(arcname)
		while true do
			local chunk = f:read(65536)
			if not chunk then break end
			self:write_chunk(chunk)
		end
		f:close()
		return self:finish_file_stream()
	else
		local data = f:read('*a')
		f:close()
		return self:add_data(arcname, data)
	end
end

-- Add raw data as a file entry (stored/no compression)
function ZipWriter:add_data(name, data, modtime)
	if type(name) ~= 'string' then return nil, 'name must be string' end
	name = zip_path(name)
	local crc = crc32(data)
	local size = #data
	local method = 0 -- 0=stored, 8=deflate
	local outdata = data
	local comp_size = size
	if self.compress then
		local comp = deflate_lz77(data, self.level)
		if comp and #comp > 0 then
			outdata = comp
			comp_size = #outdata
			method = 8
		end
	end
	local dos_time, dos_date = dos_datetime(os_date('*t'))

	-- local file header
	local local_header = table.concat{
		string.char(0x50,0x4b,0x03,0x04), -- signature
		u16(20), -- version needed
		u16(0), -- flags
		u16(method), -- method: store or deflate
		dos_time,
		dos_date,
		u32(crc),
		u32(comp_size),
		u32(size),
		u16(#name),
		u16(0), -- extra len
		name
	}
		local header_offset = self.offset
			self:_write(local_header)
		if comp_size > 0 then self:_write(outdata) end

	-- central directory record info
	-- central directory extra for ZIP64 if necessary
	local extra = ''
	local cd_comp_size = comp_size
	local cd_size = size
	local cd_offset = header_offset
	if comp_size > MAX32 or size > MAX32 or header_offset > MAX32 then
		-- ZIP64 extra: tag 0x0001, size 16 or 24 depending
		local zbuf = {}
		if size > MAX32 then table.insert(zbuf, u64(size)) else table.insert(zbuf, u64(0)) end
		if comp_size > MAX32 then table.insert(zbuf, u64(comp_size)) else table.insert(zbuf, u64(0)) end
		if header_offset > MAX32 then table.insert(zbuf, u64(header_offset)) else table.insert(zbuf, u64(0)) end
		extra = string.char(0x01,0x00) .. u16(#table.concat(zbuf)) .. table.concat(zbuf)
		cd_comp_size = math.min(comp_size, MAX32)
		cd_size = math.min(size, MAX32)
		cd_offset = math.min(header_offset, MAX32)
	end
	local central = table.concat{
		string.char(0x50,0x4b,0x01,0x02), -- signature
		u16(45), -- version made by (45 for ZIP64)
		u16(45), -- version needed (45 for ZIP64)
		u16(0), -- flags
		u16(method), -- method
		dos_time,
		dos_date,
		u32(crc),
		u32(cd_comp_size),
		u32(cd_size),
		u16(#name),
		u16(#extra), -- extra len
		u16(0), -- comment
		u16(0), -- disk
		u16(0), -- int attr
		u32(0), -- ext attr
		u32(cd_offset),
		name,
		extra
	}
	table.insert(self.entries, central)
	return true
end

function ZipWriter:add_directory(name)
	name = zip_path(name)
	if not name:match('/$') then name = name .. '/' end
	-- directories have zero data but must have directory attribute set in central dir
	local dos_time, dos_date = dos_datetime(os_date('*t'))
	local header_offset = self.offset
	local local_header = table.concat{
		string.char(0x50,0x4b,0x03,0x04),
		u16(20), u16(0), u16(0), dos_time, dos_date, u32(0), u32(0), u32(0), u16(#name), u16(0), name
	}
	self:_write(local_header)
	local central = table.concat{
		string.char(0x50,0x4b,0x01,0x02), u16(20), u16(20), u16(0), u16(0), dos_time, dos_date, u32(0), u32(0), u32(0), u16(#name), u16(0), u16(0), u16(0), u16(0), u32(16), u32(header_offset), name
	}
	table.insert(self.entries, central)
	return true
end

-- ZipWriter:close()
--
-- Finalize the archive: write the collected central-directory entries, then
-- write the proper EOCD record(s). When the archive or per-entry values
-- exceed 32-bit limits, this writes a ZIP64 End Of Central Directory Record
-- followed by the ZIP64 EOCD Locator before the classic EOCD. The classic
-- EOCD will contain 0xFFFF/0xFFFFFFFF sentinels in that case so readers know
-- to consult the ZIP64 structures.
--
-- This function does not alter the previously written local headers; it only
-- appends the central directory and the EOCD structures and closes the file.
function ZipWriter:close()
	local central_offset = self.offset
	local cd = table.concat(self.entries)
	self:_write(cd)
	local central_size = self.offset - central_offset
	-- If ZIP64 is needed for central directory counts/sizes/offsets, write ZIP64 EOCD and locator
	local need_zip64 = false
	if #self.entries > MAX16 or central_size > MAX32 or central_offset > MAX32 then need_zip64 = true end
	if need_zip64 then
		-- ZIP64 End of Central Directory Record
		local zip64_eocd = table.concat{
			string.char(0x50,0x4b,0x06,0x06), -- signature
			u64(44), -- size of zip64 eocd record (size of remaining fields)
			u16(45), u16(45), -- version made by, version needed
			u32(0), u32(0), -- disk numbers
			u64(#self.entries), u64(#self.entries), -- total entries on this disk, total entries
			u64(central_size), u64(central_offset)
		}
		self:_write(zip64_eocd)
		-- ZIP64 EOCD Locator
		local zip64_locator = table.concat{
			string.char(0x50,0x4b,0x06,0x07), -- signature
			u32(0), -- number of the disk with the start of the zip64 eocd
			u64(self.offset - #zip64_eocd), -- relative offset of the zip64 eocd
			u32(1) -- total number of disks
		}
		self:_write(zip64_locator)
	end
	-- end of central dir (classic EOCD)
	local eocd = table.concat{
		string.char(0x50,0x4b,0x05,0x06),
		u16(0), u16(0),
		u16(need_zip64 and 0xFFFF or #self.entries), u16(need_zip64 and 0xFFFF or #self.entries),
		u32(need_zip64 and 0xFFFFFFFF or central_size), u32(need_zip64 and 0xFFFFFFFF or central_offset),
		u16(0) -- comment len
	}
	self:_write(eocd)
	self.f:close()
	self.f = nil
	return true
end

-- Recursive add using shell commands (fallback when lfs is not available)
local function is_windows()
	return package.config:sub(1,1) == '\\'
end

local function file_exists(path)
	local f = io_open(path, 'rb')
	if f then f:close(); return true end
	return false
end

-- Helpers to create directories
local function make_dir(path)
	if path == '' then return true end
	if is_windows() then
		return os.execute('mkdir ' .. shell_quote(path) .. ' > nul 2>&1')
	else
		return os.execute('mkdir -p ' .. shell_quote(path))
	end
end

-- Read little-endian ints from a binary string
local function le16(s, i)
	i = i or 1
	local a = s:byte(i) or 0
	local b = s:byte(i+1) or 0
	return a + b * 256
end
local function le32(s, i)
	i = i or 1
	local a = s:byte(i) or 0
	local b = s:byte(i+1) or 0
	local c = s:byte(i+2) or 0
	local d = s:byte(i+3) or 0
	return a + b * 256 + c * 65536 + d * 16777216
end
-- expose for debug scripts
-- (le16/le32 kept local for internal use)

-- Find EOCD record by scanning the last 66k bytes
local function find_eocd(f)
	local size = f:seek('end')
	local scan = math.min(65536 + 22, size)
	f:seek('end', -scan)
	local tail = f:read(scan)
	local sig = string.char(0x50,0x4b,0x05,0x06)
	local pos = tail:match('.*()' .. sig)
	if not pos then return nil, 'EOCD not found' end
	local off = size - scan + pos
	f:seek('set', off)
	local e = f:read(22)
	local total_entries = le16(e, 11)
	local cd_size = le32(e, 13)
	local cd_offset = le32(e, 17)
	return {entries = total_entries, cd_size = cd_size, cd_offset = cd_offset}
end

-- find_eocd_and_zip64(f)
--
-- Scans the end of the ZIP file for the End Of Central Directory (EOCD) record.
-- If the classic EOCD contains 0xFFFF/0xFFFFFFFF sentinel values, this function
-- will locate and read the ZIP64 EOCD Locator and the ZIP64 EOCD Record and
-- return 64-bit values for: total entries, central-directory size and
-- central-directory offset. Returns a table {entries, cd_size, cd_offset} or
-- (nil, err) on failure.
function find_eocd_and_zip64(f)
	local size = f:seek('end')
	local scan = math.min(65536 + 22, size)
	f:seek('end', -scan)
	local tail = f:read(scan)
	local sig = string.char(0x50,0x4b,0x05,0x06)
	local pos = tail:find(sig, 1, true)
	if not pos then return nil, 'EOCD not found' end
	-- extract EOCD record from the tail slice to avoid file seek rounding
	local e = tail:sub(pos, pos + 22 - 1)
	local total_entries = le16(e, 11)
	local cd_size = le32(e, 13)
	local cd_offset = le32(e, 17)

	-- if any sentinel values appear, locate ZIP64 structures
	if total_entries == 0xFFFF or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF then
		-- find ZIP64 EOCD locator signature (0x504b0607) in the tail
		local loc_sig = string.char(0x50,0x4b,0x06,0x07)
		local loc_pos = tail:find(loc_sig, 1, true)
		if not loc_pos then return nil, 'ZIP64 locator not found' end
		local locator = tail:sub(loc_pos, loc_pos + 20 - 1)
		if not locator or #locator < 20 then return nil, 'ZIP64 locator truncated' end
		-- parse locator: signature(4), number of disk(4), offset(8), total disks(4)
		local zip64_eocd_off = le64(locator, 9)
		-- read ZIP64 EOCD record
		if zip64_eocd_off < 0 or zip64_eocd_off > size then return nil, 'ZIP64 EOCD offset invalid' end
		f:seek('set', zip64_eocd_off)
		local sig4 = f:read(4)
		if sig4 ~= string.char(0x50,0x4b,0x06,0x06) then return nil, 'ZIP64 EOCD signature not found' end
		local size_bytes = f:read(8)
		local eocd_size = le64(size_bytes,1)
		local eocd_rest = f:read(eocd_size)
		if not eocd_rest or #eocd_rest < 40 then return nil, 'ZIP64 EOCD truncated' end
		-- offsets within eocd_rest (1-based): version(1-2), version_needed(3-4), disk(5-8), disk_start(9-12), total_entries(13-20), total_entries_all(21-28), cd_size(29-36), cd_offset(37-44)
		local total_entries64 = le64(eocd_rest, 13)
		local cd_size64 = le64(eocd_rest, 29)
		local cd_offset64 = le64(eocd_rest, 37)
		return {entries = total_entries64, cd_size = cd_size64, cd_offset = cd_offset64}
	end

	return {entries = total_entries, cd_size = cd_size, cd_offset = cd_offset}
end

-- Build fixed-huffman decode tables
local function build_fixed_decode()
	local table_by_len = {}
	for sym = 0, 287 do
		local code, len
		if sym >= 0 and sym <= 143 then code = sym + 48; len = 8
		elseif sym >= 144 and sym <= 255 then code = sym + 256; len = 9
		elseif sym >= 256 and sym <= 279 then code = sym - 256; len = 7
		elseif sym >= 280 and sym <= 287 then code = sym - 88; len = 8
		end
		if code and len then
			table_by_len[len] = table_by_len[len] or {}
			table_by_len[len][code] = sym
		end
	end
	return table_by_len
end

local fixed_table = build_fixed_decode()

-- Bit reader for LSB-first streams
local function BitReader(data)
	local o = {data = data, pos = 1, bitbuf = 0, bitlen = 0}
	local function fill(self)
		if self.pos <= #self.data then
			self.bitbuf = self.bitbuf + ((self.data:byte(self.pos) or 0) * (2 ^ self.bitlen))
			self.bitlen = self.bitlen + 8
			self.pos = self.pos + 1
		end
	end
	function o:read_bits(n)
		while self.bitlen < n do fill(self) end
		local val = 0
		for i = 0, n-1 do
			val = val + (((self.bitbuf // (2 ^ i)) % 2) * (2 ^ i))
		end
		-- remove bits
		self.bitbuf = math.floor(self.bitbuf / (2 ^ n))
		self.bitlen = self.bitlen - n
		return val
	end
	function o:read_bit()
		return self:read_bits(1)
	end
	return o
end

-- Decode a Huffman symbol from fixed_table
local function decode_fixed_symbol(br)
	-- read up to 9 bits and check matches
	local val = 0
	local acc = 0
	for l = 1, 9 do
		local b = br:read_bit()
		acc = acc + (b * (2 ^ (l-1)))
		local t = fixed_table[l]
		if t and t[acc] then return t[acc] end
	end
	return nil, 'invalid symbol'
end

-- Inflate deflate data with fixed Huffman blocks and LZ77 backrefs
-- reverse lower 'bits' bits of value
local function bit_reverse(val, bits)
	local out = 0
	for i = 1, bits do
		out = out * 2 + (val & 1)
		val = math.floor(val / 2)
	end
	return out
end

local function build_decode_table(lengths)
	-- lengths: array indexed 0..N-1 (but implemented as 1..N) giving bit lengths
	local n = #lengths
	local maxbits = 0
	for i = 1, n do if lengths[i] and lengths[i] > maxbits then maxbits = lengths[i] end end
	local count = {}
	for i = 1, maxbits do count[i] = 0 end
	for i = 1, n do local l = lengths[i] or 0; if l > 0 then count[l] = count[l] + 1 end end
	local next_code = {}
	local code = 0
	for bits = 1, maxbits do
		code = (code + (count[bits-1] or 0)) * 2
		next_code[bits] = code
	end
	local table_by_len = {}
	for i = 1, n do
		local l = lengths[i] or 0
		if l > 0 then
			local c = next_code[l]
			next_code[l] = next_code[l] + 1
			local rev = bit_reverse(c, l)
			table_by_len[l] = table_by_len[l] or {}
			table_by_len[l][rev] = i-1 -- store symbol (0-based)
		end
	end
	return table_by_len
end

local function decode_symbol(br, table_by_len)
	local acc = 0
	for l = 1, 32 do
		local b = br:read_bit()
		acc = acc + (b * (2 ^ (l-1)))
		local t = table_by_len[l]
		if t and t[acc] ~= nil then return t[acc] end
	end
	return nil, 'invalid symbol'
end

-- Simple inflater: supports stored blocks (BTYPE=0) and fixed-Huffman (BTYPE=1)
local function inflate_deflate(data)
	local br = BitReader(data)
	local out = {}
	local length_base = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
	local length_extra = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
	local dist_base = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
	local dist_extra = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}

	while true do
		local bfinal = br:read_bit()
		local btype = br:read_bits(2)
		if btype == 0 then
			-- stored (byte aligned)
			while br.bitlen % 8 ~= 0 do br:read_bit() end
			local lo = br:read_bits(8); local hi = br:read_bits(8)
			local len = lo + hi * 256
			local nlo = br:read_bits(8); local nhi = br:read_bits(8)
			local nlen = nlo + nhi * 256
			if (len ~ nlen) ~= 0xFFFF then return nil, 'stored len mismatch' end
			for i = 1, len do table.insert(out, string.char(br:read_bits(8))) end

		elseif btype == 1 then
			-- fixed Huffman
			while true do
				local sym = decode_fixed_symbol(br)
				if not sym then return nil, 'decode error' end
				if sym < 256 then
					table.insert(out, string.char(sym))
				elseif sym == 256 then
					break
				else
					local lenidx = sym - 256
					local lb = length_base[lenidx]
					local le = length_extra[lenidx]
					local extra = 0
					if le and le > 0 then extra = br:read_bits(le) end
					local length = lb + extra
					local distbits = br:read_bits(5)
					local dist = dist_base[distbits+1]
					local de = dist_extra[distbits+1]
					local dext = 0
					if de and de > 0 then dext = br:read_bits(de) end
					dist = dist + dext
					local outlen = #out
					for k = 1, length do
						local pos = outlen - dist + k
						if pos < 1 then return nil, 'dist out of range' end
						table.insert(out, out[pos])
					end
				end
			end

		else
			return nil, 'unsupported BTYPE'
		end

		if bfinal == 1 then break end
	end

	return table.concat(out)
end

function unzip_file(zip_path, out_dir)
	out_dir = out_dir or '.'
	local f, err = io_open(zip_path, 'rb')
	if not f then return nil, err end
	local eocd, eerr = find_eocd_and_zip64(f)
	if not eocd then f:close(); return nil, eerr end

	-- read central directory into memory then parse entries
	f:seek('set', eocd.cd_offset)
	local cd = f:read(eocd.cd_size)
	if not cd or #cd < 46 then f:close(); return nil, 'central directory truncated' end
	local i = 1
	local entries = {}
	while i <= #cd do
		local sig = cd:sub(i, i+3)
		if sig ~= string.char(0x50,0x4b,0x01,0x02) then break end
		local ver_made = le16(cd, i+4)
		local ver_needed = le16(cd, i+6)
		local flags = le16(cd, i+8)
		local method = le16(cd, i+10)
		local dos_time = le16(cd, i+12)
		local dos_date = le16(cd, i+14)
		local crc = le32(cd, i+16)
		local comp_size = le32(cd, i+20)
		local size = le32(cd, i+24)
		local name_len = le16(cd, i+28)
		local extra_len = le16(cd, i+30)
		local comment_len = le16(cd, i+32)
		local header_offset = le32(cd, i+42)
		local name = cd:sub(i+46, i+45+name_len)
		local extra = cd:sub(i+46+name_len, i+45+name_len+extra_len)
		-- If sentinel values present, parse ZIP64 extra in central dir to get 64-bit sizes/offsets
		if (comp_size == 0xFFFFFFFF or size == 0xFFFFFFFF or header_offset == 0xFFFFFFFF) and #extra > 0 then
			local j = 1
			while j <= #extra do
				local eid = le16(extra, j)
				local elen = le16(extra, j+2)
				if eid == 0x0001 then
					local payload = extra:sub(j+4, j+3+elen)
					local pidx = 1
					if size == 0xFFFFFFFF then size = le64(payload, pidx); pidx = pidx + 8 end
					if comp_size == 0xFFFFFFFF then comp_size = le64(payload, pidx); pidx = pidx + 8 end
					if header_offset == 0xFFFFFFFF then header_offset = le64(payload, pidx); pidx = pidx + 8 end
					break
				end
				j = j + 4 + elen
			end
		end
		table.insert(entries, {name = name, method = method, crc = crc, comp = comp_size, size = size, header_offset = header_offset, flags = flags})
		i = i + 46 + name_len + extra_len + comment_len
	end

	-- helper: sanitize file name to prevent zip-slip
	local function sanitize_name(n)
		n = n or ''
		n = n:gsub('^/*', '') -- strip leading slashes
		n = n:gsub('^%a:[\\/]+', '') -- strip Windows drive letters
		local parts = {}
		for part in n:gmatch('[^/]+') do
			if part == '..' then
				if #parts > 0 then table.remove(parts) end
			elseif part ~= '.' and part ~= '' then
				table.insert(parts, part)
			end
		end
		return table.concat(parts, '/')
	end

	-- extract entries
	for _, e in ipairs(entries) do
		local sname = sanitize_name(e.name)
		if sname == '' then goto continue end
		local sep = package.config:sub(1,1)
		local outpath = sname:gsub('/', sep)
		local full = out_dir .. (out_dir:sub(-1) == sep and '' or sep) .. outpath
		local dir = full:match('^(.+)[\\/]') or out_dir
		make_dir(dir)

	-- read local header to find data start
		f:seek('set', e.header_offset)
		local lh = f:read(30)
	-- inspect local header
		if not lh or #lh < 30 then f:close(); return nil, 'local header truncated' end
		local lnam = le16(lh, 27)
		local lextra = le16(lh, 29)
		local data_offset = e.header_offset + 30 + lnam + lextra
	f:seek('set', data_offset)
	local data = f:read(e.comp)
	if not data and e.comp > 0 then f:close(); return nil, 'compressed data truncated' end

		local outdata, oerr
		if e.method == 0 then
			outdata = data or ''
		elseif e.method == 8 then
			outdata, oerr = inflate_deflate(data)
			if not outdata then f:close(); return nil, oerr end
		else
			f:close(); return nil, 'unsupported method '..tostring(e.method)
		end

		if e.name:sub(-1) ~= '/' then
			local wf, werr = io_open(full, 'wb')
			if not wf then f:close(); return nil, werr end
			wf:write(outdata)
			wf:close()
			local got = crc32(outdata)
			if got ~= e.crc then f:close(); return nil, string.format('CRC mismatch for %s: expected %08X got %08X', e.name, e.crc, got) end
		else
			make_dir(full)
		end
		::continue::
	end

	f:close()
	return true
end
-- (Old duplicate unzip_file removed; ZIP64-aware unzip_file is defined earlier)

local function dir_exists(path)
	-- Try opening with appended separator
	local sep = is_windows() and '\\' or '/'
	local test = path .. sep .. 'NUL'
	if is_windows() then
		-- Windows: use io.popen to test
		local cmd = 'if exist ' .. shell_quote(path .. '\\NUL') .. ' (echo d)'
		local p = io.popen(cmd)
		if not p then return false end
		local out = p:read('*a')
		p:close()
		return out and out:match('d')
	else
		-- Unix-like: use io.popen with test -d
		local p = io.popen('[ -d ' .. shell_quote(path) .. ' ] && echo d')
		if not p then return false end
		local out = p:read('*a')
		p:close()
		return out and out:match('d')
	end
end

local function enumerate_files(dir)
	local files = {}
	if is_windows() then
		local cmd = 'dir /b /s /a:-D ' .. shell_quote(dir)
		local p = io.popen(cmd)
		if not p then return files end
		for line in p:lines() do table.insert(files, line) end
		p:close()
	else
		local cmd = 'find ' .. shell_quote(dir) .. ' -type f -print'
		local p = io.popen(cmd)
		if not p then return files end
		for line in p:lines() do table.insert(files, line) end
		p:close()
	end
	return files
end

local function enumerate_dirs(dir)
	local dirs = {}
	if is_windows() then
		local cmd = 'dir /b /s /ad ' .. shell_quote(dir)
		local p = io.popen(cmd)
		if not p then return dirs end
		for line in p:lines() do table.insert(dirs, line) end
		p:close()
	else
		local cmd = 'find ' .. shell_quote(dir) .. ' -type d -print'
		local p = io.popen(cmd)
		if not p then return dirs end
		for line in p:lines() do table.insert(dirs, line) end
		p:close()
	end
	return dirs
end

-- Add a directory tree; base is how it appears inside the zip (optional)
function ZipWriter:add_tree(path, base)
	base = base or ''
	path = path:gsub('[\\/]+$', '') -- trim trailing separators
	local files = enumerate_files(path)
	local dirs = enumerate_dirs(path)
	table.sort(dirs, function(a,b) return #a < #b end)
	-- add directories first (so empty dirs are preserved)
	for _, d in ipairs(dirs) do
		local rel = d:sub(#path+2)
		if rel and #rel > 0 then
			local arc = (base == '' and rel) or (base .. '/' .. rel)
			arc = zip_path(arc)
			self:add_directory(arc)
		end
	end
	for _, f in ipairs(files) do
		local rel = f:sub(#path+2)
		local arc = (base == '' and rel) or (base .. '/' .. rel)
		arc = zip_path(arc)
		self:add_file(f, arc)
	end
	return true
end

-- Streaming write support
function ZipWriter:start_file_stream(name)
	name = zip_path(name)
	local dos_time, dos_date = dos_datetime(os_date('*t'))
	-- write local header with zeros for crc/size, set flag bit 3 (data descriptor follows)
	local local_header = table.concat{
		string.char(0x50,0x4b,0x03,0x04), -- signature
		u16(20), u16(0x08), -- flags with bit 3 set (use data descriptor)
		u16(0), -- method unknown yet (0 stored), we'll write stored
		dos_time, dos_date,
		u32(0), u32(0), u32(0), -- crc, comp, size = 0
		u16(#name), u16(0), name
	}
	local header_offset = self.offset
	self:_write(local_header)
	-- prepare stream state
		self._stream = {name = name, offset = header_offset, crc = 0xFFFFFFFF, size = 0, method = 0}
		-- if compression enabled, create deflater
		if self.compress then
			self._stream.method = 8
			-- simple deflater: buffer until finish; to keep streaming, we expose an object with deflate_chunk and finish
			local buffer = {}
			local total = 0
			local function feed(chunk)
				table.insert(buffer, chunk)
				total = total + #chunk
				return '' -- no immediate output in this simple builder
			end
			local function finish()
				local all = table.concat(buffer)
				return deflate_lz77(all, self.level)
			end
			self._stream._feed = feed
			self._stream._finish = finish
		end
	return true
end

function ZipWriter:write_chunk(chunk)
	if not self._stream then return nil, 'no active stream' end
	-- update CRC incrementally using crc table
	local crc = self._stream.crc
	local tbl = (function()
		-- rebuild CRC table quickly
		local poly = 0xEDB88320
		local t = {}
		for i = 0,255 do
			local c = i
			for j = 1,8 do
				if (c & 1) ~= 0 then c = poly ~ (c >> 1) else c = c >> 1 end
			end
			t[i] = c
		end
		return t
	end)()
		for i = 1, #chunk do
			local b = chunk:byte(i)
			crc = (__crc_table[(crc ~ b) & 0xFF] ~ (crc >> 8)) & 0xFFFFFFFF
		end
	self._stream.crc = crc
	self._stream.size = self._stream.size + #chunk
	-- write data
		if self._stream.method == 8 then
			-- compression enabled: feed into stream deflater
			self._stream._feed(chunk)
			-- do not write raw chunk; compressed output will be written on finish
		else
			self:_write(chunk)
		end
	return true
end

-- ZipWriter:finish_file_stream()
--
-- Finish a streaming file previously started with start_file_stream(). This
-- function finalizes CRC and size bookkeeping, emits any buffered compressed
-- bytes (the current streaming compressor implementation buffers the whole
-- file and compresses at finish), writes the data descriptor (since local
-- header used bit 3 to indicate sizes/CRC will follow), and appends a central
-- directory entry for the file. If sizes or offsets are larger than 32-bit,
-- a ZIP64 extra field is added to the central-directory record for this
-- entry.
function ZipWriter:finish_file_stream()
	if not self._stream then return nil, 'no active stream' end
	local crc = (self._stream.crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
	local size = self._stream.size
	local comp_size = size
	local header_offset = self._stream.offset
	-- if compression enabled, produce compressed data now
	if self._stream.method == 8 then
		local comp = self._stream._finish()
		comp_size = #comp
		self:_write(comp)
	end
	-- write data descriptor: signature + crc + comp_size + size
	local desc = table.concat{string.char(0x50,0x4b,0x07,0x08), u32(crc), u32(comp_size), u32(size)}
	self:_write(desc)
	-- also add central directory entry
	local dos_time, dos_date = dos_datetime(os_date('*t'))
	-- central directory extra for ZIP64 if necessary
	local extra = ''
	local cd_comp_size = comp_size
	local cd_size = size
	local cd_offset = header_offset
	if comp_size > MAX32 or size > MAX32 or header_offset > MAX32 then
		local zbuf = {}
		if size > MAX32 then table.insert(zbuf, u64(size)) else table.insert(zbuf, u64(0)) end
		if comp_size > MAX32 then table.insert(zbuf, u64(comp_size)) else table.insert(zbuf, u64(0)) end
		if header_offset > MAX32 then table.insert(zbuf, u64(header_offset)) else table.insert(zbuf, u64(0)) end
		extra = string.char(0x01,0x00) .. u16(#table.concat(zbuf)) .. table.concat(zbuf)
		cd_comp_size = math.min(comp_size, MAX32)
		cd_size = math.min(size, MAX32)
		cd_offset = math.min(header_offset, MAX32)
	end
	local method = self._stream.method or 0
	local ver_made = 20
	local ver_needed = 20
	if #extra > 0 then ver_made = 45; ver_needed = 45 end
	local central = table.concat{
		string.char(0x50,0x4b,0x01,0x02),
		u16(ver_made), u16(ver_needed),
		u16(0x08), -- flags (data descriptor used)
		u16(method), -- method
		dos_time, dos_date,
		u32(crc),
		u32(cd_comp_size),
		u32(cd_size),
		u16(#self._stream.name),
		u16(#extra), -- extra len
		u16(0), -- comment len
		u16(0), -- disk
		u16(0), -- int attr
		u32(0), -- ext attr
		u32(cd_offset),
		self._stream.name,
		extra
	}
	table.insert(self.entries, central)
	self._stream = nil
	return true
end


-- CLI
local function usage()
	io.stderr:write("Usage:\n")
	io.stderr:write("  Create: lua test.lua [-z|--deflate] [-l|--level N] out.zip in1 [in2 ...]\n")
	io.stderr:write("  Extract: lua test.lua -x|--extract archive.zip [out_dir]\n")
end

local function main(args)
	if #args < 2 then usage(); return end
		local compress = false
		local level = 6
		local idx = 1
		local extract = false
		while idx <= #args and args[idx]:sub(1,1) == '-' do
			local a = args[idx]
			if a == '-x' or a == '--extract' then extract = true; idx = idx + 1
			elseif a == '-z' or a == '--deflate' then compress = true; idx = idx + 1
			elseif a == '-l' or a == '--level' then
				if args[idx+1] then level = tonumber(args[idx+1]) or level; idx = idx + 2 else usage(); return end
			else
				-- unknown flag
				usage(); return
			end
		end
		if extract then
			local archive = args[idx]
			if not archive then usage(); return end
			local outdir = args[idx+1] or '.'
			local ok, err = unzip_file(archive, outdir)
			if not ok then io.stderr:write('Extract failed: ' .. tostring(err) .. '\n') else print('Extracted to', outdir) end
			return
		end

		local out = args[idx]
		if not out then usage(); return end
		local zw, err = ZipWriter.new(out, {compress = compress, level = level})
		if not zw then io.stderr:write('Error creating ' .. out .. ': ' .. tostring(err) .. '\n'); return end
		for i = idx + 1, #args do
			local p = args[i]
			if file_exists(p) then
				-- file
				local name = p:gsub('^.*[\\/]', '')
				zw:add_file(p, name)
			else
				-- assume directory
				local base = p:gsub('^.*[\\/]', '')
				zw:add_tree(p, base)
			end
		end
		zw:close()
		print('Wrote', out)
end

-- When executed directly, run main. If this file is required as a module,
-- the host can call ZipWriter/unzip_file directly.
-- When executed directly, build args from `arg` and run main.
local argv2 = {}
if type(arg) == 'table' then for i = 1, #arg do argv2[i] = arg[i] end end
if #argv2 > 0 then main(argv2) end
end

