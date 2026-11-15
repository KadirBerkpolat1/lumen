-- eosfix.lua — the EOS (Epic Online Services) emulator fix kind for fixinstall.
--
-- An EOS fix replaces the game's EOSSDK-Win64-Shipping.dll with the
-- Nemirtingas EOS emulator and ships its config beside it:
--   <dll dir>/nepice_settings/NemirtingasEpicEmu.json
-- fixinstall extracts and records it like any fix archive; this module only
-- recognizes the kind and fixes the config's identity after extraction.
--
-- Why the config is rewritten: archives ship the uploader's config, and the
-- emulator keeps a valid "epicid"/"productuserid" it finds, so everyone who
-- installs the same archive would share one player id and their lobbies
-- collide. Dropping both ids makes the emulator generate them again: randomly
-- when "username" is "DefaultName", otherwise seeded by the username. So the
-- username becomes the player's Steam PersonaName (or "DefaultName" without
-- one). Known limit: two players with the SAME PersonaName get the same ids.
-- "appid" (the Epic lobby key every player must share) and every other key
-- are kept byte for byte: the edit works on the config text, never a
-- decode/encode round trip, which would reorder keys and re-escape values.
--
-- Detection evidence is the emulator config only. A genuine EOSSDK DLL or the
-- EpicOnlineServices installer ships with ordinary games and is never a fix.
--
-- Pure helpers, unit-tested in tools/test_eosfix.lua.

local eosfix = {}

local json = require("json")

eosfix.KIND = "eos_emu"
eosfix.SETTINGS_DIR = "nepice_settings"
eosfix.DEFAULT_USERNAME = "DefaultName"
-- Members dropped so the emulator generates them again for this player.
eosfix.ID_KEYS = { epicid = true, productuserid = true }

local STEAMID64_BASE = 76561197960265728

-- is_config_path(path) -> path (archive entry or file path, "/"-separated)
-- names an emulator config: .../nepice_settings/NemirtingasEpicEmu.json.
function eosfix.is_config_path(path)
  local low = "/" .. tostring(path or ""):lower()
  return low:match("/nepice_settings/nemirtingasepicemu%.json$") ~= nil
end

-- is_settings_dir(name) -> name is the emulator's settings folder.
function eosfix.is_settings_dir(name)
  return tostring(name or ""):lower() == eosfix.SETTINGS_DIR
end

-- is_sdk_dll(name) -> name is an EOSSDK runtime DLL (genuine or emulated).
function eosfix.is_sdk_dll(name)
  return tostring(name or ""):lower():match("^eossdk%-win%d%d%-shipping%.dll$") ~= nil
end

