-- room_create: a new lobby with its host as the first member. The host's busy slot must be
-- free and the code unused; both are taken here, atomically.
-- KEYS[1] room hash. ARGV[1] config JSON: {id, kind, code, host, card, settings (JSON text),
--   capacity, idle_ms, handover_ms, host_left_ms, autostart_ms, rematch_ms, again_ms,
--   rematch_max, ttl}.
-- Returns {status, detail}: ok, busy (the busy value in the way), code_taken or exists.
local base = KEYS[1]
local c = cjson.decode(ARGV[1])
if redis.call('EXISTS', base) == 1 then return {'exists', ''} end
local busy = redis.call('GET', 'busy:' .. c.host)
if busy then return {'busy', busy} end
if not redis.call('SET', 'room:code:' .. c.code, c.id, 'NX', 'EX', c.ttl) then
  return {'code_taken', ''}
end
local now = now_ms()
redis.call('HSET', base,
  'id', c.id, 'kind', c.kind, 'code', c.code, 'host', c.host, 'status', 'lobby',
  'locked', '0', 'settings', c.settings, 'capacity', c.capacity, 'seq', 0,
  'created_ms', now, 'active_ms', now, 'match', '', 'games', 0, 'rematch', '',
  'autostart_at', 0, 'idle_ms', c.idle_ms, 'handover_ms', c.handover_ms,
  'host_left_ms', c.host_left_ms, 'autostart_ms', c.autostart_ms, 'rematch_ms', c.rematch_ms,
  'again_ms', c.again_ms, 'rematch_max', c.rematch_max, 'ttl', c.ttl, 'closed_reason', '')
local connected = redis.call('EXISTS', 'rt:conn:' .. c.host) == 1
redis.call('HSET', base .. ':m', c.host, cjson.encode({
  card = c.card, ready = false, connected = connected, away = false, joined_ms = now,
  disc_ms = connected and 0 or now, spectator = false,
}))
redis.call('SET', 'busy:' .. c.host, 'r:' .. c.id, 'EX', c.ttl)
local r = load_room(base)
touch(r, now)
emit_state(r, now)
reschedule(r)
return {'ok', ''}
