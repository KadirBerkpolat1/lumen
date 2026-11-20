-- stackhealth: MoonTools runtime stack diagnostics for Lumen's Health tab.
--
-- Probes the live Steam client, SLSsteam injection/profile alignment,
-- CloudRedirect status, native dialog tools, and tracked fix installs.
-- All OS / /proc / filesystem probes are injectable via `deps` so unit tests
-- stay pure and deterministic.

local json = require("json")

local M = {}

local function default_read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function default_exists(path)
  if not path or path == "" then return false end
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function default_read_link(path)
  local p = io.popen("readlink -f -- '" .. tostring(path):gsub("'", "'\\''") .. "' 2>/dev/null", "r")
  if not p then return nil end
  local out = (p:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  p:close()
  return out ~= "" and out or nil
end

local function default_list_dir(path)
  local out = {}
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs and type(lfs) == "table" and type(lfs.dir) == "function" then
    local ok, iter, state = pcall(lfs.dir, path)
    if ok then
      for entry in iter, state do
        if entry ~= "." and entry ~= ".." then out[#out + 1] = entry end
      end
      return out
    end
  end
  local p = io.popen("ls -1 -- '" .. tostring(path):gsub("'", "'\\''") .. "' 2>/dev/null", "r")
  if not p then return out end
  for line in p:lines() do
    if line ~= "" then out[#out + 1] = line end
  end
  p:close()
  return out
end

local function default_list_pids()
  local pids = {}
  for _, entry in ipairs(default_list_dir("/proc")) do
    if entry:match("^%d+$") then pids[#pids + 1] = entry end
  end
  return pids
end

local function default_find_bin(name)
  for _, p in ipairs({ "/usr/bin/" .. name, "/usr/local/bin/" .. name }) do
    if default_exists(p) then return p end
  end
  local pipe = io.popen("command -v -- '" .. tostring(name):gsub("'", "'\\''") .. "' 2>/dev/null", "r")
  if not pipe then return nil end
  local out = (pipe:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  pipe:close()
  return out ~= "" and out or nil
end

local function detect_arch(exe)
  if type(exe) ~= "string" or exe == "" then return "unknown" end
  if exe:find("/steamrt64/", 1, true) or exe:find("/ubuntu12_64/", 1, true) or exe:find("/linux64/", 1, true) then
    return "x86_64"
  end
  if exe:find("/ubuntu12_32/", 1, true) or exe:find("/steamrt32/", 1, true) or exe:find("/linux32/", 1, true) then
    return "x86"
  end
  return "unknown"
end

local function find_steam_process(deps, home)
  local list_pids = deps.list_pids or default_list_pids
  local read_file = deps.read_file or default_read_file
  local read_link = deps.read_link or default_read_link
  local pids = list_pids()
  table.sort(pids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)

  local ok_sp, slsprofile = pcall(require, "slsprofile")
  local env_val = (ok_sp and slsprofile and slsprofile.environ_value) or function() return nil end

  local helper = nil
  for _, pid in ipairs(pids) do
    local comm = (read_file("/proc/" .. pid .. "/comm") or ""):gsub("[\r\n]+$", "")
    if comm == "steam" or comm == "steamwebhelper" then
      local environ = read_file("/proc/" .. pid .. "/environ") or ""
      local proc_home = env_val(environ, "HOME")
      if not proc_home or proc_home:gsub("/+$", "") == home then
        local exe = read_link("/proc/" .. pid .. "/exe") or ""
        local maps = read_file("/proc/" .. pid .. "/maps") or ""
        local info = {
          pid = tonumber(pid),
          comm = comm,
          exe = exe,
          arch = detect_arch(exe),
          xdg_config_home = env_val(environ, "XDG_CONFIG_HOME"),
          sls_loaded = maps:find("SLSsteam", 1, true) ~= nil,
          cloud_loaded = maps:find("CloudRedirect", 1, true) ~= nil,
        }
        if comm == "steam" then return info end
        if not helper then helper = info end
      end
    end
  end
  return helper
end

function M.collect(deps)
  deps = deps or {}
  local getenv = deps.getenv or os.getenv
  local home = tostring(deps.home or getenv("HOME") or ""):gsub("/+$", "")
  local exists = deps.exists or default_exists
  local list_dir = deps.list_dir or default_list_dir
  local find_bin = deps.find_bin or default_find_bin

  local steam = find_steam_process(deps, home)

  local sls_root = deps.sls_root
  if not sls_root then
    local ok_sp, slsprofile = pcall(require, "slsprofile")
    if ok_sp and type(slsprofile) == "table" and type(slsprofile.root) == "function" then
      sls_root = slsprofile.root({
        home = home,
        getenv = getenv,
        list_pids = deps.list_pids,
        read_comm = deps.read_file and function(pid)
          local c = deps.read_file("/proc/" .. tostring(pid) .. "/comm")
          return c and c:gsub("[\r\n]+$", "") or nil
        end or nil,
        read_environ = deps.read_file and function(pid)
          return deps.read_file("/proc/" .. tostring(pid) .. "/environ")
        end or nil,
      })
    elseif home ~= "" then
      sls_root = home .. "/.config/SLSsteam"
    end
  end
  local config_path = sls_root and (sls_root .. "/config.yaml") or ""
  local config_exists = config_path ~= "" and exists(config_path)

  local cloud_present = deps.has_cloudredirect
  if cloud_present == nil then
    local ok_sc, slsconfig = pcall(require, "slsconfig")
    if ok_sc and type(slsconfig) == "table" and type(slsconfig.has_cloudredirect) == "function" then
      cloud_present = slsconfig.has_cloudredirect() == true
    else
      cloud_present = false
    end
  end

  local dialog_tool = find_bin("zenity") and "zenity" or (find_bin("kdialog") and "kdialog" or nil)
  local fix_store = deps.fix_store or (home ~= "" and (home .. "/.local/share/Lumen/fix_installs") or "")
  local tracked_fixes = 0
  if fix_store ~= "" then
    for _, name in ipairs(list_dir(fix_store)) do
      if name:match("^%d+$") and exists(fix_store .. "/" .. name .. "/manifest.json") then
        tracked_fixes = tracked_fixes + 1
      end
    end
  end

  local checks = {}
  local function add(id, status, detail, path)
    checks[#checks + 1] = {
      id = id,
      status = status,
      detail = detail,
      path = path or "",
    }
  end

  if steam then
    add("steam", "ok",
      string.format("PID %d (%s, %s)", steam.pid, steam.comm, steam.arch),
      steam.exe)
  else
    add("steam", "warn", "Steam process not detected in /proc", "")
  end

  if steam and steam.sls_loaded then
    add("slssteam", "ok", "SLSsteam loaded in running Steam (" .. steam.arch .. ")", sls_root or "")
  elseif config_exists then
    add("slssteam", "warn", "config.yaml present, SLSsteam not mapped in Steam", config_path)
  else
    add("slssteam", "error", "SLSsteam config.yaml not found", config_path)
  end

  local profile_aligned = true
  if steam and steam.xdg_config_home and sls_root then
    local expected = steam.xdg_config_home:gsub("/+$", "") .. "/SLSsteam"
    profile_aligned = (expected == sls_root)
  end
  add("profile", profile_aligned and "ok" or "warn",
    profile_aligned and ("Active profile: " .. (sls_root or "unknown"))
      or ("Profile mismatch: Steam uses " .. tostring(steam and steam.xdg_config_home)),
    config_path)

  if cloud_present then
    add("cloudredirect", (steam and steam.cloud_loaded) and "ok" or "ok",
      (steam and steam.cloud_loaded) and "CloudRedirect installed and mapped" or "CloudRedirect installed",
      sls_root or "")
  else
    add("cloudredirect", "warn", "CloudRedirect not installed", "")
  end

  if dialog_tool then
    add("filepicker", "ok", "Native picker ready (" .. dialog_tool .. ")", "")
  else
    add("filepicker", "warn", "Neither zenity nor kdialog found", "")
  end

  add("fixes", "ok", tostring(tracked_fixes) .. " tracked fix install(s)", fix_store)

  local overall = "ok"
  for _, c in ipairs(checks) do
    if c.status == "error" then
      overall = "error"
      break
    elseif c.status == "warn" and overall == "ok" then
      overall = "warn"
    end
  end

  return {
    success = true,
    status = overall,
    arch = steam and steam.arch or "unknown",
    steamPid = steam and steam.pid or nil,
    slsRoot = sls_root or "",
    configPath = config_path,
    cloudPresent = cloud_present == true,
    dialogTool = dialog_tool or "",
    trackedFixes = tracked_fixes,
    noPlugin = deps.no_plugin == true,
    checks = checks,
  }
end

function M.register(registry, deps)
  registry.LumenStackHealth = function()
    local ok, res = pcall(M.collect, deps)
    if not ok then
      return json.encode({ success = false, error = tostring(res) })
    end
    return json.encode(res)
  end
end

return M
