-- leases: renews (ARGV[2] > 0) or releases (ARGV[2] = 0) leases held by ARGV[1].
-- KEYS: lease keys. ARGV: holder, TTL ms. Returns the 1-based indexes of keys not held.
local lost = {}
for i, key in ipairs(KEYS) do
  if redis.call('GET', key) == ARGV[1] then
    if tonumber(ARGV[2]) > 0 then
      redis.call('PEXPIRE', key, ARGV[2])
    else
      redis.call('DEL', key)
    end
  else
    table.insert(lost, i)
  end
end
return lost
