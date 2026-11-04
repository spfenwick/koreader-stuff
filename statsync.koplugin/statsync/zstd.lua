--[[--
zstd compression of segment files, with the libzstd KOReader ships (the one
its ffi/zstd.lua and persist.lua use). Unlike ffi/zstd.lua, decompression
checks the size the file says it holds before allocating, and failures are
returned, not raised: a downloaded file can be anything.
--]]

local ffi = require("ffi")
require("ffi/zstd_h")

local lib = ffi.loadlib("zstd", "1")

local Zstd = {}

Zstd.LEVEL = 3                      -- zstd's default: fast, about as small as gzip -9
Zstd.MAX_SIZE = 32 * 1024 * 1024    -- refuse to unpack more than this (a segment is ~2 MB)

-- ZSTD_getFrameContentSize's "unknown" and "error" values.
local SIZE_ERROR = 0xFFFFFFFFFFFFFFFEULL

local function errName(code)
    return ffi.string(lib.ZSTD_getErrorName(code))
end

function Zstd.compress(data, level)
    local bound = lib.ZSTD_compressBound(#data)
    local buf = ffi.new("uint8_t[?]", bound)
    local n = lib.ZSTD_compress(buf, bound, data, #data, level or Zstd.LEVEL)
    if lib.ZSTD_isError(n) ~= 0 then return nil, "zstd: " .. errName(n) end
    return ffi.string(buf, n)
end

function Zstd.decompress(data, max_size)
    max_size = max_size or Zstd.MAX_SIZE
    local size = lib.ZSTD_getFrameContentSize(data, #data)
    if size >= SIZE_ERROR then return nil, "not zstd data (or its size isn't recorded)" end
    if size > max_size then return nil, "unpacks to more than " .. max_size .. " bytes" end
    local n = tonumber(size)
    local buf = ffi.new("uint8_t[?]", math.max(n, 1))
    local got = lib.ZSTD_decompress(buf, n, data, #data)
    if lib.ZSTD_isError(got) ~= 0 then return nil, "zstd: " .. errName(got) end
    if tonumber(got) ~= n then return nil, "zstd: size mismatch" end
    return ffi.string(buf, n)
end

local function readAll(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeAll(path, data)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    local ok, werr = f:write(data)
    f:close()
    if not ok then os.remove(path); return nil, werr end
    return true
end

--- Compresses in_path to out_path. Returns the compressed size, or nil, err.
function Zstd.compressFile(in_path, out_path, level)
    local data, err = readAll(in_path)
    if not data then return nil, err end
    local packed, cerr = Zstd.compress(data, level)
    if not packed then return nil, cerr end
    local ok, werr = writeAll(out_path, packed)
    if not ok then return nil, werr end
    return #packed
end

--- Decompresses in_path to out_path. Returns true, or nil, err.
function Zstd.decompressFile(in_path, out_path, max_size)
    local data, err = readAll(in_path)
    if not data then return nil, err end
    local plain, derr = Zstd.decompress(data, max_size)
    if not plain then return nil, derr end
    return writeAll(out_path, plain)
end

return Zstd
