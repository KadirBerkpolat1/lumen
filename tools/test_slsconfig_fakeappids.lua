-- Host tests for slsconfig's FakeAppIds map editor.
--
-- Why this editor exists: fixinstall.lua used to reach config.yaml through the
-- LuaTools plugin's slsteam module, which is only on package.path when
-- LUMEN_BACKEND_DIR is set. A plugin-less Lumen still runs the Fixes Menu, and
-- an appid swap that cannot reach config.yaml fails exactly the way a missing
-- swap does -- the P2P cert is rejected.
-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_slsconfig_fakeappids.lua
package.path = "lua/?.lua;" .. package.path

local cfg = require("slsconfig")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.write("FAIL: " .. name .. "\n") end
end
local function eq(name, got, want)
  check(name .. " (got " .. tostring(got) .. ")", got == want)
end

-- A trimmed but realistic config: SCHEMA keys for the validity guard, a
-- commented-out example block, and no FakeAppIds header yet.
local BASE = table.concat({
  "#Example of FakeAppIds:",
  "#FakeAppIds:",
  "#  AppId1: FakeAppId1",
  "DisableFamilyShareLock: no",
  "UseWhitelist: no",
  "AppIds:",
  "API: no",
  "DisableCloud: no",
  "",
}, "\n")

-- ── pure text editing ───────────────────────────────────────────────────────
do
  local out, status = cfg.set_fake_appid_text(BASE, 526870, 480)
  eq("append: status", status, "added")
  check("append: header created", out:find("\nFakeAppIds:\n") ~= nil)
  check("append: entry created", out:find("526870: 480", 1, true) ~= nil)
  check("append: commented example untouched", out:find("#Example of FakeAppIds:", 1, true) ~= nil)
  check("append: DisableFamilyShareLock kept", out:find("DisableFamilyShareLock: no", 1, true) ~= nil)
  eq("append: reads back", cfg.get_fake_appid_text(out, 526870), 480)

  local again, status2 = cfg.set_fake_appid_text(out, 526870, 480)
  eq("idempotent: status", status2, "already_present")
  eq("idempotent: text unchanged", again, out)

  local upd, status3 = cfg.set_fake_appid_text(out, 526870, 730)
  eq("update: status", status3, "updated")
  eq("update: reads back", cfg.get_fake_appid_text(upd, 526870), 730)
  eq("update: only one entry", select(2, upd:gsub("526870:", "")), 1)

  local two = cfg.set_fake_appid_text(out, 3241660, 480)
  eq("second entry: reads back", cfg.get_fake_appid_text(two, 3241660), 480)
  eq("second entry: first survives", cfg.get_fake_appid_text(two, 526870), 480)

  local rm, status4 = cfg.unset_fake_appid_text(two, 526870)
  eq("unset: status", status4, "removed")
  eq("unset: target gone", cfg.get_fake_appid_text(rm, 526870), nil)
  eq("unset: sibling kept", cfg.get_fake_appid_text(rm, 3241660), 480)

  local rm2, status5 = cfg.unset_fake_appid_text(rm, 999)
  eq("unset absent: status", status5, "not_present")
  eq("unset absent: text unchanged", rm2, rm)
end

-- ── inline map is refused, never clobbered ──────────────────────────────────
do
  local inline = BASE .. "FakeAppIds: {526870: 480}\n"
  local out, err = cfg.set_fake_appid_text(inline, 3241660, 480)
  eq("inline header: refused", out, nil)
  check("inline header: reason", tostring(err):find("inline", 1, true) ~= nil)
  eq("inline header: read yields nil", cfg.get_fake_appid_text(inline, 526870), nil)
end

-- ── a hand-annotated block stays editable ──────────────────────────────────
do
  local annotated = BASE .. "FakeAppIds:\n\n  # keep me\n  526870: 480\n"
  local out, status = cfg.set_fake_appid_text(annotated, 3241660, 480)
  eq("annotated: status", status, "added")
  check("annotated: comment kept", out:find("# keep me", 1, true) ~= nil)
  eq("annotated: existing entry kept", cfg.get_fake_appid_text(out, 526870), 480)
  eq("annotated: new entry added", cfg.get_fake_appid_text(out, 3241660), 480)
end

-- ── IO path: atomic write, and the no-clobber guard ────────────────────────
do
  local tmp = os.tmpname()
  os.remove(tmp)
  local f = assert(io.open(tmp, "wb")); f:write(BASE); f:close()

  local ok, status = cfg.set_fake_appid(tmp, 526870, 480)
  check("io: write ok", ok == true)
  eq("io: status", status, "added")
  eq("io: reads back", cfg.get_fake_appid(tmp, 526870), 480)

  local data = assert(io.open(tmp, "rb")):read("*a")
  check("io: trailing newline preserved", data:sub(-1) == "\n")
  check("io: unrelated keys intact", data:find("UseWhitelist: no", 1, true) ~= nil)

  local ok2, status2 = cfg.set_fake_appid(tmp, 526870, 480)
  check("io: idempotent ok", ok2 == true)
  eq("io: idempotent status", status2, "already_present")

  -- An empty file must never be rewritten: a raced/truncated read would
  -- otherwise replace the whole config with a bare FakeAppIds block.
  local empty = os.tmpname(); os.remove(empty)
  local g = assert(io.open(empty, "wb")); g:write(""); g:close()
  local ok3, err3 = cfg.set_fake_appid(empty, 526870, 480)
  check("io: empty refused", ok3 == false)
  check("io: empty reason", tostring(err3):find("refusing", 1, true) ~= nil)
  eq("io: empty file untouched", assert(io.open(empty, "rb")):read("*a"), "")

  -- A file that is not a SLSsteam config must not be appended to either.
  local junk = os.tmpname(); os.remove(junk)
  local h = assert(io.open(junk, "wb")); h:write("hello: world\n"); h:close()
  local ok4 = cfg.set_fake_appid(junk, 526870, 480)
  check("io: non-config refused", ok4 == false)
  eq("io: non-config untouched", assert(io.open(junk, "rb")):read("*a"), "hello: world\n")

  -- Missing file: report, do not create (slsteam-moon writes it on first run).
  local ok5 = cfg.set_fake_appid(tmp .. ".nope", 526870, 480)
  check("io: missing file refused", ok5 == false)

  os.remove(tmp); os.remove(empty); os.remove(junk)
end

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
