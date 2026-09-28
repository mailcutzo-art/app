-- ready: a player's VS screen is up. Once every human is ready the countdown starts, and the
-- first question goes live as it ends.
-- KEYS[1] match hash. ARGV: uid. Returns {status, ver, due}.
local m = load_match(KEYS[1])
if not m then return {'missing', 0, 0} end
local uid = ARGV[1]
local p = m.p[uid]
if not p or uid == m.bot then return {'not_player', m.ver, m.due} end
if m.phase ~= 'ready_wait' or p.ready then return {'ok', m.ver, m.due} end
p.ready = true
save_player(m, uid)
bump(m)
for _, other in ipairs(m.humans) do
  if not m.p[other].ready then return {'ok', m.ver, m.due} end
end
local now = now_ms()
local ends = now + num(m.h.countdown_ms)
set_phase(m, 'countdown')
redis.call('HSET', m.base, 'ends_at', ends, 'started_ms', now)
emit(m, 'match.phase', {phase = 'countdown', q = 0, ends_at = ends}, now)
-- Question 1 is sent show_lead_ms early, so it goes live as the countdown ends.
schedule(m, math.max(now, ends - num(m.h.show_lead_ms)))
return {'ok', m.ver, m.due}
