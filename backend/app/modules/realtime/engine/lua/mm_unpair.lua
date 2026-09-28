-- mm_unpair: the match could not be created; puts both tickets back with their original
-- fields (and so their original joined_ms), for players still busy with that match.
-- KEYS: busy:<a>, busy:<b>, mm:t:<ta>, mm:t:<tb>, queue.
-- ARGV: ta, tb, match id, fields A JSON, fields B JSON, busy TTL (s). Returns how many.
local restored = 0
for i = 1, 2 do
  local ticket = ARGV[i]
  if redis.call('GET', KEYS[i]) == 'm:' .. ARGV[3] then
    local fields = cjson.decode(ARGV[3 + i])
    redis.call('SET', KEYS[i], 'q:' .. ticket, 'EX', ARGV[6])
    for k, v in pairs(fields) do redis.call('HSET', KEYS[2 + i], k, v) end
    redis.call('EXPIRE', KEYS[2 + i], ARGV[6])
    redis.call('ZADD', KEYS[5], fields.rating, ticket)
    restored = restored + 1
  end
end
return restored
