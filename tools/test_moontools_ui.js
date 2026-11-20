// test_moontools_ui.js — contract tests for MoonTools Lumen UI additions:
//   * full Turkish (tr) locale parity with en across every nested I18N block
//   * healthStrings() + Stack Health tab rendering (14-health-tab.js)
//   * Cloud Saves native folder picker & ~/CloudSaves/Steam preset
//   * Fixes Menu dropzone, native picker RPCs, and SHA-256 revert feedback
// Run: node tools/test_moontools_ui.js
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const MENU_DIR = path.join(__dirname, "..", "lua", "menu");
const PARTS = [
  "01-core.js", "02-i18n.js", "03-styles.js", "04-overlay-helpers.js",
  "05-config-tab.js", "06-updates-helpers.js", "07-updates-tab.js",
  "08-about-tab.js", "09-luatools-account.js", "09-overlay.js",
  "10-auto-fix-status.js", "10-fixes-menu.js", "12-cloud-tab.js",
  "13-sls-check.js", "14-health-tab.js", "11-menubar.js",
];
const SOURCE = PARTS.map((p) => fs.readFileSync(path.join(MENU_DIR, p), "utf8")).join("\n");

let fails = 0;
const fail = (m) => { console.error("FAIL: " + m); fails++; };
const ok = (m) => console.log("ok   " + m);

function stubEl() {
  return {
    style: {},
    classList: { add() {}, remove() {}, toggle() {} },
    appendChild() {},
    addEventListener() {},
    setAttribute() {},
    remove() {},
    textContent: "",
    title: "",
    id: "",
    value: "",
  };
}

function ctxFor(lang) {
  const win = {};
  const ctx = {
    window: win,
    document: {
      getElementById: () => null,
      createElement: () => stubEl(),
      querySelectorAll: () => [],
      head: { appendChild() {} },
      body: { appendChild() {} },
      documentElement: { appendChild() {} },
      addEventListener() {},
      removeEventListener() {},
    },
    location: { hostname: "steamloopback.host" },
    navigator: { language: lang },
    console: { log() {} },
    setTimeout: () => 0,
    clearTimeout: () => {},
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  return win;
}

function collectKeys(obj, prefix = "") {
  const keys = [];
  for (const [k, v] of Object.entries(obj || {})) {
    const p = prefix ? `${prefix}.${k}` : k;
    if (v && typeof v === "object" && !Array.isArray(v)) {
      keys.push(...collectKeys(v, p));
    } else {
      keys.push(p);
    }
  }
  return keys;
}

const winTr = ctxFor("tr-TR");
const I = winTr.__lumenI18n;
if (!I || !I.tr || !I["pt-BR"] || !I.en) {
  fail("I18N missing en, pt-BR, or tr locale");
} else {
  const enKeys = new Set(collectKeys(I.en));
  for (const loc of ["tr", "pt-BR"]) {
    const locKeys = new Set(collectKeys(I[loc]));
    const missing = [...enKeys].filter((k) => !locKeys.has(k));
    if (missing.length) fail(`${loc} missing I18N keys: ${missing.slice(0, 10).join(", ")}`);
    else ok(`${loc} has all ${enKeys.size} I18N keys`);
  }
  if (winTr.__lumenHealthStrings().tab !== "Sistem Sağlığı") {
    fail("tr-TR did not resolve Turkish health tab title");
  } else {
    ok("tr-TR resolves Turkish healthStrings()");
  }
  if (winTr.__lumenCloudStrings().tab !== "Bulut Kayıtları") {
    fail("tr-TR did not resolve Turkish cloud tab title");
  } else {
    ok("tr-TR resolves Turkish cloudStrings()");
  }
}

const cloudSrc = fs.readFileSync(path.join(MENU_DIR, "12-cloud-tab.js"), "utf8");
if (!cloudSrc.includes("LumenPickDirectory") || !cloudSrc.includes("~/CloudSaves/Steam")) {
  fail("12-cloud-tab.js missing native folder picker or ~/CloudSaves/Steam preset");
} else {
  ok("12-cloud-tab.js wires LumenPickDirectory and ~/CloudSaves/Steam preset");
}

const fixesSrc = fs.readFileSync(path.join(MENU_DIR, "10-fixes-menu.js"), "utf8");
if (!fixesSrc.includes("LumenPickFixSource") || !fixesSrc.includes("LumenPickDirectory")
    || !fixesSrc.includes("lumen-fx-dropzone") || !fixesSrc.includes("verifiedRestores")) {
  fail("10-fixes-menu.js missing local picker/dropzone or verifiedRestores feedback");
} else {
  ok("10-fixes-menu.js wires dropzone, native pickers, and SHA-256 revert feedback");
}

const healthSrc = fs.readFileSync(path.join(MENU_DIR, "14-health-tab.js"), "utf8");
if (!healthSrc.includes("LumenStackHealth") || !healthSrc.includes("function renderHealth")) {
  fail("14-health-tab.js missing renderHealth / LumenStackHealth");
} else {
  ok("14-health-tab.js defines renderHealth and calls LumenStackHealth");
}

if (fails) {
  console.error(`\n${fails} check(s) failed`);
  process.exit(1);
}
console.log("\nall ok");
