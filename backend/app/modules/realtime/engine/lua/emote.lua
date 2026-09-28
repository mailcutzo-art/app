-- emote: at most one every ARGV[3] ms and ARGV[4] per match for each player.
-- KEYS[1] match hash. ARGV: uid, emote, min gap ms, max per match. Returns {status}.
local m = load_match(KEYS[1])
if not m then return {'missing'} end
local uid = ARGV[1]
local p = m.p[uid]
if not p or uid == m.bot then return {'not_player'} end
local now = now_ms()
if p.emotes >= num(ARGV[4]) or now - p.emote_at < num(ARGV[3]) then return {'rate_limited'} end
p.emotes = p.emotes + 1
p.emote_at = now
save_player(m, uid)
emit(m, 'emote', {uid = uid, e = ARGV[2]}, now)
return {'ok'}
