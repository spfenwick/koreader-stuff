--[[ Running a store's CREATE TABLE IF NOT EXISTS block only when it's needed.

Every store call opens its own connection, and on a Kobo running a store's
schema costs about 4 ms even when every table is there: ~0.2 s a sync, on
the UI thread. SQLite's schema_version (in the file's header, so cheap to
read) goes up on every CREATE, ALTER and DROP, and starts again in a new
file. So a store that has run its schema on a database at version v knows
its tables are still there while the version is v; a deleted, replaced or
altered database has another version and gets the schema again.
]]

local M = {}

local function version(conn)
    local v = conn:rowexec("PRAGMA schema_version;")
    return v ~= nil and tonumber(v) or nil
end

--- Runs schema on conn unless the caller ran it on this database (path) and
-- the database's schema hasn't changed since. known is the caller's own
-- table, path -> schema_version after its schema last ran.
function M.ensure(conn, path, schema, known)
    local v = version(conn)
    if v ~= nil and known[path] == v then return end
    conn:exec(schema)
    known[path] = version(conn)
end

return M
