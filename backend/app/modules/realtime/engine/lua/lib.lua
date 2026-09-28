-- Shared by every match script: each script is this file followed by its own body.
--
-- KEYS[1] is always the match hash "m:{<mid>}"; the other keys of the match share its hash
-- tag and are derived from it (":p", ":q:<i>", ":log", ":final"). Global keys (rt:timers,
-- settle:q, busy:<uid>) assume the single Redis primary described in realtime-engine.md.
--
-- Scripts never read the clock from their caller: every time comes from Redis TIME.

local TIMERS = 'rt:timers'
local SETTLE = 'settle:q'
-- cjson encodes an empty table as {}; lists that may be empty are encoded through this marker.
local EMPTY = '__empty_list__'

local function now_ms()
  local t = redis.call('TIME')
  return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end

local function encode(value)
  return (string.gsub(cjson.encode(value), '"' .. EMPTY .. '"', '[]'))
end

local function list(t)
  if #t == 0 then return EMPTY end
  return t
end

local function num(value)
  return tonumber(value) or 0
end

local function hgetall(key)
  local flat = redis.call('HGETALL', key)
  local map = {}
  for i = 1, #flat, 2 do map[flat[i]] = flat[i + 1] end
  return map
end

local function terminal(phase)
  return phase == 'finished' or phase == 'aborted' or phase == 'voided'
end

-- The match: its hash, and every player's JSON state from "<base>:p".
local function load_match(base)
  local h = hgetall(base)
  if h.phase == nil then return nil end
  local m = {
    base = base,
    id = h.id,
    h = h,
    kind = h.kind,
    phase = h.phase,
    ver = num(h.ver),
    q = num(h.q),
    total = num(h.total),
    revealed = num(h.revealed),
    pdue = num(h.pdue),
    due = num(h.due),
    players = cjson.decode(h.players),
    humans = cjson.decode(h.humans),
    bot = h.bot or '',
    p = {},
  }
  local states = hgetall(base .. ':p')
  for uid, raw in pairs(states) do m.p[uid] = cjson.decode(raw) end
  return m
end

local function save_player(m, uid)
  redis.call('HSET', m.base .. ':p', uid, cjson.encode(m.p[uid]))
end

local function bump(m)
  m.ver = m.ver + 1
  redis.call('HSET', m.base, 'ver', m.ver)
end

local function set_phase(m, phase)
  m.phase = phase
  redis.call('HSET', m.base, 'phase', phase)
end

local function qkey(m, i)
  return m.base .. ':q:' .. i
end

-- One shared event: next seq, appended to the capped log, published to every node.
local function emit(m, t, d, now)
  local seq = redis.call('HINCRBY', m.base, 'seq', 1)
  local env = encode({v = 1, t = t, ch = 'm:' .. m.id, seq = seq, ts = now, d = d})
  redis.call('XADD', m.base .. ':log', 'MAXLEN', '~', 300, '*', 'seq', seq, 'ev', env)
  if seq == 1 then
    -- The log is created by its first event: it expires with the match.
    local ttl = redis.call('TTL', m.base)
    if ttl > 0 then redis.call('EXPIRE', m.base .. ':log', ttl) end
  end
  redis.call('PUBLISH', 'ev:m:' .. m.id, env)
  return seq
end

-- The earliest grace deadline of a human who is away (0 if nobody is).
local function earliest_grace(m)
  local g = 0
  for _, uid in ipairs(m.humans) do
    local p = m.p[uid]
    if not p.connected and not p.left and p.grace_until > 0 then
      if g == 0 or p.grace_until < g then g = p.grace_until end
    end
  end
  return g
end

-- The phase's own deadline is pdue; the timer fires at the earlier of it and any grace
-- deadline. Every change of due is mirrored in rt:timers for the failover scanner.
local function schedule(m, pdue)
  m.pdue = pdue
  local due = pdue
  local g = earliest_grace(m)
  if g > 0 and (due == 0 or g < due) then due = g end
  local short = num(m.h.short_until)
  if short > 0 and (due == 0 or short < due) then due = short end
  m.due = due
  redis.call('HSET', m.base, 'pdue', pdue, 'due', due)
  if due > 0 then
    redis.call('ZADD', TIMERS, due, m.id)
  else
    redis.call('ZREM', TIMERS, m.id)
  end
