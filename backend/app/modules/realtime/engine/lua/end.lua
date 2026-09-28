-- end: a group host ends the game early. It finishes on the current scores (ended_by_host);
-- before question 1 it is aborted.
-- KEYS[1] match hash. Returns {status, ver, due}.
local m = load_match(KEYS[1])
if not m then return {'missing', 0, 0} end
if terminal(m.phase) then return {'noop', m.ver, 0} end
local now = now_ms()
bump(m)
if m.q == 0 then
  finish(m, 'aborted', 'aborted', {}, {}, now)
else
  finish(m, 'finished', 'ended_by_host', {}, {}, now)
end
return {m.phase, m.ver, 0}
