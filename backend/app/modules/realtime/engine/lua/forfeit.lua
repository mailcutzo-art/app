-- forfeit: a player leaves on purpose. Once question 1 has opened they lose (reason
-- "forfeit"); before that the match is aborted. In a group battle the player just leaves.
-- KEYS[1] match hash. ARGV: uid. Returns {status, ver, due}.
local m = load_match(KEYS[1])
if not m then return {'missing', 0, 0} end
if terminal(m.phase) then return {'noop', m.ver, 0} end
local uid = ARGV[1]
local p = m.p[uid]
if not p or uid == m.bot then return {'not_player', m.ver, m.due} end
local now = now_ms()
if is_group(m) then
  -- Leaving a group battle: shown as left, scores 0 from now on, and may rejoin.
  if p.left then return {'noop', m.ver, m.due} end
  p.left = true
  p.connected = false
  p.grace_until = 0
  save_player(m, uid)
  bump(m)
  emit(m, 'opp.conn', {uid = uid, state = 'left', grace_until = cjson.null}, now)
  track_short(m, now)
  schedule(m, m.pdue)
  return {'left', m.ver, m.due}
end
p.left = true
save_player(m, uid)
bump(m)
if m.q == 0 then
  local ready = {}
  for _, other in ipairs(m.humans) do
    if other ~= uid then table.insert(ready, other) end
  end
  finish(m, 'aborted', 'aborted', {}, {left = {uid}, not_ready = {uid}, ready = list(ready)}, now)
else
  finish(m, 'finished', 'forfeit', {uid}, {left = {uid}}, now)
end
return {m.phase, m.ver, 0}
