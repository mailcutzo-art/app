-- latency: a player's latency allowance, from the gateway's heartbeat round trips.
-- KEYS[1] match hash. ARGV: uid, allowance ms. Returns 1 if stored.
local raw = redis.call('HGET', KEYS[1] .. ':p', ARGV[1])
if not raw then return 0 end
local p = cjson.decode(raw)
p.lat_ms = tonumber(ARGV[2])
redis.call('HSET', KEYS[1] .. ':p', ARGV[1], cjson.encode(p))
return 1
