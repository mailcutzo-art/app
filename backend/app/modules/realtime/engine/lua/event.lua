-- event: emits one shared event (e.g. rematch.status) with the next seq.
-- KEYS[1] match hash. ARGV: type, payload JSON. Returns the seq, or 0 if the match is gone.
local m = load_match(KEYS[1])
if not m then return 0 end
return emit(m, ARGV[1], cjson.decode(ARGV[2]), now_ms())
