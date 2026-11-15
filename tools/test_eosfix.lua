-- Host tests for eosfix.lua: EOS emulator fix classification, the byte-exact
-- config identity rewrite, and the Steam PersonaName lookup.
-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_eosfix.lua
package.path = "lua/?.lua;" .. package.path

local eos = require("eosfix")
local json = require("json")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.write("FAIL: " .. name .. "\n") end
end

local function entries(paths)
  local out = {}
  for _, p in ipairs(paths) do out[#out + 1] = { path = p, size = 1 } end
  return out
end

-- ── classify ─────────────────────────────────────────────────────────────────────────
-- An Unreal game's emulator fix: the DLL and its settings folder beside it.
local UE_FIX = entries({
  "FactoryGame/Binaries/Win64/EOSSDK-Win64-Shipping.dll",
  "FactoryGame/Binaries/Win64/nepice_settings/NemirtingasEpicEmu.json",
})
check("classify: emulator DLL + its config -> eos_emu", eos.classify(UE_FIX) == "eos_emu")
check("classify: the config is found at the archive root too, case-insensitively",
  eos.classify(entries({ "Nepice_Settings/NemirtingasEpicEmu.JSON" })) == "eos_emu")
check("classify: a genuine EOSSDK DLL alone is not a fix",
  eos.classify(entries({ "Game/Binaries/Win64/EOSSDK-Win64-Shipping.dll" })) == "generic")
check("classify: the EpicOnlineServices installer is not a fix",
  eos.classify(entries({ "EpicOnlineServices/EpicOnlineServicesInstaller.exe",
    "EOSSDK-Win32-Shipping.dll" })) == "generic")
check("classify: an emulator config outside nepice_settings is not the emulator's",
  eos.classify(entries({ "NemirtingasEpicEmu.json", "nepice_settings.json" })) == "generic")
check("classify: an OnlineFix archive stays generic",
  eos.classify(entries({ "OnlineFix64.dll", "OnlineFix.ini", "winmm.dll" })) == "generic")
check("classify: malformed input -> generic", eos.classify(nil) == "generic"
  and eos.classify({ "x", 1 }) == "generic")
check("config_paths: every emulator config of the archive",
  #eos.config_paths(entries({ "a/nepice_settings/NemirtingasEpicEmu.json",
    "b/nepice_settings/NemirtingasEpicEmu.json", "b/EOSSDK-Win32-Shipping.dll" })) == 2)
check("is_sdk_dll: Win64 and Win32 runtimes, nothing else",
  eos.is_sdk_dll("EOSSDK-Win64-Shipping.dll") and eos.is_sdk_dll("eossdk-win32-shipping.DLL")
    and not eos.is_sdk_dll("EOSSDK-Win64-Shipping.dll.bak") and not eos.is_sdk_dll("EOSSDK.dll"))
check("is_settings_dir", eos.is_settings_dir("NEPICE_SETTINGS") and not eos.is_settings_dir("settings"))

-- ── rewrite_config ────────────────────────────────────────────────────────────────────
-- The shape fix archives ship: the uploader's identity baked in.
local SHIPPED = [[
{
    "appid": "0123456789abcdef0123456789abcdef",
    "custom_broadcast": "192.168.200.255",
    "disable_online_networking": false,
    "enable_overlay": true,
    "epicid": "156abc156f1c5487f91c",
    "gamename": "Satisfactory \"EA\" {build}",
    "language": "en",
    "log_level": "OFF",
    "productuserid": "0x8d7e6f5a4b3c2d1e",
    "savepath": "saves/emu",
    "stats": { "ids": [1, 2, 3], "note": "a}b]c" },
    "empty": [],
    "big": 12345678901234567890,
    "unlock_dlcs": true,
    "username": "FreeTP.Org"
}
]]
local out, info = eos.rewrite_config(SHIPPED, "Berk")
local dec = out and json.decode(out)
check("rewrite: valid JSON with the player's name and no shipped ids",
  dec ~= nil and dec.username == "Berk" and dec.epicid == nil and dec.productuserid == nil
    and info.idsReset == true and info.username == "Berk")
check("rewrite: appid (the Epic lobby key) is untouched",
  dec ~= nil and dec.appid == "0123456789abcdef0123456789abcdef")
