-- Unit tests for lua/stackhealth.lua (MoonTools stack diagnostics RPC).
package.path = "lua/?.lua;" .. package.path
local json = require("json")
local stackhealth = require("stackhealth")

local pass, fail = 0, 0
local function ok(cond, msg)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    io.stderr:write("FAIL: " .. msg .. "\n")
  end
end

local function find_check(checks, id)
  for _, c in ipairs(checks or {}) do
    if c.id == id then return c end
  end
  return nil
end

-- 1. Healthy 64-bit Steam + SLSsteam + CloudRedirect + zenity + 2 tracked fixes
do
  local files = {
    ["/proc/420/comm"] = "steam\n",
    ["/proc/420/environ"] = "HOME=/home/berk\0XDG_CONFIG_HOME=/home/berk/.config/moon64\0",
    ["/proc/420/maps"] = "7f0000-7f1000 r-xp 0000 /home/berk/.local/share/moon64/SLSsteam.so.64\n7f2000-7f3000 r-xp 0000 /home/berk/.local/share/SLSsteam/CloudRedirect.so\n",
  }
  local existing = {
    ["/home/berk/.config/moon64/SLSsteam/config.yaml"] = true,
    ["/home/berk/.local/share/Lumen/fix_installs/480/manifest.json"] = true,
    ["/home/berk/.local/share/Lumen/fix_installs/526870/manifest.json"] = true,
  }
  local res = stackhealth.collect({
    home = "/home/berk",
    getenv = function(k) return k == "HOME" and "/home/berk" or nil end,
    list_pids = function() return { "420" } end,
    read_file = function(p) return files[p] end,
    read_link = function(p)
      if p == "/proc/420/exe" then return "/home/berk/.local/share/Steam/steamrt64/steam" end
      return nil
    end,
    exists = function(p) return existing[p] == true end,
    list_dir = function(p)
      if p == "/home/berk/.local/share/Lumen/fix_installs" then return { "480", "526870", "notes" } end
      return {}
    end,
    find_bin = function(name) return name == "zenity" and "/usr/bin/zenity" or nil end,
    has_cloudredirect = true,
  })
  ok(res.success == true and res.status == "ok", "healthy 64-bit stack reports ok")
  ok(res.arch == "x86_64" and res.steamPid == 420, "detects x86_64 steamrt64 pid")
  ok(res.slsRoot == "/home/berk/.config/moon64/SLSsteam", "aligns with Steam XDG_CONFIG_HOME")
  ok(res.trackedFixes == 2, "counts valid tracked fix manifests")
  ok(find_check(res.checks, "slssteam").status == "ok", "slssteam check ok")
  ok(find_check(res.checks, "profile").status == "ok", "profile alignment ok")
  ok(find_check(res.checks, "filepicker").status == "ok", "filepicker check ok")
end

-- 2. Missing config.yaml -> overall error; missing picker -> warn
do
  local res = stackhealth.collect({
    home = "/home/berk",
    getenv = function(k) return k == "HOME" and "/home/berk" or nil end,
    list_pids = function() return {} end,
    read_file = function() return nil end,
    read_link = function() return nil end,
    exists = function() return false end,
    list_dir = function() return {} end,
    find_bin = function() return nil end,
    has_cloudredirect = false,
  })
  ok(res.status == "error", "missing config.yaml yields overall error")
  ok(find_check(res.checks, "steam").status == "warn", "absent steam warns")
  ok(find_check(res.checks, "slssteam").status == "error", "missing config errors")
  ok(find_check(res.checks, "filepicker").status == "warn", "missing zenity/kdialog warns")
end

-- 3. RPC registration returns valid JSON
do
  local reg = {}
  stackhealth.register(reg, {
    home = "/home/berk",
    getenv = function(k) return k == "HOME" and "/home/berk" or nil end,
    list_pids = function() return {} end,
    read_file = function() return nil end,
    read_link = function() return nil end,
    exists = function() return false end,
    list_dir = function() return {} end,
    find_bin = function() return nil end,
    has_cloudredirect = false,
  })
  local raw = reg.LumenStackHealth()
  local parsed = json.decode(raw)
  ok(type(parsed) == "table" and parsed.success == true and type(parsed.checks) == "table",
    "LumenStackHealth returns decodable JSON")
end

io.write(string.format("test_stackhealth: %d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
