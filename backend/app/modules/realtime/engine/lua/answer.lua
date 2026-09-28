-- answer: validates, times and scores one answer in one atomic step, emits q.progress, and
-- reveals early once everyone who was here when the question opened has answered.
-- KEYS[1] match hash. ARGV: uid, q, option id, client el_ms, bot time ms ('' for humans).
-- Returns {status, dup (0/1), ver, due}. A repeat returns the first status with dup = 1.
local m = load_match(KEYS[1])
if not m then return {'invalid', 0, 0, 0} end
local uid, qi, opt = ARGV[1], tonumber(ARGV[2]), ARGV[3]
local el = math.floor(tonumber(ARGV[4]) or 0)
local bot_ms = tonumber(ARGV[5])
local p = m.p[uid]
if not p or (bot_ms ~= nil) ~= (uid == m.bot) then return {'invalid', 0, m.ver, m.due} end
if qi ~= nil and qi >= 1 and qi <= m.total then
  local previous = redis.call('HGET', qkey(m, qi), 'a:' .. uid)
  if previous then return {cjson.decode(previous).status, 1, m.ver, m.due} end
end
if m.phase ~= 'q_open' or qi ~= m.q then
  -- The question already closed: say so plainly ("Time's up") without recording anything.
  if qi ~= nil and qi >= 1 and qi <= m.q then return {'late', 0, m.ver, m.due} end
  return {'wrong_phase', 0, m.ver, m.due}
end
if p.left then return {'invalid', 0, m.ver, m.due} end
local key = qkey(m, qi)
local q = hgetall(key)
local valid = false
for _, option in ipairs(cjson.decode(q.options)) do
  if option.id == opt then valid = true end
end
if not valid then return {'invalid', 0, m.ver, m.due} end

local now = now_ms()
local raw, lat = now - num(q.shown_at), p.lat_ms
if bot_ms ~= nil then
  -- The bot's time is decided by the model, not by when the owner's timer ran.
  raw, el, lat = bot_ms, bot_ms, 0
end
local e, status, ok, pts = judge(raw, el, lat, num(q.limit_ms), opt == q.correct)
redis.call('HSET', key, 'a:' .. uid, cjson.encode({
  opt = opt, raw = raw, e = e, ok = ok, pts = pts, status = status, recv = now, el = el,
}))
bump(m)

local answered = {}
for _, other in ipairs(m.players) do
  if redis.call('HEXISTS', key, 'a:' .. other) == 1 then table.insert(answered, other) end
end
emit(m, 'q.progress', {q = qi, answered = list(answered)}, now)

local open = cjson.decode(q.open or '[]')
local everyone = #open > 0
for _, other in ipairs(open) do
  if redis.call('HEXISTS', key, 'a:' .. other) == 0 then everyone = false end
end
if everyone then reveal(m, now) end
return {status, 0, m.ver, m.due}