end

-- Group battles never forfeit anyone: a missing player scores 0, and the game ends once fewer
-- than 2 players have been connected for short_ms.
local function is_group(m)
  return m.h.rules == 'group'
end

local function present(m)
  local n = 0
  for _, uid in ipairs(m.humans) do
    local p = m.p[uid]
    if p.connected and not p.left then n = n + 1 end
  end
  return n
end

-- Starts or clears the "fewer than 2 connected" deadline of a group battle.
local function track_short(m, now)
  if not is_group(m) then return end
  local short = num(m.h.short_until)
  if present(m) < 2 then
    if short == 0 then short = now + num(m.h.short_ms) end
  else
    short = 0
  end
  m.h.short_until = short
  redis.call('HSET', m.base, 'short_until', short)
end

local function start_countdown(m, now)
  local ends = now + num(m.h.countdown_ms)
  set_phase(m, 'countdown')
  redis.call('HSET', m.base, 'ends_at', ends, 'started_ms', now)
  emit(m, 'match.phase', {phase = 'countdown', q = 0, ends_at = ends}, now)
  -- Question 1 is sent show_lead_ms early, so it goes live as the countdown ends.
  schedule(m, math.max(now, ends - num(m.h.show_lead_ms)))
end

local function open_question(m, i, now)
  local key = qkey(m, i)
  local q = hgetall(key)
  local limit = num(q.limit_ms)
  local shown = now + num(m.h.show_lead_ms)
  local deadline = shown + limit
  -- Who is here as the question opens: early advance waits for them, speed compares them.
  local open = {}
  for _, uid in ipairs(m.players) do
    local p = m.p[uid]
    if uid == m.bot or (p.connected and not p.left) then table.insert(open, uid) end
  end
  local show = {
    q = i,
    total = m.total,
    stem = q.stem,
    options = cjson.decode(q.options),
    shown_at = shown,
    deadline_at = deadline,
    limit_ms = limit,
    chapter = q.chapter,
  }
  redis.call('HSET', key, 'shown_at', shown, 'deadline_at', deadline,
    'open', encode(list(open)), 'show', encode(show))
  m.q = i
  redis.call('HSET', m.base, 'q', i, 'ends_at', deadline)
  set_phase(m, 'q_open')
  emit(m, 'q.show', show, now)
  schedule(m, deadline + num(m.h.answer_grace_ms))
end

-- Latency-fair timing and points: scoring.effective_time_ms, judge_timing and
-- question_points. Returns effective time, status, whether it scores, points.
local function judge(raw, el, lat, limit, picked_correct)
  local e = math.max(0, math.min(raw, math.max(raw - lat, el)))
  local status = 'accepted'
  if raw < 0 then
    status = 'too_early'
  elseif e > limit or raw > limit + lat then
    status = 'late'
  end
  local ok = status == 'accepted' and picked_correct
  local pts = 0
  if ok then
    local span = limit - 1000
    local used = math.min(math.max(e - 1000, 0), span)
    pts = 100 + math.floor((100 * (span - used) + span) / (2 * span))
  end
  return e, status, ok, pts
end

local function answers_of(m, key)
  local answers = {}
  for _, uid in ipairs(m.players) do
    local raw = redis.call('HGET', key, 'a:' .. uid)
    if raw then answers[uid] = cjson.decode(raw) end
  end
  return answers
end

-- The median of sorted times; the mean of the middle two rounded half up.
local function median(times)
  table.sort(times)
  local n = #times
  local mid = math.floor(n / 2)
  if n % 2 == 1 then return times[mid + 1] end
  return math.floor((times[mid] + times[mid + 1] + 1) / 2)
end

