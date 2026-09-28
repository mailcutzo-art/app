-- Test probe: runs the engine's shared Lua functions (lib.lua is prepended) on given inputs,
-- so tests can check they agree with app.modules.realtime.engine.scoring.
-- ARGV: operation, arguments JSON. Returns a JSON result.
local op = ARGV[1]
local args = cjson.decode(ARGV[2])
if op == 'judge' then
  local e, status, ok, pts = judge(args.raw, args.el, args.lat, args.limit, args.correct)
  return encode({e = e, status = status, ok = ok, pts = pts})
elseif op == 'speed' then
  local open_set = {}
  for _, uid in ipairs(args.open) do open_set[uid] = true end
  local m = {bot = args.bot, humans = args.humans}
  local speed, peer = speed_label(m, args.uid, args.answers, open_set)
  return encode({speed = speed or cjson.null, peer = peer or cjson.null})
elseif op == 'places' then
  return encode(list(places(args.uids, args.totals)))
end
return redis.error_reply('unknown probe ' .. op)
