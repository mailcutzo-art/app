-- mm_cancel: ends a queued ticket if the player's busy slot still points at it.
-- KEYS: busy:<uid>, mm:t:<ticket>, mm:q:<mode>:<subject>. ARGV: ticket.
-- Returns {"cancelled", hold id}, {"matched", match id} when a match was found first, or
-- {"gone", ""}.
local busy, ticket_key, queue = KEYS[1], KEYS[2], KEYS[3]
local ticket = ARGV[1]
local current = redis.call('GET', busy)
if current == 'q:' .. ticket then
  local hold = redis.call('HGET', ticket_key, 'hold_id') or ''
  redis.call('DEL', busy, ticket_key)
  redis.call('ZREM', queue, ticket)
  return {'cancelled', hold}
end
redis.call('DEL', ticket_key)
redis.call('ZREM', queue, ticket)
if current and string.sub(current, 1, 2) == 'm:' then return {'matched', string.sub(current, 3)} end
return {'gone', ''}