-- Fast, slow or even against the other humans who were here when the question opened
-- (scoring.speed_vs_opponents). Bot games and players who weren't here get no label.
local function speed_label(m, uid, answers, open_set)
  if m.bot ~= '' or not open_set[uid] then return nil, nil end
  local peers, times = 0, {}
  for _, other in ipairs(m.humans) do
    if other ~= uid and open_set[other] then
      peers = peers + 1
      local a = answers[other]
      if a and a.status == 'accepted' then table.insert(times, a.e) end
    end
  end
  if peers == 0 then return nil, nil end
  local mine = answers[uid]
  local answered = mine ~= nil and mine.status == 'accepted'
  if #times == 0 then
    if answered then return 'fast', nil end
    return nil, nil
  end
  local peer = median(times)
  if not answered then return 'slow', peer end
  if mine.e < peer - 250 then return 'fast', peer end
  if mine.e > peer + 250 then return 'slow', peer end
  return 'even', peer
end

local function totals_of(m)
  local totals = {}
  for _, uid in ipairs(m.players) do
    local p = m.p[uid]
    totals[uid] = {points = p.score, correct = p.correct}
  end
  return totals
end

local places

-- The mini leaderboard of a group battle: place (1, 1, 3...) and the change since the last
-- question, positive when the player moved up.
local function standings_of(m)
  local tot, uids = {}, {}
  for _, uid in ipairs(m.players) do
    local p = m.p[uid]
    tot[uid] = {points = p.score, correct = p.correct, correct_ms = p.correct_ms}
    table.insert(uids, uid)
  end
  local before = cjson.decode(m.h.places or '{}')
  local now_places, out, placed = {}, {}, 0
  for _, group in ipairs(places(uids, tot)) do
    local place = placed + 1
    for _, uid in ipairs(group) do
      now_places[uid] = place
      local change = 0
      if before[uid] then change = before[uid] - place end
      table.insert(out, {uid = uid, points = tot[uid].points, place = place, change = change})
    end
    placed = placed + #group
  end
  redis.call('HSET', m.base, 'places', cjson.encode(now_places))
  return out
end

local function reveal(m, now)
  local i = m.q
  local key = qkey(m, i)
  local q = hgetall(key)
  local open_set = {}
  for _, uid in ipairs(cjson.decode(q.open or '[]')) do open_set[uid] = true end
  local answers = answers_of(m, key)
  local players, results = {}, {}
  for _, uid in ipairs(m.players) do
    local a = answers[uid]
    local speed, peer = speed_label(m, uid, answers, open_set)
    local entry = {opt = cjson.null, correct = false, pts = 0, time_ms = cjson.null,
      speed = speed or cjson.null}
    if a then entry.opt = a.opt end
    if a and a.status == 'accepted' then
      local p = m.p[uid]
      entry.correct = a.ok
      entry.pts = a.pts
      entry.time_ms = a.e
      p.score = p.score + a.pts
      if a.ok then
        p.correct = p.correct + 1
        p.correct_ms = p.correct_ms + a.e
      end
      save_player(m, uid)
    end
    players[uid] = entry
    results[uid] = {speed = speed or cjson.null, peer = peer or cjson.null}
  end
  local d = {q = i, correct = q.correct, players = players, totals = totals_of(m), ref = q.ref}
  if m.h.standings == '1' then d.standings = standings_of(m) end
  local reveal_ms = num(m.h.reveal_ms)
  m.revealed = i
  redis.call('HSET', key, 'res', cjson.encode(results))
  redis.call('HSET', m.base, 'last_reveal', encode(d), 'revealed', i, 'ends_at', now + reveal_ms)
  set_phase(m, 'q_reveal')
  emit(m, 'q.reveal', d, now)
  schedule(m, now + reveal_ms)
end

-- Stronger first: more points, then more correct answers, then less time on correct ones.
local function stronger(a, b)
  if a.points ~= b.points then return a.points > b.points end
  if a.correct ~= b.correct then return a.correct > b.correct end
  return a.correct_ms < b.correct_ms
end

local function level(a, b)
  return a.points == b.points and a.correct == b.correct and a.correct_ms == b.correct_ms
end

