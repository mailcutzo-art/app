-- mm_pair: atomically takes two tickets out of the queue for a new match. Both tickets must
-- still exist and both players' busy slots must still point at them (a cancel may have won).
-- KEYS: busy:<a>, busy:<b>, mm:t:<ta>, mm:t:<tb>, queue. ARGV: ta, tb, match id, busy TTL (s).
-- Returns 1 if paired, 0 if not.
local ta, tb, mid = ARGV[1], ARGV[2], ARGV[3]
if redis.call('GET', KEYS[1]) ~= 'q:' .. ta or redis.call('GET', KEYS[2]) ~= 'q:' .. tb then
  return 0
end
if redis.call('EXISTS', KEYS[3]) == 0 or redis.call('EXISTS', KEYS[4]) == 0 then return 0 end
redis.call('ZREM', KEYS[5], ta, tb)
redis.call('DEL', KEYS[3], KEYS[4])
redis.call('SET', KEYS[1], 'm:' .. mid, 'EX', ARGV[4])
redis.call('SET', KEYS[2], 'm:' .. mid, 'EX', ARGV[4])
return 1
