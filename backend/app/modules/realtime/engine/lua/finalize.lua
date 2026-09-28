-- finalize: after settlement commits. Marks the match settled, drops it from the settle queue
-- and the timers, and lets its keys expire.
-- KEYS[1] match hash. ARGV: match id, TTL (s) for the remaining keys. Returns the humans.
local base, mid, ttl = KEYS[1], ARGV[1], tonumber(ARGV[2])
redis.call('ZREM', SETTLE, mid)
redis.call('ZREM', TIMERS, mid)
redis.call('DEL', base .. ':lease')
local humans = redis.call('HGET', base, 'humans')
if not humans then return {} end
redis.call('HSET', base, 'settled', 1)
local total = num(redis.call('HGET', base, 'total'))
for _, suffix in ipairs({'', ':p', ':log', ':final'}) do
  redis.call('EXPIRE', base .. suffix, ttl)
end
for i = 1, total do redis.call('EXPIRE', base .. ':q:' .. i, ttl) end
local out = {}
for _, uid in ipairs(cjson.decode(humans)) do
  if redis.call('GET', 'busy:' .. uid) == 'm:' .. mid then redis.call('DEL', 'busy:' .. uid) end
  table.insert(out, uid)
end
return out
