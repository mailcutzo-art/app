-- Shared by every room script, after the engine's lib.lua: a room's lobby in Redis.
--
-- KEYS[1] is always the room hash "room:{<rid>}". Members live in "<base>:m" (uid -> JSON
-- {card, ready, connected, away, joined_ms, disc_ms, spectator}), kicked players in "<base>:k"
-- and the event log in "<base>:log". "room:code:<CODE>" maps a live code to its room, and
-- "rooms:timers" (room id -> due ms) wakes whichever rt node scans it first; every script that
-- changes a deadline rewrites it. Scripts are idempotent, so two nodes ticking the same room
-- is harmless.

local ROOM_TIMERS = 'rooms:timers'

local function load_room(base)
  local h = hgetall(base)
  if h.status == nil then return nil end
  local r = {base = base, id = h.id, h = h, kind = h.kind, status = h.status, host = h.host,
    members = {}, order = {}}
  for uid, raw in pairs(hgetall(base .. ':m')) do
    r.members[uid] = cjson.decode(raw)
    table.insert(r.order, uid)
  end
  table.sort(r.order, function(a, b)
    local ma, mb = r.members[a], r.members[b]
    if ma.joined_ms ~= mb.joined_ms then return ma.joined_ms < mb.joined_ms end
    return a < b
  end)
  return r
end

local function save_member(r, uid)
  redis.call('HSET', r.base .. ':m', uid, cjson.encode(r.members[uid]))
end

local function set_field(r, field, value)
  r.h[field] = value
  redis.call('HSET', r.base, field, value)
end

local function set_status(r, status)
  r.status = status
  set_field(r, 'status', status)
end

local function set_host(r, uid)
  r.host = uid
  set_field(r, 'host', uid)
end

local function rematch_of(r)
  if (r.h.rematch or '') == '' then return nil end
  return cjson.decode(r.h.rematch)
end

local function role_of(r, uid)
  if uid == r.host then return 'host' end
  if r.members[uid].spectator then return 'spectator' end
  return 'player'
end

-- The whole lobby as room.state carries it.
local function room_state(r)
  local members = {}
  for _, uid in ipairs(r.order) do
    local mem = r.members[uid]
    local card = {}
    for k, v in pairs(mem.card) do card[k] = v end
    card.ready = mem.ready
    card.connected = mem.connected
    card.away = mem.away
    card.role = role_of(r, uid)
    card.joined_at = mem.joined_ms
    table.insert(members, card)
  end
  local status = r.status
  if status == 'starting' then status = 'lobby' end
  local rematch = cjson.null
  local rm = rematch_of(r)
  if rm then rematch = {offered_by = rm.offered_by or cjson.null, ['until'] = rm['until']} end
  local match = cjson.null
  if (r.h.match or '') ~= '' then match = r.h.match end
  return {
    room_id = r.id,
    kind = r.kind,
    code = r.h.code,
    host = r.host,
    status = status,
    locked = r.h.locked == '1',
    settings = cjson.decode(r.h.settings),
    capacity = num(r.h.capacity),
    match_id = match,
    members = list(members),
    rematch = rematch,
  }
end

-- One shared event: next seq, appended to the capped log, published to every node.
local function room_emit(r, t, d, now)
  local seq = redis.call('HINCRBY', r.base, 'seq', 1)
  local env = encode({v = 1, t = t, ch = 'r:' .. r.id, seq = seq, ts = now, d = d})
  redis.call('XADD', r.base .. ':log', 'MAXLEN', '~', 300, '*', 'seq', seq, 'ev', env)
  redis.call('PUBLISH', 'ev:r:' .. r.id, env)
  return seq
end

local function emit_state(r, now)
  room_emit(r, 'room.state', room_state(r), now)
end

-- Keys (and members' busy slots) live as long as the room is used.
local function refresh(r)
  local ttl = num(r.h.ttl)
  for _, suffix in ipairs({'', ':m', ':k', ':log'}) do
    redis.call('EXPIRE', r.base .. suffix, ttl)
  end
  redis.call('EXPIRE', 'room:code:' .. r.h.code, ttl)
  for _, uid in ipairs(r.order) do
    if redis.call('GET', 'busy:' .. uid) == 'r:' .. r.id then
      redis.call('EXPIRE', 'busy:' .. uid, ttl)
    end
  end
end

-- Activity keeps an idle lobby open.
local function touch(r, now)
  set_field(r, 'active_ms', now)
  refresh(r)
end

-- The earliest-joined connected player other than ``except`` (never a spectator).
local function earliest(r, except)
  for _, uid in ipairs(r.order) do
    local mem = r.members[uid]
    if uid ~= except and mem.connected and not mem.spectator then return uid end
  end
  return nil
end

local function room_due(r)
  if r.status == 'closed' then return 0 end
  local due = 0
  local function consider(t)
    if t > 0 and (due == 0 or t < due) then due = t end
  end
  local rm = rematch_of(r)
  if r.status == 'lobby' then consider(num(r.h.active_ms) + num(r.h.idle_ms)) end
  if r.status == 'finished' then
    if rm then consider(rm['until']) else consider(num(r.h.active_ms) + num(r.h.idle_ms)) end
  end
  consider(num(r.h.autostart_at))
  local host = r.members[r.host]
  if host and not host.connected and host.disc_ms > 0 and earliest(r, r.host) then
    if r.kind == 'group' then
      consider(host.disc_ms + num(r.h.handover_ms))
    elseif r.status ~= 'playing' then
      consider(host.disc_ms + num(r.h.host_left_ms))
    end
  end
  return due
end

local function reschedule(r)
  local due = room_due(r)
  if due > 0 then
    redis.call('ZADD', ROOM_TIMERS, due, r.id)
  else
    redis.call('ZREM', ROOM_TIMERS, r.id)
  end
end

-- Closes the lobby: members' busy slots are freed (a game in progress runs on), the code
-- stops working and room.closed goes out. The keys expire soon after.
local function close_room(r, reason, now)
  set_status(r, 'closed')
  set_field(r, 'closed_reason', reason)
  for _, uid in ipairs(r.order) do
    if redis.call('GET', 'busy:' .. uid) == 'r:' .. r.id then redis.call('DEL', 'busy:' .. uid) end
  end
  if redis.call('GET', 'room:code:' .. r.h.code) == r.id then
    redis.call('DEL', 'room:code:' .. r.h.code)
  end
  room_emit(r, 'room.closed', {room_id = r.id, reason = reason}, now)
  redis.call('ZREM', ROOM_TIMERS, r.id)
  for _, suffix in ipairs({'', ':m', ':k', ':log'}) do
    redis.call('EXPIRE', r.base .. suffix, 600)
  end
end

local function reset_ready(r)
  for _, uid in ipairs(r.order) do
    local mem = r.members[uid]
    if mem.ready then
      mem.ready = false
      save_member(r, uid)
    end
  end
end
