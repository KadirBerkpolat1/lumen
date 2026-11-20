-- slsprofile: locate the SLSsteam config directory the RUNNING Steam client
-- actually uses.
--
-- Lumen runs as its own process (sidecar or systemd user service) and may not
-- inherit a custom XDG_CONFIG_HOME exported by a 64-bit Steam wrapper. Writing
-- config.yaml, FakeAppIds, or manifests into ~/.config/SLSsteam while the
-- injected client reads $XDG_CONFIG_HOME/SLSsteam makes edits vanish silently.
--
-- Resolution order (first non-empty directory containing `SLSsteam`):
--   1. SLSSTEAM_CONFIG_HOME (explicit override, same semantics as XDG_CONFIG_HOME)
--   2. XDG_CONFIG_HOME of a running `steam` or `steamwebhelper` process whose
--      HOME matches ours (other users' processes are ignored)
--   3. our own XDG_CONFIG_HOME
--   4. $HOME/.config
--
-- Pure /proc readers are injectable via `opts` for deterministic host tests.

local M = {}

local STEAM_COMMS = { steam = true, steamwebhelper = true }

local function default_read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function default_comm(pid)
  local f = io.open("/proc/" .. tostring(pid) .. "/comm", "rb")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line
end

local function default_pids()
  local pids = {}
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs and type(lfs) == "table" and type(lfs.dir) == "function" then
    local ok, iter, state = pcall(lfs.dir, "/proc")
    if ok then
      for entry in iter, state do
        if entry:match("^%d+$") then pids[#pids + 1] = entry end
      end
      return pids
    end
  end
  local pipe = io.popen("ls -1 /proc 2>/dev/null")
  if not pipe then return pids end
  for entry in pipe:lines() do
    if entry:match("^%d+$") then pids[#pids + 1] = entry end
  end
  pipe:close()
  return pids
end

-- Parse a NUL-separated /proc/<pid>/environ blob.
function M.environ_value(blob, key)
  if type(blob) ~= "string" or type(key) ~= "string" or key == "" then return nil end
  local prefix = key .. "="
  local text = blob:gsub("%z", "\n")
  for item in text:gmatch("[^\n]+") do
    if item:sub(1, #prefix) == prefix then
      local val = item:sub(#prefix + 1)
      if val ~= "" then return val end
      return nil
    end
  end
  return nil
end

local function strip_trailing_slash(p)
  if type(p) ~= "string" then return nil end
  p = p:gsub("/+$", "")
  return p ~= "" and p or nil
end

-- config_home(opts) -> string|nil (the directory that CONTAINS `SLSsteam`).
function M.config_home(opts)
  opts = opts or {}
  local getenv = opts.getenv or os.getenv
  local home = strip_trailing_slash(opts.home or getenv("HOME") or "")

  local explicit = strip_trailing_slash(getenv("SLSSTEAM_CONFIG_HOME"))
  if explicit then return explicit end

  if home then
    local list_pids = opts.list_pids or default_pids
    local read_comm = opts.read_comm or default_comm
    local read_environ = opts.read_environ or function(pid)
      return default_read("/proc/" .. tostring(pid) .. "/environ")
    end
    local pids = list_pids()
    table.sort(pids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
    -- Prefer the main `steam` process over `steamwebhelper`.
    local helper_xdg = nil
    for _, pid in ipairs(pids) do
      local comm = read_comm(pid)
      if comm and STEAM_COMMS[comm] then
        local blob = read_environ(pid)
        local proc_home = strip_trailing_slash(M.environ_value(blob, "HOME"))
        if proc_home == home then
          local proc_xdg = strip_trailing_slash(M.environ_value(blob, "XDG_CONFIG_HOME"))
          if proc_xdg then
            if comm == "steam" then return proc_xdg end
            if not helper_xdg then helper_xdg = proc_xdg end
          end
        end
      end
    end
    if helper_xdg then return helper_xdg end
  end

  local own_xdg = strip_trailing_slash(getenv("XDG_CONFIG_HOME"))
  if own_xdg then return own_xdg end
  if home then return home .. "/.config" end
  return nil
end

-- root(opts) -> "<config_home>/SLSsteam" or nil.
function M.root(opts)
  local base = M.config_home(opts)
  if not base then return nil end
  return base .. "/SLSsteam"
end

return M