-- config_paths(entries) -> the entry paths that are emulator configs.
function eosfix.config_paths(entries)
  local out = {}
  for _, e in ipairs(type(entries) == "table" and entries or {}) do
    if type(e) == "table" and eosfix.is_config_path(e.path) then out[#out + 1] = e.path end
  end
  return out
end

-- classify(entries) -> "eos_emu" when the archive ships an emulator config,
-- else "generic". An EOSSDK DLL alone is not the emulator.
function eosfix.classify(entries)
  return #eosfix.config_paths(entries) > 0 and eosfix.KIND or "generic"
end

-- ── config text editing ────────────────────────────────────────────────────────────
-- The scanner only runs on text json.decode accepted, so it finds value ends,
-- it does not validate.

local function skip_ws(s, i)
  return s:find("[^ \t\r\n]", i) or (#s + 1)
end

-- Index just past the string opening at i, or nil.
local function scan_string(s, i)
  local j = i + 1
  while j <= #s do
    local c = s:sub(j, j)
    if c == "\\" then j = j + 2
    elseif c == '"' then return j + 1
    else j = j + 1 end
  end
  return nil
end

-- Index just past the value starting at i, or nil.
local function scan_value(s, i)
  local c = s:sub(i, i)
  if c == '"' then return scan_string(s, i) end
  if c == "{" or c == "[" then
    local depth, j = 0, i
    while j <= #s do
      local d = s:sub(j, j)
      if d == '"' then
        j = scan_string(s, j)
        if not j then return nil end
      else
        if d == "{" or d == "[" then
          depth = depth + 1
        elseif d == "}" or d == "]" then
          depth = depth - 1
          if depth == 0 then return j + 1 end
        end
        j = j + 1
      end
    end
    return nil
  end
  local e = s:find("[,}%]%s]", i)
  if not e or e == i then return nil end
  return e
end

-- top_members(s) -> { open, close, members = { { key, from, to } } } for the
-- top-level object: s:sub(from, to) is one member's text (key to value end),
-- open/close the indexes of its braces. nil when s is not one object.
local function top_members(s)
  local i = skip_ws(s, 1)
  if s:sub(i, i) ~= "{" then return nil end
  local res = { open = i, members = {} }
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == "}" then
    res.close = i
    return res
  end
  while true do
    if s:sub(i, i) ~= '"' then return nil end
    local key_end = scan_string(s, i)
    if not key_end then return nil end
    local ok, key = pcall(json.decode, s:sub(i, key_end - 1))
    if not ok or type(key) ~= "string" then return nil end
    local colon = skip_ws(s, key_end)
    if s:sub(colon, colon) ~= ":" then return nil end
    local v = skip_ws(s, colon + 1)
    local v_end = scan_value(s, v)
    if not v_end then return nil end
    res.members[#res.members + 1] = { key = key, from = i, to = v_end - 1, value_from = v }
    i = skip_ws(s, v_end)
    local c = s:sub(i, i)
    if c == "}" then
      res.close = i
      return res
    end
    if c ~= "," then return nil end
    i = skip_ws(s, i + 1)
  end
end

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not same(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- rewrite_config(text, username) -> new_text, { idsReset, username } or nil,
-- reason. Drops "epicid" and "productuserid" and sets "username" ("DefaultName"
-- when username is empty); every other member keeps its exact text. reason:
-- "malformed" (not a JSON object) or "rewrite_failed" (the result did not
-- check out). A caller given nil leaves the file untouched. PURE.
function eosfix.rewrite_config(text, username)
  if type(text) ~= "string" then return nil, "malformed" end
  local ok, before = pcall(json.decode, text)
  local top = ok and type(before) == "table" and top_members(text) or nil
  if not top then return nil, "malformed" end
  if type(username) ~= "string" or username == "" then username = eosfix.DEFAULT_USERNAME end
  local user_text = '"username": ' .. json.encode(username)

  local kept, ids_reset, user_set = {}, false, false
  for _, m in ipairs(top.members) do
    if eosfix.ID_KEYS[m.key] then
      ids_reset = true
    elseif m.key == "username" then
      if not user_set then
        kept[#kept + 1] = text:sub(m.from, m.value_from - 1) .. json.encode(username)
        user_set = true
      end
    else
      kept[#kept + 1] = text:sub(m.from, m.to)
    end
  end
  if not user_set then kept[#kept + 1] = user_text end

  -- The original layout: what follows "{", what sits between members, what
  -- precedes "}".
  local ms = top.members
  local lead, sep, trail = "", ", ", ""
  if #ms > 0 then
    lead = text:sub(top.open + 1, ms[1].from - 1)
    trail = text:sub(ms[#ms].to + 1, top.close - 1)
    sep = #ms > 1 and text:sub(ms[1].to + 1, ms[2].from - 1) or ("," .. lead)
  end
  local out = text:sub(1, top.open) .. lead .. table.concat(kept, sep) .. trail .. text:sub(top.close)

  local ok_after, after = pcall(json.decode, out)
  if not ok_after or type(after) ~= "table" or after.username ~= username
      or after.epicid ~= nil or after.productuserid ~= nil then
    return nil, "rewrite_failed"
  end
  for k, v in pairs(before) do
    if k ~= "username" and not eosfix.ID_KEYS[k] and not same(v, after[k]) then
      return nil, "rewrite_failed"
    end
  end
  for k in pairs(after) do
    if k ~= "username" and before[k] == nil then return nil, "rewrite_failed" end
  end
  return out, { idsReset = ids_reset, username = username }
end

-- ── the player's Steam name ──────────────────────────────────────────────────────────

-- most_recent_persona(vdf_text) -> the PersonaName of the account
-- loginusers.vdf marks MostRecent, or nil. Names come from cloudsettings'
-- parser (core), so this works without the plugin backend.
function eosfix.most_recent_persona(text)
  if type(text) ~= "string" then return nil end
  local names = require("cloudsettings").parse_loginusers(text)
  for sid, block in text:gmatch('"(%d+)"%s*(%b{})') do
    if block:match('"[Mm]ost[Rr]ecent"%s*"1"') then
      local id64 = math.tointeger(tonumber(sid))
      local name = id64 and names[id64 - STEAMID64_BASE]
      if type(name) == "string" and name ~= "" then return name end
    end
  end
  return nil
end

-- persona_name(deps) -> the logged-in player's Steam name, or nil. deps.home /
-- deps.read_file are injectable for tests.
function eosfix.persona_name(deps)
  deps = deps or {}
  local home = deps.home or os.getenv("HOME") or ""
  if home == "" then return nil end
  local read_file = deps.read_file or function(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
  end
  for _, root in ipairs({ home .. "/.steam/steam", home .. "/.steam/debian-installation",
                          home .. "/.local/share/Steam" }) do
    local text = read_file(root .. "/config/loginusers.vdf")
    if text then return eosfix.most_recent_persona(text) end
  end
  return nil
end

return eosfix
