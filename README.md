ziptool — pure-Lua ZIP utilities
lua_zip
======

A small, dependency-free pure-Lua ZIP utility library and CLI.

This repository exposes a simple API in `ziptool.lua` and provides a
lightweight CLI in `zip_cli.lua` plus tests in `tests/run_tests.lua`.

Quick start
-----------

1) Use `ZipWriter` to create an archive:

```lua
local ziptool = require('ziptool')

-- Create a zip and add files/directories
local zw, err = ziptool.ZipWriter.new('out.zip', { compress = true, level = 6 })
if not zw then error(err) end

-- Add an individual file (filesystem path, archive name optional)
local ok, e = zw:add_file('path/to/file.txt', 'file.txt')
assert(ok, e)

-- Add a directory tree recursively
assert(zw:add_tree('some/dir', 'dir'))

-- Finish and close the archive
assert(zw:close())
```

2) Add programmatic data as an entry (small payloads)

```lua
local zw = assert(ziptool.ZipWriter.new('data.zip', { compress = true }))
assert(zw:add_data('hello.txt', 'Hello world\n'))
assert(zw:close())
```

3) Extract a zip using `unzip_file`:

```lua
local ziptool = require('ziptool')
local ok, err = ziptool.unzip_file('out.zip', 'out_dir')
if not ok then error(err) end
```

Notes and behavior
------------------
- The compressor (`deflate_lz77`) implemented in this library is a small,
	pure-Lua LZ77-based deflater that emits spec-compliant fixed-Huffman
	blocks (readable by standard unzip tools). It is intended for
	portability rather than maximum compression.
- With `compress = true`, an entry uses DEFLATE only when the compressed
	data is smaller; otherwise it is stored. Set `force_deflate = true` to
	always use DEFLATE.
- Limitation: the inflater handles stored and fixed-Huffman DEFLATE blocks.
	Archives from other tools that use dynamic-Huffman blocks are not yet
	supported.
- ZIP64 is supported: the library will read/write ZIP64 records when
	entries, offsets or sizes exceed 32-bit limits.
- Extraction sanitizes entry names (including backslash separators) and
	verifies CRC and uncompressed size before writing files.
- Public API exported by `ziptool.lua`:
	- `ziptool.ZipWriter` (constructor + instance methods)
	- `ziptool.unzip_file` (extract zip into a directory)
	- `ziptool.deflate_lz77`, `ziptool.inflate_deflate`, `ziptool.crc32`
	- optional helpers: `ziptool.list_zip`, `ziptool.zip_dir`, `ziptool.zip_paths`

Running tests
-------------
Run the test suite from the repository root (requires `lua` in PATH):

```pwsh
lua tests/run_tests.lua
```

The suite covers create/extract round-trips, DEFLATE output compatibility,
store-vs-DEFLATE selection, streamed entries, ZIP64 records, name sanitizing
and CRC verification.

License
-------
(If you have a preferred license, add it here.)
