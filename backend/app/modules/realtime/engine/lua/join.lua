-- join: someone from the match's room comes into a running group battle. A late joiner plays
-- from the current question (0 for what they missed), a player who left comes back, and a
-- spectator only watches (the ":s" set lets them follow the channel).
-- KEYS[1] match hash. ARGV: uid, card JSON, "player" | "spectator", busy TTL (s).
-- Returns {status, ver, due}: joined, rejoined, spectating, already, busy or missing.
local m = load_match(KEYS[1])
if not m or terminal(m.phase) then return {'missing', 0, 0} end
local uid, as, ttl = ARGV[1], ARGV[3], tonumber(ARGV[4])
if as == 'spectator' then
  redis.call('SADD', m.base .. ':s', uid)
  redis.call('EXPIRE', m.base .. ':s', math.max(redis.call('TTL', m.base), 60))
  return {'spectating', m.ver, m.due}
end
local now = now_ms()
local busy = redis.call('GET', 'busy:' .. uid)
if busy and busy ~= 'r:' .. (m.h.room or '') and busy ~= 'm:' .. m.id then
  return {'busy', m.ver, m.due}
end
local p = m.p[uid]
local status = 'joined'
if p then
  if p.connected and not p.left then return {'already', m.ver, m.due} end
  p.left = false
  p.connected = true
  p.grace_until = 0
  status = 'rejoined'
  save_player(m, uid)
  bump(m)
  emit(m, 'opp.conn', {uid = uid, state = 'connected', grace_until = cjson.null}, now)
else
  local card = cjson.decode(ARGV[2])
  table.insert(m.players, uid)
  table.insert(m.humans, uid)
  local cards = cjson.decode(m.h.cards)
  cards[uid] = card
  redis.call('HSET', m.base, 'players', encode(m.players), 'humans', encode(m.humans),
    'cards', encode(cards))
  -- Questions before joined_q were missed (0 points); settlement skips them for this player.
  local joined_q = m.q
  if m.phase == 'q_reveal' then joined_q = m.q + 1 end
  m.p[uid] = {
    ready = true, connected = true, left = false, grace_until = 0, lat_ms = 100,
    score = 0, correct = 0, correct_ms = 0, emote_at = 0, emotes = 0, joined_q = joined_q,
  }
  save_player(m, uid)
  bump(m)
  emit(m, 'player.joined', {player = card, joined_q = joined_q}, now)
end
redis.call('SET', 'busy:' .. uid, 'm:' .. m.id, 'EX', ttl)
track_short(m, now)
schedule(m, m.pdue)
return {status, m.ver, m.due}
