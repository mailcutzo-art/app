-- room_op: one change to a lobby, emitted as room.state.
-- KEYS[1] room hash. ARGV: op, uid, arg JSON, settings JSON text (op "settings" only).
-- Ops (the host's are checked here):
--   conn {connected}    the member's socket came or went (disc_ms starts the host's timers)
--   away {away}         the member's app went to the background or came back
--   ready {ready}       lobby or between games; a friend duel starts autostart_ms after both
--   settings            host; lobby or between games; everyone's ready is reset
--   lock {locked}       host
--   transfer {uid}      host; to another player
--   rematch {accept}    after a game: friend duels need both within the window (then
--                       "start"); in a group it says "count me in" for Play again
--   started {match_id}  the game of a claimed start exists: room.started
--   unstart             the claimed start failed: back to where it was
--   end                 host: the room closes ("host_ended"); returns closed
-- Returns {status, detail}: ok, noop, start, offered, declined, not_found, not_member,
-- not_host, wrong_status, bad_target, expired or stale.
local r = load_room(KEYS[1])
if not r or r.status == 'closed' then return {'not_found', ''} end
local op, uid = ARGV[1], ARGV[2]
local arg = cjson.decode(ARGV[3])
local now = now_ms()
local mem = r.members[uid]
local system = op == 'started' or op == 'unstart'
if not system and not mem then return {'not_member', ''} end
if (op == 'settings' or op == 'lock' or op == 'transfer') and uid ~= r.host then
  return {'not_host', ''}
end
local between = r.status == 'lobby' or r.status == 'finished'

-- A friend duel starts by itself a few seconds after both players are ready and here.
local function arm_autostart()
  local all = r.kind == 'friend' and r.status == 'lobby' and #r.order == 2
  for _, other in ipairs(r.order) do
    local o = r.members[other]
    if not (o.ready and o.connected) then all = false end
  end
  if all then
    set_field(r, 'autostart_at', now + num(r.h.autostart_ms))
  else
    set_field(r, 'autostart_at', 0)
  end
end

if op == 'conn' then
  local connected = arg.connected == true
  if connected == mem.connected then return {'noop', ''} end
  mem.connected = connected
  mem.disc_ms = connected and 0 or now
  save_member(r, uid)
  arm_autostart()
elseif op == 'away' then
  local away = arg.away == true
  if away == mem.away then return {'noop', ''} end
  mem.away = away
  save_member(r, uid)
elseif op == 'ready' then
  if not between then return {'wrong_status', ''} end
  mem.ready = arg.ready == true
  save_member(r, uid)
  arm_autostart()
  touch(r, now)
elseif op == 'settings' then
  if not between then return {'wrong_status', ''} end
  set_field(r, 'settings', ARGV[4])
  reset_ready(r)
  set_field(r, 'autostart_at', 0)
  touch(r, now)
elseif op == 'lock' then
  set_field(r, 'locked', arg.locked and '1' or '0')
  touch(r, now)
elseif op == 'transfer' then
  local target = r.members[arg.uid]
  if not target or target.spectator or arg.uid == r.host then return {'bad_target', ''} end
  set_host(r, arg.uid)
  touch(r, now)
elseif op == 'rematch' then
  local rm = rematch_of(r)
  if r.status ~= 'finished' or not rm then return {'wrong_status', ''} end
  if now > rm['until'] then return {'expired', ''} end
  touch(r, now)
  if r.kind == 'group' then
    mem.ready = arg.accept ~= false
    save_member(r, uid)
  elseif arg.accept == false then
    set_field(r, 'rematch', '')
    set_status(r, 'lobby')
    reset_ready(r)
    emit_state(r, now)
    reschedule(r)
    return {'declined', ''}
  else
    rm.accepted[uid] = true
    if rm.offered_by == nil or rm.offered_by == cjson.null then rm.offered_by = uid end
    set_field(r, 'rematch', cjson.encode(rm))
    local all = #r.order == 2
    for _, other in ipairs(r.order) do
      if not rm.accepted[other] then all = false end
    end
    emit_state(r, now)
    reschedule(r)
    if all then return {'start', ''} end
    return {'offered', ''}
  end
elseif op == 'started' then
  if r.status ~= 'starting' or r.h.match ~= arg.match_id then return {'stale', ''} end
  set_status(r, 'playing')
  set_field(r, 'games', num(r.h.games) + 1)
  reset_ready(r)
  touch(r, now)
  room_emit(r, 'room.started', {match_id = arg.match_id, ch = 'm:' .. arg.match_id}, now)
elseif op == 'unstart' then
  if r.status ~= 'starting' then return {'noop', ''} end
  set_status(r, r.h.back or 'lobby')
  set_field(r, 'match', r.h.previous or '')
elseif op == 'end' then
  if uid ~= r.host then return {'not_host', ''} end
  close_room(r, 'host_ended', now)
  return {'closed', 'host_ended'}
else
  return {'bad_target', ''}
end
emit_state(r, now)
reschedule(r)
return {'ok', ''}
