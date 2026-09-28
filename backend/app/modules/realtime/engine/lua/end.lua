-- end: a running game ends now. ARGV[1] is the reason:
--   'deadline': a tournament round's deadline passed (docs/plan.md, Phase 5). After question 1
--     it finishes on the current score; before it, the players who weren't ready are no-shows
--     (everyone, if the countdown never finished).
--   'host': a group host ends the game early. It finishes on the current scores
--     (ended_by_host); before question 1 it is aborted.
-- KEYS[1] match hash. Returns {status, ver, due}.
local m = load_match(KEYS[1])
if not m then return {'missing', 0, 0} end
if terminal(m.phase) then return {'noop', m.ver, 0} end
local by_host = ARGV[1] == 'host'
local now = now_ms()
bump(m)
if by_host then
  if m.q == 0 then
    finish(m, 'aborted', 'aborted', {}, {}, now)
  else
    finish(m, 'finished', 'ended_by_host', {}, {}, now)
  end
elseif m.q == 0 then
  local absent = {}
  for _, uid in ipairs(m.humans) do
    if not m.p[uid].ready then table.insert(absent, uid) end
  end
  if #absent == 0 then absent = m.humans end
  no_show(m, absent, now)
else
  finish(m, 'finished', 'normal', {}, {forced = true}, now)
end
return {m.phase, m.ver, 0}
