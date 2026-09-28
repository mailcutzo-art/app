-- room_leave: a member leaves or is kicked (then they can't come back). The host's leaving
-- hands the room to the earliest-joined connected player (group) or closes it (friend,
-- "host_left"); the last one out closes it ("empty").
-- KEYS[1] room hash. ARGV: uid, "1" when kicked.
-- Returns {status, detail}: left (the host now), closed (the reason) or not_member.
local r = load_room(KEYS[1])
if not r or r.status == 'closed' then return {'not_member', ''} end
local uid = ARGV[1]
if not r.members[uid] then return {'not_member', ''} end
local now = now_ms()
if ARGV[2] == '1' then
  redis.call('SADD', r.base .. ':k', uid)
end
redis.call('HDEL', r.base .. ':m', uid)
r.members[uid] = nil
for i, other in ipairs(r.order) do
  if other == uid then
    table.remove(r.order, i)
    break
  end
end
local busy = redis.call('GET', 'busy:' .. uid)
if busy == 'r:' .. r.id or ((r.h.match or '') ~= '' and busy == 'm:' .. r.h.match) then
  redis.call('DEL', 'busy:' .. uid)
end
if #r.order == 0 then
  close_room(r, 'empty', now)
  return {'closed', 'empty'}
end
if uid == r.host then
  if r.kind == 'friend' then
    close_room(r, 'host_left', now)
    return {'closed', 'host_left'}
  end
  set_host(r, earliest(r, nil) or r.order[1])
end
set_field(r, 'autostart_at', 0)
touch(r, now)
emit_state(r, now)
reschedule(r)
return {'left', r.host}
