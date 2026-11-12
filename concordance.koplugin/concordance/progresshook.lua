--[[--
Reading progress across versions of a book (see IDENTITY.md, Progress).

KOReader's progress sync plugin (kosync.koplugin) keeps one position per
book on its own server, keyed by the book's partial MD5, so two versions
of a book (a Calibre rewrite) keep two positions. This wraps its client's
get_progress: when the book has other versions with the same text (level 2
of book identity), their positions are fetched too and the newest of all
is handed back, as if the server had returned it. Everything else (when to
pull, asking before jumping, pushing) stays the progress sync plugin's.

Read-only: pushes still go to this file's MD5 only. Main process.
--]]

local ProgressHook = {}

--- The position to hand back: the newest by the server's timestamp; with
-- no timestamps, this file's own, else the furthest. own may be nil or
-- have no percentage (nothing on the server for this MD5).
function ProgressHook.pick(own, others)
    local best = own and own.percentage and own or nil
    for _, b in ipairs(others) do
        if not best then
            best = b
        elseif b.timestamp and best.timestamp then
            if b.timestamp > best.timestamp then best = b end
        elseif b.timestamp and not best.timestamp then
            best = b
        elseif not b.timestamp and not best.timestamp and best ~= own
            and tonumber(b.percentage) > tonumber(best.percentage) then
            best = b
        end
    end
    return best or own
end

--- Whether get_progress still looks like the one this wraps:
-- (self, username, password, document, callback). Returns true, or false
-- and why. A changed signature would put our arguments in the wrong places.
function ProgressHook.compatible(fn)
    if type(fn) ~= "function" then return false, "no get_progress" end
    local ok, info = pcall(debug.getinfo, fn, "u")
    -- Without nparams (not LuaJIT or Lua 5.2+) there's nothing to check.
    if not ok or type(info) ~= "table" or info.nparams == nil then return true end
    if info.nparams ~= 5 or info.isvararg then
        return false, "get_progress takes " .. tostring(info.nparams) .. (info.isvararg and "+" or "")
            .. " parameters, expected 5"
    end
    return true
end

--- Wraps Client.get_progress (once). deps: peers(md5) -> { md5, … },
-- schedule(fn) (run fn soon, outside the current request), logger.
-- Returns true if it's in place now, else false and why.
function ProgressHook.install(Client, deps)
    if Client._concordance_get_progress then return false, "already installed" end
    local fits, why = ProgressHook.compatible(Client.get_progress)
    if not fits then
        if deps.logger then deps.logger.warn("Concordance: progress sync changed, not finding other versions' positions:", why) end
        return false, why
    end
    local orig = Client.get_progress
    Client._concordance_get_progress = orig
    local log = deps.logger

    Client.get_progress = function(self, username, password, document, callback)
        local ok, peers = pcall(deps.peers, document)
        if not ok then
            if log then log.warn("Concordance: progress: looking up other versions failed:", peers) end
            peers = nil
        end
        if type(document) ~= "string" or not peers or #peers == 0 then
            return orig(self, username, password, document, callback)
        end
        return orig(self, username, password, document, function(own_ok, own)
            -- This MD5's request failed: the network's down, report that.
            if not own_ok then return callback(own_ok, own) end
            local found = {}
            local i = 0
            local function finish()
                local body = ProgressHook.pick(type(own) == "table" and own or nil, found)
                if log and body ~= own then
                    log.info("Concordance: progress: newest from another version of the book,", body.document)
                end
                local cok, err = pcall(callback, own_ok, body)
                if not cok and log then log.warn("Concordance: progress: progress sync's callback failed:", err) end
            end
            local function nextPeer()
                i = i + 1
                if i > #peers then return finish() end
                local md5 = peers[i]
                -- Outside the request that just finished, so requests don't nest.
                deps.schedule(function()
                    local rok, err = pcall(orig, self, username, password, md5, function(pok, body)
                        if pok and type(body) == "table" and tonumber(body.percentage) then
                            body.document = body.document or md5
                            found[#found + 1] = body
                        end
                        nextPeer()
                    end)
                    if not rok then
                        if log then log.warn("Concordance: progress: request failed:", err) end
                        nextPeer()
                    end
                end)
            end
            nextPeer()
        end)
    end
    return true
end

return ProgressHook
