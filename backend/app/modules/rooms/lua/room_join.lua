-- room_join: someone comes into the lobby (or, for a member, comes back). The checks that
-- need Postgres (blocks, friends only, tournaments) are the caller's; this one decides kicks,
-- the lock, capacity and the busy slot atomically.
-- KEYS[1] room hash. ARGV: uid, card JSON, "player" | "spectator".
-- Returns {status, detail}: joined (as), member (as), not_found, kicked, locked, starting,
-- full, or busy (the busy value in the way).
local r = load_room(KEYS[1])
if not r or r.status == 'closed' then return {'not_found', ''} end
local uid, as = ARGV[1], ARGV[3]
local now = now_ms()
local mem = r.members[uid]
if mem then
  if not mem.connected then
    mem.connected = true
    mem.disc_ms = 0
    save_member(r, uid)
    emit_state(r, now)
    reschedule(r)
  end
  return {'member', mem.spectator and 'spectator' or 'player'}
end
if redis.call('SISMEMBER', r.base .. ':k', uid) == 1 then return {'kicked', ''} end
if r.h.locked == '1' then return {'locked', ''} end
if r.status == 'starting' then return {'starting', ''} end
if #r.order >= num(r.h.capacity) then return {'full', ''} end
local busy = redis.call('GET', 'busy:' .. uid)
if busy and busy ~= 'r:' .. r.id then return {'busy', busy} end
redis.call('SET', 'busy:' .. uid, 'r:' .. r.id, 'EX', num(r.h.ttl))
r.members[uid] = {
  card = cjson.decode(ARGV[2]), ready = false, connected = true, away = false,
  joined_ms = now, disc_ms = 0, spectator = as == 'spectator',
}
table.insert(r.order, uid)
save_member(r, uid)
set_field(r, 'autostart_at', 0)
touch(r, now)
emit_state(r, now)
reschedule(r)
return {'joined', as}
