-- snapshot: everything a match.snapshot needs for one viewer, read atomically so it matches
-- the returned seq exactly.
-- KEYS[1] match hash. ARGV: viewer uid. Returns a JSON object, or nil if the match is gone.
local base, viewer = KEYS[1], ARGV[1]
local h = hgetall(base)
if h.phase == nil then return nil end
local states = hgetall(base .. ':p')
local players = cjson.decode(h.players)
local q = num(h.q)
local answered, mine = {}, {}
local show, limit = cjson.null, redis.call('HGET', base .. ':q:1', 'limit_ms')
if q > 0 then
  local key = base .. ':q:' .. q
  show = redis.call('HGET', key, 'show') or cjson.null
  limit = redis.call('HGET', key, 'limit_ms')
  for _, uid in ipairs(players) do
    answered[uid] = redis.call('HEXISTS', key, 'a:' .. uid) == 1
  end
end
for i = 1, q do
  local raw = redis.call('HGET', base .. ':q:' .. i, 'a:' .. viewer)
  if raw then
    local a = cjson.decode(raw)
    table.insert(mine, {q = i, opt = a.opt, status = a.status})
  end
end
return encode({
  h = h,
  p = states,
  show = show,
  limit_ms = num(limit),
  answered = answered,
  mine = list(mine),
})
