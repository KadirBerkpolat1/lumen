-- Unit tests for lua/slsprofile.lua (active Steam XDG_CONFIG_HOME discovery).
package.path = "lua/?.lua;" .. package.path
local slsprofile = require("slsprofile")

local pass, fail = 0, 0
local function ok(cond, msg)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    io.stderr:write("FAIL: " .. msg .. "\n")
  end
end

-- environ_value parses NUL-separated blobs
do
  local blob = "HOME=/home/berk\0XDG_CONFIG_HOME=/home/berk/.config/custom-sls\0FOO=bar\0"
  ok(slsprofile.environ_value(blob, "HOME") == "/home/berk", "parses HOME")
  ok(slsprofile.environ_value(blob, "XDG_CONFIG_HOME") == "/home/berk/.config/custom-sls", "parses XDG_CONFIG_HOME")
  ok(slsprofile.environ_value(blob, "MISSING") == nil, "missing key returns nil")
  ok(slsprofile.environ_value("", "HOME") == nil, "empty blob returns nil")
end

-- 1. SLSSTEAM_CONFIG_HOME beats everything
do
  local env = {
    HOME = "/home/berk",
    SLSSTEAM_CONFIG_HOME = "/home/berk/.override/",
    XDG_CONFIG_HOME = "/home/berk/.own-xdg",
  }
  local root = slsprofile.root({
    getenv = function(k) return env[k] end,
    list_pids = function() return { "100" } end,
    read_comm = function() return "steam" end,
    read_environ = function() return "HOME=/home/berk\0XDG_CONFIG_HOME=/home/berk/.steam-xdg\0" end,
  })
  ok(root == "/home/berk/.override/SLSsteam", "SLSSTEAM_CONFIG_HOME wins over running steam")
end

-- 2. Running steam process XDG_CONFIG_HOME wins over own XDG_CONFIG_HOME and steamwebhelper
do
  local env = { HOME = "/home/berk", XDG_CONFIG_HOME = "/home/berk/.own-xdg" }
  local comms = { ["10"] = "steamwebhelper", ["20"] = "steam", ["30"] = "steam" }
  local envs = {
    ["10"] = "HOME=/home/berk\0XDG_CONFIG_HOME=/home/berk/.helper-xdg\0",
    ["20"] = "HOME=/home/other\0XDG_CONFIG_HOME=/home/other/.foreign-xdg\0",
    ["30"] = "HOME=/home/berk\0XDG_CONFIG_HOME=/home/berk/.steam-x64/\0",
  }
  local root = slsprofile.root({
    getenv = function(k) return env[k] end,
    list_pids = function() return { "30", "10", "20" } end,
    read_comm = function(p) return comms[p] end,
    read_environ = function(p) return envs[p] end,
  })
  ok(root == "/home/berk/.steam-x64/SLSsteam", "same-HOME steam wins over helper and foreign user")
end

-- 3. Helper fallback when main steam has no custom XDG_CONFIG_HOME
do
  local env = { HOME = "/home/berk" }
  local root = slsprofile.root({
    getenv = function(k) return env[k] end,
    list_pids = function() return { "10", "20" } end,
    read_comm = function(p) return p == "10" and "steam" or "steamwebhelper" end,
    read_environ = function(p)
      if p == "10" then return "HOME=/home/berk\0" end
      return "HOME=/home/berk\0XDG_CONFIG_HOME=/home/berk/.helper-profile\0"
    end,
  })
  ok(root == "/home/berk/.helper-profile/SLSsteam", "falls back to steamwebhelper XDG_CONFIG_HOME")
end

-- 4. Foreign user's steam is ignored; falls back to own XDG_CONFIG_HOME then $HOME/.config
do
  local env = { HOME = "/tmp/isolated-home", XDG_CONFIG_HOME = "/tmp/isolated-home/.xdg" }
  local root = slsprofile.root({
    getenv = function(k) return env[k] end,
    list_pids = function() return { "99" } end,
    read_comm = function() return "steam" end,
    read_environ = function() return "HOME=/home/berk\0XDG_CONFIG_HOME=/home/berk/.steam-x64\0" end,
  })
  ok(root == "/tmp/isolated-home/.xdg/SLSsteam", "ignores steam with different HOME, uses own XDG")

  local root2 = slsprofile.root({
    getenv = function(k) return k == "HOME" and "/tmp/isolated-home" or nil end,
    list_pids = function() return {} end,
  })
  ok(root2 == "/tmp/isolated-home/.config/SLSsteam", "falls back to $HOME/.config/SLSsteam")
end

io.write(string.format("test_slsprofile: %d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
