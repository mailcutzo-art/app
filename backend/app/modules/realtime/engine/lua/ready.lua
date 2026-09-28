-- ready: a player's VS screen is up. Once every human is ready (in a group battle: every
-- connected one) the countdown starts, and the first question goes live as it ends.
-- KEYS[1] match hash. ARGV: uid. Returns {status, ver, due}.
local m = load_match(KEYS[1])
if not m then return {'missing', 0, 0} end
local uid = ARGV[1]
local p = m.p[uid]
if not p or uid == m.bot then return {'not_player', m.ver, m.due} end
if m.phase ~= 'ready_wait' or p.ready or p.left then return {'ok', m.ver, m.due} end
p.ready = true
save_player(m, uid)
bump(m)
for _, other in ipairs(m.humans) do
  local o = m.p[other]
  local counts = not is_group(m) or (o.connected and not o.left)
  if counts and not o.ready then return {'ok', m.ver, m.due} end
end
start_countdown(m, now_ms())
return {'ok', m.ver, m.due}
