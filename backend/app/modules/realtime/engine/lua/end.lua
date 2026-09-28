-- end: a tournament round's deadline passed, so a game still running ends now (docs/plan.md,
-- Phase 5). After question 1 it finishes on the current score; before it, the players who
-- weren't ready are no-shows (everyone, if the countdown never finished).
-- KEYS[1] match hash. Returns {status, ver, due}.
local m = load_match(KEYS[1])
if not m then return {'missing', 0, 0} end
if terminal(m.phase) then return {'noop', m.ver, 0} end
local now = now_ms()
bump(m)
if m.q == 0 then
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
