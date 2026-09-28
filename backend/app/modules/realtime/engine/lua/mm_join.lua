-- mm_join: takes the player's busy slot and queues a ticket. A requeue passes the busy value
-- it replaces (the match that fell through) and the ticket's original joined_ms.
-- KEYS: busy:<uid>, mm:t:<ticket>, mm:q:<mode>:<subject>.
-- ARGV: ticket, fields JSON (uid, mode, subject, chapter, rating, rd, device, hold_id, first,
--   joined_ms?, deadline_ms?), busy TTL (s), max wait (ms), minimum time left on a requeue
--   (ms), busy value that may be replaced ('' for none).
-- Returns {"ok", joined_ms} or {"busy", current busy value}.
local busy, ticket_key, queue = KEYS[1], KEYS[2], KEYS[3]
local ticket = ARGV[1]
local f = cjson.decode(ARGV[2])
local current = redis.call('GET', busy)
if current and current ~= ARGV[6] then return {'busy', current} end
local now = now_ms()
local joined = tonumber(f.joined_ms) or now
local deadline = tonumber(f.deadline_ms) or (now + tonumber(ARGV[4]))
if f.joined_ms then deadline = math.max(deadline, now + tonumber(ARGV[5])) end
redis.call('SET', busy, 'q:' .. ticket, 'EX', ARGV[3])
redis.call('DEL', ticket_key)
redis.call('HSET', ticket_key,
  'uid', f.uid, 'mode', f.mode, 'subject', f.subject, 'chapter', f.chapter,
  'rating', f.rating, 'rd', f.rd, 'device', f.device, 'hold_id', f.hold_id,
  'first', f.first, 'joined_ms', joined, 'deadline_ms', deadline,
  'last_status', f.last_status or '', 'timeouts', 0, 'bg_ms', 0, 'disc_ms', 0)
redis.call('EXPIRE', ticket_key, ARGV[3])
redis.call('ZADD', queue, f.rating, ticket)
redis.call('SADD', 'mm:queues', f.mode .. ':' .. f.subject)
return {'ok', joined}
