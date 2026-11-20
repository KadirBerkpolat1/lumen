-- Unit tests for lua/filepicker.lua (native zenity/kdialog folder & fix picker).
package.path = "lua/?.lua;" .. package.path
local filepicker = require("filepicker")

local pass, fail = 0, 0
local function ok(cond, msg)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    io.stderr:write("FAIL: " .. msg .. "\n")
  end
end

-- 1. Prefers zenity and validates directory under HOME
do
  local seen_cmd
  local res = filepicker.pick_directory("~/CloudSaves", {
    home = "/home/berk",
    find_tool = function(name) return name == "zenity" and "/usr/bin/zenity" or nil end,
    file_mode = function(p)
      if p == "/home/berk/CloudSaves" or p == "/home/berk/CloudSaves/Steam" then return "directory" end
      return nil
    end,
    realpath = function(p) return p end,
    run_cmd = function(cmd)
      seen_cmd = cmd
      return "/home/berk/CloudSaves/Steam\n", 0
    end,
  })
  ok(res.success == true and res.cancelled == false, "zenity dir pick succeeds")
  ok(res.path == "/home/berk/CloudSaves/Steam", "returns picked folder path")
  ok(res.isDir == true and res.tool == "zenity", "reports isDir and zenity")
  ok(seen_cmd and seen_cmd:find("--directory", 1, true) ~= nil, "passes --directory to zenity")
  ok(seen_cmd and seen_cmd:find("/home/berk/CloudSaves/", 1, true) ~= nil, "expands ~ initial path")
end

-- 2. Falls back to kdialog for archive picking
do
  local seen_cmd
  local res = filepicker.pick_fix_source("/home/berk/Downloads", {
    home = "/home/berk",
    find_tool = function(name) return name == "kdialog" and "/usr/bin/kdialog" or nil end,
    file_mode = function(p)
      if p == "/home/berk/Downloads" then return "directory" end
      if p == "/home/berk/Downloads/game-fix.zip" then return "file" end
      return nil
    end,
    realpath = function(p) return p end,
    run_cmd = function(cmd)
      seen_cmd = cmd
      return "/home/berk/Downloads/game-fix.zip\n", 0
    end,
  })
  ok(res.success == true and res.cancelled == false, "kdialog archive pick succeeds")
  ok(res.path == "/home/berk/Downloads/game-fix.zip", "returns picked archive path")
  ok(res.name == "game-fix.zip" and res.isDir == false and res.tool == "kdialog", "archive metadata ok")
  ok(seen_cmd and seen_cmd:find("--getopenfilename", 1, true) ~= nil, "uses kdialog --getopenfilename")
end

-- 3. Cancelled dialog returns cancelled=true
do
  local res = filepicker.pick_directory("", {
    home = "/home/berk",
    find_tool = function(name) return name == "zenity" and "/usr/bin/zenity" or nil end,
    file_mode = function() return "directory" end,
    run_cmd = function() return "", 1 end,
  })
  ok(res.success == true and res.cancelled == true, "empty output treated as cancel")
end

-- 4. Rejects path outside $HOME
do
  local res = filepicker.pick_directory("", {
    home = "/home/berk",
    find_tool = function(name) return name == "zenity" and "/usr/bin/zenity" or nil end,
    file_mode = function() return "directory" end,
    realpath = function(p) return p end,
    run_cmd = function() return "/etc/systemd\n", 0 end,
  })
  ok(res.success == false and res.errorCode == "outside_home", "path outside HOME rejected")
end

-- 5. Missing zenity and kdialog returns no_dialog_tool
do
  local res = filepicker.pick_directory("", {
    home = "/home/berk",
    find_tool = function() return nil end,
  })
  ok(res.success == false and res.errorCode == "no_dialog_tool", "missing dialog tool reported cleanly")
end

-- 6. RPC registration wires both RPCs
do
  local reg = {}
  filepicker.register(reg)
  ok(type(reg.LumenPickDirectory) == "function", "LumenPickDirectory registered")
  ok(type(reg.LumenPickFixSource) == "function", "LumenPickFixSource registered")
end

io.write(string.format("test_filepicker: %d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