-- Places as tie groups (scoring.rank_group), uids sorted within a place.
places = function(uids, tot)
  table.sort(uids, function(x, y)
    if level(tot[x], tot[y]) then return x < y end
    return stronger(tot[x], tot[y])
  end)
  local out, current = {}, nil
  for _, uid in ipairs(uids) do
    if current and level(tot[current[1]], tot[uid]) then
      table.insert(current, uid)
    else
      current = {uid}
      table.insert(out, current)
    end
  end
  return out
end

-- Ends the match: finished (with a ranking), aborted or voided. Writes the immutable final
-- result, queues settlement, frees the players' busy slots and emits match.end. ``losers``
-- rank last whatever their points (a forfeit or an expired grace).
local function finish(m, status, reason, losers, extra, now)
  local tot = {}
  for _, uid in ipairs(m.players) do
    local p = m.p[uid]
    tot[uid] = {points = p.score, correct = p.correct, correct_ms = p.correct_ms}
  end
  local ranking = {}
  if status == 'finished' then
    local lost = {}
    for _, uid in ipairs(losers) do lost[uid] = true end
    local ahead, behind = {}, {}
    for _, uid in ipairs(m.players) do
      if lost[uid] then table.insert(behind, uid) else table.insert(ahead, uid) end
    end
    for _, group in ipairs(places(ahead, tot)) do table.insert(ranking, group) end
    for _, group in ipairs(places(behind, tot)) do table.insert(ranking, group) end
  end
  local end_payload = {reason = reason, totals = totals_of(m), ranking = list(ranking)}
  set_phase(m, status)
  redis.call('HSET', m.base, 'reason', reason, 'finished_ms', now, 'ends_at', 0,
    'end', encode(end_payload), 'pdue', 0, 'due', 0)
  redis.call('ZREM', TIMERS, m.id)

  local questions = {}
  for i = 1, m.revealed do
    local key = qkey(m, i)
    local q = hgetall(key)
    table.insert(questions, {
      q = i,
      shown_at = num(q.shown_at),
      limit_ms = num(q.limit_ms),
      correct = q.correct,
      open = cjson.decode(q.open or '[]'),
      answers = answers_of(m, key),
      results = cjson.decode(q.res or '{}'),
    })
  end
  local final = {
    match_id = m.id,
    kind = m.kind,
    status = status,
    reason = reason,
    losers = list(losers),
    players = m.players,
    humans = m.humans,
    bot = m.bot,
    totals = tot,
    ranking = list(ranking),
    revealed = m.revealed,
    created_ms = num(m.h.created_ms),
    started_ms = num(m.h.started_ms),
    finished_ms = now,
    questions = list(questions),
    room = m.h.room or '',
  }
  local joined = {}
  for _, uid in ipairs(m.humans) do
    local q = m.p[uid].joined_q or 0
    if q > 0 then joined[uid] = q end
  end
  if next(joined) ~= nil then final.joined = joined end
  for k, v in pairs(extra) do final[k] = v end
  local ttl = redis.call('TTL', m.base)
  if ttl < 3600 then ttl = 3600 end
  redis.call('SET', m.base .. ':final', encode(final), 'NX', 'EX', ttl)
  redis.call('ZADD', SETTLE, now, m.id)
  -- Players of a room game go back to its lobby (their busy slot is the room again); the
  -- room's own timer moves it on at once.
  local room = m.h.room or ''
  local room_base = 'room:{' .. room .. '}'
  local in_room = room ~= '' and redis.call('HGET', room_base, 'status') == 'playing'
  for _, uid in ipairs(m.humans) do
    if redis.call('GET', 'busy:' .. uid) == 'm:' .. m.id then
      if in_room and redis.call('HEXISTS', room_base .. ':m', uid) == 1 then
        redis.call('SET', 'busy:' .. uid, 'r:' .. room, 'EX', num(m.h.room_ttl))
      else
        redis.call('DEL', 'busy:' .. uid)
      end
    end
  end
  if room ~= '' then redis.call('ZADD', 'rooms:timers', now, room) end
  emit(m, 'match.end', end_payload, now)
end
