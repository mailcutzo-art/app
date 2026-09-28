-- advance: the timer transition. It acts only once due; a version other than ARGV[1] means
-- another node moved the match on, and the caller reschedules from the returned due.
-- KEYS[1] match hash. ARGV: expected ver (-1: any). Returns {status, ver, due}, where status
-- is the new phase, or stale / early / wait / done / missing.
local m = load_match(KEYS[1])
if not m then return {'missing', 0, 0} end
if terminal(m.phase) then
  redis.call('ZREM', TIMERS, m.id)
  return {'done', m.ver, 0}
end
local expected = tonumber(ARGV[1])
if expected >= 0 and m.ver ~= expected then return {'stale', m.ver, m.due} end
local now = now_ms()

-- Humans past their grace lose. If every human went away within the void window of each
-- other, the match is voided instead, once the last of them is past their grace.
local expired, first = {}, 0
for _, uid in ipairs(m.humans) do
  local p = m.p[uid]
  if not p.connected and not p.left and p.grace_until > 0 and p.grace_until <= now then
    table.insert(expired, uid)
    if first == 0 or p.grace_until < first then first = p.grace_until end
  end
end
if #expired > 0 then
  if #m.humans >= 2 then
    local window = num(m.h.void_window_ms)
    local all_away, latest = true, 0
    for _, uid in ipairs(m.humans) do
      local p = m.p[uid]
      if p.connected or p.left or p.grace_until == 0 or p.grace_until > first + window then
        all_away = false
      elseif p.grace_until > latest then
        latest = p.grace_until
      end
    end
    if all_away then
      bump(m)
      if latest > now then
        m.due = latest
        redis.call('HSET', m.base, 'due', latest)
        redis.call('ZADD', TIMERS, latest, m.id)
        return {'wait', m.ver, latest}
      end
      finish(m, 'voided', 'voided', {}, {away = expired}, now)
      return {m.phase, m.ver, 0}
    end
  end
  bump(m)
  if m.q == 0 then
    finish(m, 'aborted', 'aborted', {}, {away = expired}, now)
  else
    finish(m, 'finished', 'disconnected', expired, {away = expired}, now)
  end
  return {m.phase, m.ver, 0}
end

if now < m.pdue then return {'early', m.ver, m.due} end
bump(m)
if m.phase == 'ready_wait' then
  local not_ready, ready = {}, {}
  for _, uid in ipairs(m.humans) do
    if m.p[uid].ready then table.insert(ready, uid) else table.insert(not_ready, uid) end
  end
  finish(m, 'aborted', 'aborted', {}, {not_ready = list(not_ready), ready = list(ready)}, now)
  return {m.phase, m.ver, 0}
elseif m.phase == 'countdown' then
  open_question(m, 1, now)
elseif m.phase == 'q_open' then
  reveal(m, now)
elseif m.phase == 'q_reveal' then
  if m.q < m.total then
    open_question(m, m.q + 1, now)
  else
    finish(m, 'finished', 'normal', {}, {}, now)
    return {m.phase, m.ver, 0}
  end
end
return {m.phase, m.ver, m.due}
