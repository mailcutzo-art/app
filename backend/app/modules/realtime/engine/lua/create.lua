-- create: writes a new match (idempotent), marks every human busy with it and schedules the
-- ready timeout.
-- KEYS[1] match hash. ARGV: config JSON, questions JSON, key TTL (s).
-- config: {id, kind, mode, subject, players, humans, bot, bot_acc, cards, meta, ready_ms,
--   reveal_ms, countdown_ms, show_lead_ms, answer_grace_ms, grace_ms, void_window_ms}
--   extra?: more hash fields (room games: room, rules, short_ms, standings, room_ttl)
-- questions: [{stem, options: [{id, text}], correct, ref, limit_ms, chapter}]
-- Returns {status, ver, due}.
local base = KEYS[1]
if redis.call('EXISTS', base) == 1 then
  return {'exists', num(redis.call('HGET', base, 'ver')), num(redis.call('HGET', base, 'due'))}
end
local c = cjson.decode(ARGV[1])
local questions = cjson.decode(ARGV[2])
local ttl = tonumber(ARGV[3])
local now = now_ms()
local ready_by = now + c.ready_ms
redis.call('HSET', base,
  'id', c.id, 'kind', c.kind, 'mode', c.mode, 'subject', c.subject,
  'phase', 'ready_wait', 'ver', 1, 'q', 0, 'total', #questions, 'revealed', 0,
  'reveal_ms', c.reveal_ms, 'countdown_ms', c.countdown_ms,
  'show_lead_ms', c.show_lead_ms, 'answer_grace_ms', c.answer_grace_ms,
  'grace_ms', c.grace_ms, 'void_window_ms', c.void_window_ms,
  'seq', 0, 'players', encode(c.players), 'humans', encode(c.humans), 'bot', c.bot,
  'cards', encode(c.cards), 'meta', encode(c.meta), 'bot_acc', c.bot_acc,
  'created_ms', now, 'started_ms', 0, 'finished_ms', 0, 'ends_at', ready_by,
  'settled', 0, 'reason', '')
for k, v in pairs(c.extra or {}) do redis.call('HSET', base, k, v) end
for _, uid in ipairs(c.players) do
  redis.call('HSET', base .. ':p', uid, cjson.encode({
    ready = uid == c.bot, connected = true, left = false, grace_until = 0, lat_ms = 100,
    score = 0, correct = 0, correct_ms = 0, emote_at = 0, emotes = 0,
  }))
end
for i, q in ipairs(questions) do
  local key = base .. ':q:' .. i
  redis.call('HSET', key, 'stem', q.stem, 'options', encode(q.options), 'correct', q.correct,
    'ref', q.ref, 'limit_ms', q.limit_ms, 'chapter', q.chapter)
  redis.call('EXPIRE', key, ttl)
end
redis.call('EXPIRE', base, ttl)
redis.call('EXPIRE', base .. ':p', ttl)
for _, uid in ipairs(c.humans) do
  redis.call('SET', 'busy:' .. uid, 'm:' .. c.id, 'EX', ttl)
end
local m = load_match(base)
schedule(m, ready_by)
return {'ok', 1, m.due}
