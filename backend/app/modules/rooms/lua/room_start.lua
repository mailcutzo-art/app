-- room_start: claims the right to start a game (exactly one caller wins). The connected
-- players (not spectators) play; at least two are needed. The room waits in "starting" until
-- the game exists (room_op "started") or the start fails (room_op "unstart").
-- KEYS[1] room hash. ARGV: uid (the host, or '' for an automatic start), new match id.
-- Returns {status, detail}: ok (JSON list of players), not_found, not_host, wrong_status or
-- too_few.
local r = load_room(KEYS[1])
if not r or r.status == 'closed' then return {'not_found', ''} end
local uid, mid = ARGV[1], ARGV[2]
if uid ~= '' and uid ~= r.host then return {'not_host', ''} end
if r.status ~= 'lobby' and r.status ~= 'finished' then return {'wrong_status', ''} end
local players = {}
for _, other in ipairs(r.order) do
  local mem = r.members[other]
  if mem.connected and not mem.spectator then table.insert(players, other) end
end
if #players < 2 then return {'too_few', ''} end
local previous = r.h.match or ''
set_field(r, 'back', r.status)
set_field(r, 'previous', previous)
set_status(r, 'starting')
set_field(r, 'match', mid)
set_field(r, 'autostart_at', 0)
set_field(r, 'rematch', '')
reschedule(r)
return {'ok', cjson.encode(players)}
