-- forfeit: a player leaves on purpose. Once question 1 has opened they lose (reason
-- "forfeit"); before that the match is aborted.
-- KEYS[1] match hash. ARGV: uid. Returns {status, ver, due}.
local m = load_match(KEYS[1])
if not m then return {'missing', 0, 0} end
if terminal(m.phase) then return {'noop', m.ver, 0} end
local uid = ARGV[1]
local p = m.p[uid]
if not p or uid == m.bot then return {'not_player', m.ver, m.due} end
local now = now_ms()
p.left = true
save_player(m, uid)
bump(m)
if m.kind == 'tournament' and m.q == 0 then
  -- Leaving before question 1 is not showing up. Once everyone else is ready it decides the
  -- game at once; otherwise the ready deadline does.
  p.ready = false
  save_player(m, uid)
  local absent, waiting = {}, false
  for _, other in ipairs(m.humans) do
    local o = m.p[other]
    if o.left then
      table.insert(absent, other)
    elseif not o.ready then
      waiting = true
    end
  end
  if waiting and m.phase == 'ready_wait' then return {'ok', m.ver, m.due} end
  no_show(m, absent, now)
elseif m.q == 0 then
  local ready = {}
  for _, other in ipairs(m.humans) do
    if other ~= uid then table.insert(ready, other) end
  end
  finish(m, 'aborted', 'aborted', {}, {left = {uid}, not_ready = {uid}, ready = list(ready)}, now)
else
  finish(m, 'finished', 'forfeit', {uid}, {left = {uid}}, now)
end
return {m.phase, m.ver, 0}
