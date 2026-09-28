-- room_read: the room.state payload and the channel's current seq, read atomically (the
-- snapshot a resume or a join gets), plus the fields REST previews need.
-- KEYS[1] room hash. Returns JSON {seq, state, status, match, active_ms, idle_ms}, or nil.
local r = load_room(KEYS[1])
if not r then return nil end
return encode({
  seq = num(r.h.seq),
  state = room_state(r),
  status = r.status,
  match = r.h.match or '',
  active_ms = num(r.h.active_ms),
  idle_ms = num(r.h.idle_ms),
})
