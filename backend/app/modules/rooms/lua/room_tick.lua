-- room_tick: the room's timer (rooms:timers), run by any rt node once due. In order:
--   * a game that ended puts the room between games: a friend duel offers a rematch for
--     rematch_ms (at most rematch_max per room), a group keeps "Play again" for again_ms;
--   * a friend duel whose players are both ready starts (returns "autostart");
--   * a rematch window that lapsed sends a friend duel back to its lobby, and closes a group
--     room ("idle");
--   * a lobby without activity for idle_ms closes ("idle");
--   * a group host disconnected for handover_ms hands over to the earliest-joined connected
--     player; a friend host away for host_left_ms with their friend waiting closes the lobby
--     ("host_left").
-- KEYS[1] room hash. Returns {action, detail}: finished (match id), autostart, lobby,
-- closed (reason), host (the new host), none or gone.
local base = KEYS[1]
local r = load_room(base)
if not r then
  redis.call('ZREM', ROOM_TIMERS, string.match(base, '{(.*)}'))
  return {'gone', ''}
end
if r.status == 'closed' then
  redis.call('ZREM', ROOM_TIMERS, r.id)
  return {'none', ''}
end
local now = now_ms()

if r.status == 'playing' then
  local phase = redis.call('HGET', 'm:{' .. r.h.match .. '}', 'phase')
  if not phase or terminal(phase) then
    set_status(r, 'finished')
    for _, uid in ipairs(r.order) do
      local mem = r.members[uid]
      mem.ready = false
      mem.spectator = false
      save_member(r, uid)
    end
    if r.kind == 'group' then
      set_field(r, 'rematch', cjson.encode({offered_by = cjson.null, ['until'] = now + num(r.h.again_ms)}))
    elseif num(r.h.games) <= num(r.h.rematch_max) then
      set_field(r, 'rematch', cjson.encode({
        offered_by = cjson.null, ['until'] = now + num(r.h.rematch_ms), accepted = {x = false},
      }))
    else
      set_status(r, 'lobby')
    end
    touch(r, now)
    emit_state(r, now)
    reschedule(r)
    return {'finished', r.h.match}
  end
end

local autostart = num(r.h.autostart_at)
if autostart > 0 and now >= autostart then
  set_field(r, 'autostart_at', 0)
  reschedule(r)
  return {'autostart', ''}
end

local rm = rematch_of(r)
if r.status == 'finished' and rm and now >= rm['until'] then
  if r.kind == 'group' then
    close_room(r, 'idle', now)
    return {'closed', 'idle'}
  end
  set_field(r, 'rematch', '')
  set_status(r, 'lobby')
  reset_ready(r)
  touch(r, now)
  emit_state(r, now)
  reschedule(r)
  return {'lobby', ''}
end

if (r.status == 'lobby' or (r.status == 'finished' and not rm))
    and now >= num(r.h.active_ms) + num(r.h.idle_ms) then
  close_room(r, 'idle', now)
  return {'closed', 'idle'}
end

local host = r.members[r.host]
if host and not host.connected and host.disc_ms > 0 then
  local successor = earliest(r, r.host)
  if successor and r.kind == 'group' and now >= host.disc_ms + num(r.h.handover_ms) then
    set_host(r, successor)
    emit_state(r, now)
    reschedule(r)
    return {'host', successor}
  end
  if successor and r.kind == 'friend' and r.status ~= 'playing'
      and now >= host.disc_ms + num(r.h.host_left_ms) then
    close_room(r, 'host_left', now)
    return {'closed', 'host_left'}
  end
end
reschedule(r)
return {'none', ''}
