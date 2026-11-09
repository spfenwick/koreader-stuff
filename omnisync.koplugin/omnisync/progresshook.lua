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

--- Wraps Client.get_progress (once). deps: peers(md5) -> { md5, … },
-- schedule(fn) (run fn soon, outside the current request), logger.
function ProgressHook.install(Client, deps)
    if Client._omnisync_get_progress then return false end
    local orig = Client.get_progress
    Client._omnisync_get_progress = orig
    local log = deps.logger

    Client.get_progress = function(self, username, password, document, callback)
        local ok, peers = pcall(deps.peers, document)
        if not ok then
            if log then log.warn("OmniSync: progress: looking up other versions failed:", peers) end
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
                    log.info("OmniSync: progress: newest from another version of the book,", body.document)
                end
                local cok, err = pcall(callback, own_ok, body)
                if not cok and log then log.warn("OmniSync: progress: progress sync's callback failed:", err) end
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
                        if log then log.warn("OmniSync: progress: request failed:", err) end
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
