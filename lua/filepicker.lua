-- filepicker: native Linux folder and fix-archive picker for Lumen/MoonTools.
--
-- Uses `zenity` when available and falls back to `kdialog`. Results are
-- validated to stay under $HOME and exist with the expected file type so a
-- buggy or unexpected dialog return can never point outside the user's tree.

local json = require("json")
local lfs_ok, lfs = pcall(require, "lfs")

local M = {}

local function shq(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function trim(s)
  return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function file_mode(path)
  if lfs_ok and type(lfs) == "table" and type(lfs.attributes) == "function" then
    return lfs.attributes(path, "mode")
  end
  local f = io.open(path, "rb")
  if f then
    f:close()
    return "file"
  end
  return nil
end

local function realpath_safe(path, deps)
  if deps and type(deps.realpath) == "function" then
    return deps.realpath(path)
  end
  local p = io.popen("realpath -m -- " .. shq(path) .. " 2>/dev/null", "r")
  if not p then return path end
  local out = trim(p:read("*l") or "")
  p:close()
  return out ~= "" and out or path
end

function M.under_home(path, home)
  path = tostring(path or ""):gsub("/+$", "")
  home = tostring(home or ""):gsub("/+$", "")
  if path == "" or home == "" then return false end
  if path == home then return true end
  if path:sub(1, #home + 1) ~= home .. "/" then return false end
  for seg in path:sub(#home + 2):gmatch("[^/]+") do
    if seg == ".." then return false end
  end
  return true
end

local function default_find_tool(name)
  local candidates = { "/usr/bin/" .. name, "/usr/local/bin/" .. name }
  for _, c in ipairs(candidates) do
    local f = io.open(c, "rb")
    if f then f:close(); return c end
  end
  local p = io.popen("command -v -- " .. shq(name) .. " 2>/dev/null", "r")
  if not p then return nil end
  local out = trim(p:read("*l") or "")
  p:close()
  return out ~= "" and out or nil
end

local function default_run_cmd(cmd)
  local p = io.popen(cmd, "r")
  if not p then return nil, 1 end
  local out = p:read("*a") or ""
  local ok, _, code = p:close()
  return out, ok and 0 or (tonumber(code) or 1)
end

local function expand_initial(initial, home, mode_fn)
  initial = trim(initial)
  if initial == "" then return home end
  if initial == "~" then
    initial = home
  elseif initial:sub(1, 2) == "~/" then
    initial = home .. initial:sub(2)
  end
  if not M.under_home(initial, home) then return home end
  local m = mode_fn(initial)
  if m == "directory" then return initial end
  local parent = initial:match("^(.+)/[^/]+$")
  if parent and M.under_home(parent, home) and mode_fn(parent) == "directory" then
    return parent
  end
  return home
end

local function build_command(tool_kind, tool_path, mode, start_dir, title)
  if tool_kind == "zenity" then
    local start_arg = start_dir:gsub("/+$", "") .. "/"
    if mode == "directory" then
      return shq(tool_path)
        .. " --file-selection --directory"
        .. " --title=" .. shq(title)
        .. " --filename=" .. shq(start_arg)
        .. " 2>/dev/null"
    else
      return shq(tool_path)
        .. " --file-selection"
        .. " --title=" .. shq(title)
        .. " --filename=" .. shq(start_arg)
        .. " --file-filter=" .. shq("Fix archives (*.zip *.rar *.7z *.exe) | *.zip *.ZIP *.rar *.RAR *.7z *.7Z *.exe *.EXE")
        .. " --file-filter=" .. shq("All files | *")
        .. " 2>/dev/null"
    end
  else
    if mode == "directory" then
      return shq(tool_path)
        .. " --getexistingdirectory " .. shq(start_dir)
        .. " --title " .. shq(title)
        .. " 2>/dev/null"
    else
      return shq(tool_path)
        .. " --getopenfilename " .. shq(start_dir)
        .. " " .. shq("*.zip *.rar *.7z *.exe|Fix archives")
        .. " --title " .. shq(title)
        .. " 2>/dev/null"
    end
  end
end

local function pick(mode, initial_path, title, deps)
  deps = deps or {}
  local home = tostring(deps.home or os.getenv("HOME") or ""):gsub("/+$", "")
  if home == "" then
    return { success = false, errorCode = "no_home", error = "HOME is not set." }
  end
  local find_tool = deps.find_tool or default_find_tool
  local run_cmd = deps.run_cmd or default_run_cmd
  local mode_fn = deps.file_mode or file_mode

  local tool_kind, tool_path
  local z = find_tool("zenity")
  if z and z ~= "" then
    tool_kind, tool_path = "zenity", z
  else
    local k = find_tool("kdialog")
    if k and k ~= "" then
      tool_kind, tool_path = "kdialog", k
    end
  end
  if not tool_path then
    return {
      success = false,
      errorCode = "no_dialog_tool",
      error = "Neither zenity nor kdialog is installed.",
    }
  end

  local start_dir = expand_initial(initial_path, home, mode_fn)
  local cmd = build_command(tool_kind, tool_path, mode, start_dir, title)
  local raw, exit_code = run_cmd(cmd)
  local picked = trim((tostring(raw or ""):match("^([^\r\n]+)") or ""))
  if picked == "" or (exit_code ~= 0 and picked == "") then
    return { success = true, cancelled = true, tool = tool_kind }
  end

  local resolved = realpath_safe(picked, deps)
  if not M.under_home(resolved, home) then
    return {
      success = false,
      errorCode = "outside_home",
      error = "Selected path must be inside your home directory.",
    }
  end

  local picked_mode = mode_fn(resolved)
  if mode == "directory" and picked_mode ~= "directory" then
    return {
      success = false,
      errorCode = "not_directory",
      error = "Selected path is not an existing folder.",
    }
  end
  if mode == "archive" and picked_mode ~= "file" then
    return {
      success = false,
      errorCode = "not_file",
      error = "Selected path is not an existing file.",
    }
  end

  return {
    success = true,
    cancelled = false,
    tool = tool_kind,
    path = resolved,
    name = resolved:match("([^/]+)$") or resolved,
    isDir = picked_mode == "directory",
  }
end

function M.pick_directory(initial_path, deps)
  return pick("directory", initial_path, "Select Folder — MoonTools", deps)
end

function M.pick_fix_source(initial_path, deps)
  return pick("archive", initial_path, "Select Fix Archive — MoonTools", deps)
end

local function extract_initial(a, b)
  if type(a) == "table" then
    return tostring(a.initialPath or "")
  end
  if type(b) == "string" then
    return b
  end
  if type(a) == "string" and (a:sub(1, 1) == "/" or a:sub(1, 1) == "~") then
    return a
  end
  return ""
end

function M.register(registry)
  registry.LumenPickDirectory = function(a, b)
    return json.encode(M.pick_directory(extract_initial(a, b)))
  end
  registry.LumenPickFixSource = function(a, b)
    return json.encode(M.pick_fix_source(extract_initial(a, b)))
  end
end

return M