local verbatim = true
for line in SHIPPED:gmatch("[^\n]+") do
  local key = line:match('^%s*"(%w+)"')
  if key and key ~= "epicid" and key ~= "productuserid" and key ~= "username" then
    local body = line:gsub(",%s*$", "")
    if not out:find(body, 1, true) then verbatim = false; io.write("  lost: " .. body .. "\n") end
  end
end
check("rewrite: every other member keeps its exact text (slashes, big numbers, [], nested braces)",
  verbatim and out:find('"savepath": "saves/emu"', 1, true) ~= nil
    and out:find('"empty": []', 1, true) ~= nil and out:find("12345678901234567890", 1, true) ~= nil)
check("rewrite: the layout stays (one member per line, same indent, trailing newline)",
  out:find('\n    "unlock_dlcs": true,\n    "username": "Berk"\n}\n$') ~= nil
    and out:find('"enable_overlay": true,\n    "gamename"', 1, true) ~= nil)
local again, info2 = eos.rewrite_config(out, "Berk")
check("rewrite: idempotent — a second pass changes nothing and resets no ids",
  again == out and info2.idsReset == false)

local no_name = eos.rewrite_config('{"appid":"x","epicid":"ab"}', nil)
check("rewrite: no Steam name -> DefaultName (the emulator then picks random ids)",
  no_name == '{"appid":"x","username": "DefaultName"}')
check("rewrite: a missing username member is added",
  json.decode(eos.rewrite_config('{"appid": "x"}', "P")).username == "P")
check("rewrite: an empty object gets just the username",
  eos.rewrite_config("{}", "P") == '{"username": "P"}')
check("rewrite: a config holding only ids keeps nothing else",
  eos.rewrite_config('{ "epicid": "aa", "productuserid": "bb" }', "P") == '{ "username": "P" }')
local dup = eos.rewrite_config('{"username":"a","appid":"x","username":"b"}', "P")
check("rewrite: a duplicated username collapses to one",
  dup == '{"username":"P","appid":"x"}')
local odd = 'Berk "K" ü\\/'
local odd_out = eos.rewrite_config('{"appid":"x"}', odd)
check("rewrite: a name with quotes, backslashes and UTF-8 is encoded, not injected",
  odd_out ~= nil and json.decode(odd_out).username == odd and json.decode(odd_out).appid == "x")

for name, bad in pairs({
  truncated = '{"appid": "x", "epicid": ',
  empty = "",
  array = '[{"appid": "x"}]',
  trailing = '{"appid": "x"} junk',
  string = '"appid"',
}) do
  local r, why = eos.rewrite_config(bad, "P")
  check("rewrite: " .. name .. " config is left alone (nil, malformed)", r == nil and why == "malformed")
end
check("rewrite: no text -> malformed", select(2, eos.rewrite_config(nil, "P")) == "malformed")

-- ── PersonaName (loginusers.vdf, parsed by cloudsettings) ──────────────────────────────────────
local VDF = [[
"users"
{
	"76561198000000001"
	{
		"AccountName"		"old_login"
		"PersonaName"		"Old Name"
		"MostRecent"		"0"
	}
	"76561198000000002"
	{
		"AccountName"		"berk_login"
		"PersonaName"		"Berk"
		"RememberPassword"		"1"
		"MostRecent"		"1"
	}
}
]]
check("persona: the MostRecent account's name, not the login", eos.most_recent_persona(VDF) == "Berk")
check("persona: no MostRecent account -> nil",
  eos.most_recent_persona((VDF:gsub('"MostRecent"\t\t"1"', '"MostRecent"\t\t"0"'))) == nil)
check("persona: no text -> nil", eos.most_recent_persona(nil) == nil)
local asked = {}
local name = eos.persona_name({ home = "/h", read_file = function(p)
  asked[#asked + 1] = p
  if p == "/h/.local/share/Steam/config/loginusers.vdf" then return VDF end
end })
check("persona_name: reads loginusers.vdf from the Steam roots in order",
  name == "Berk" and #asked == 3 and asked[1] == "/h/.steam/steam/config/loginusers.vdf")
check("persona_name: without HOME -> nil", eos.persona_name({ home = "" }) == nil)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
