-- conn: a player's socket connected or dropped. A drop starts the grace period (plus
-- ARGV[3] ms when the server itself is restarting) and pulls the timer earlier if the grace
-- deadline now comes first. The other players see opp.conn.
-- KEYS[1] match hash. ARGV: uid, "connected" | "dropped", extra grace ms.
-- Returns {status, ver, due}.
local m = load_match(KEYS[1])
if not m then return {'missing', 0, 0} end
if terminal(m.phase) then return {'noop', m.ver, 0} end
local uid, state, extra = ARGV[1], ARGV[2], num(ARGV[3])
local p = m.p[uid]
if not p or uid == m.bot then return {'not_player', m.ver, m.due} end
local now = now_ms()
if state == 'connected' then
  if p.connected then return {'noop', m.ver, m.due} end
  p.connected = true
  p.grace_until = 0
  save_player(m, uid)
  bump(m)
  emit(m, 'opp.conn', {uid = uid, state = 'connected', grace_until = cjson.null}, now)
else
  local until_ms = now + num(m.h.grace_ms) + extra
  -- Already away: only a restart can lengthen the grace.
  if not p.connected and (extra <= 0 or until_ms <= p.grace_until) then
    return {'noop', m.ver, m.due}
  end
  p.connected = false
  p.grace_until = until_ms
  save_player(m, uid)
  bump(m)
  emit(m, 'opp.conn', {uid = uid, state = 'reconnecting', grace_until = until_ms}, now)
end
schedule(m, m.pdue)
return {'ok', m.ver, m.due}
