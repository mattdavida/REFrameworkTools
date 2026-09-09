/**
 * Pack sibling RefShell chrome + this repo's Live View into one autorun script.
 *
 * Usage: npm run bundle
 *        node tools/bundle.mjs <out.lua>
 * Default output: dist/cache/ref_liveview.lua
 *
 * RefShell is ../../REFrameworkMods/REFrameworkRefShell (or REFSHELL_DIR).
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const OUT = path.resolve(process.argv[2] || path.join(ROOT, "dist", "cache", "ref_liveview.lua"));
const REFSHELL_ROOT = path.resolve(
  process.env.REFSHELL_DIR
    || path.join(ROOT, "..", "..", "REFrameworkMods", "REFrameworkRefShell"),
);

const REFSHELL_MODULES = [
  ["refshell.util", "lua/refshell/util.lua"],
  ["refshell.config", "lua/refshell/config.lua"],
  ["refshell.input", "lua/refshell/input.lua"],
  ["refshell.theme", "lua/refshell/theme.lua"],
  ["refshell.host", "lua/refshell/host.lua"],
  ["refshell.log", "lua/refshell/log.lua"],
  ["refshell.ui", "lua/refshell/ui.lua"],
  ["refshell", "lua/refshell.lua"],
];

const LIVE_MODULES = [
  ["liveview.core", "lua/liveview/core.lua"],
  ["liveview.cache", "lua/liveview/cache.lua"],
  ["liveview.tdb", "lua/liveview/tdb.lua"],
  ["liveview.bridge", "lua/liveview/bridge.lua"],
  ["liveview.invoke", "lua/liveview/invoke.lua"],
  ["liveview.ui.widgets", "lua/liveview/ui/widgets.lua"],
  ["liveview.ui.inspect", "lua/liveview/ui/inspect.lua"],
  ["liveview.ui.call", "lua/liveview/ui/call.lua"],
  ["liveview.ui.chat", "lua/liveview/ui/chat.lua"],
  ["liveview.ui.workspace", "lua/liveview/ui/workspace.lua"],
  ["liveview.ui.finder", "lua/liveview/ui/finder.lua"],
  ["liveview", "lua/liveview.lua"],
];

const IIFE_FILES = ["reframework/autorun/main.lua"];

function readLua(absPath) {
  if (!fs.existsSync(absPath)) {
    throw new Error(`Missing source: ${absPath}`);
  }
  return fs.readFileSync(absPath, "utf8").replace(/^\uFEFF/, "");
}

function wrapPreload(name, label, source) {
  const body = source.replace(/\s*$/, "");
  return `-- ${label}\npackage.preload[${JSON.stringify(name)}] = function(...)\n${body}\nend\n`;
}

function wrapIife(relPath, source) {
  const body = source.replace(/\s*$/, "");
  return `-- ${relPath}\ndo\n(function()\n${body}\nend)()\nend\n`;
}

function main() {
  if (!fs.existsSync(path.join(REFSHELL_ROOT, "lua", "refshell.lua"))) {
    throw new Error(`RefShell not found at ${REFSHELL_ROOT}. Set REFSHELL_DIR.`);
  }
  if (!fs.existsSync(path.join(ROOT, "lua", "liveview.lua"))) {
    throw new Error(`Live View source missing at ${path.join(ROOT, "lua", "liveview.lua")}`);
  }

  const parts = [
    ...REFSHELL_MODULES.map(([name, rel]) => {
      return wrapPreload(name, rel, readLua(path.join(REFSHELL_ROOT, rel)));
    }),
    ...LIVE_MODULES.map(([name, rel]) => {
      return wrapPreload(name, rel, readLua(path.join(ROOT, rel)));
    }),
    `require("refshell")\n`,
    ...IIFE_FILES.map((relPath) => wrapIife(relPath, readLua(path.join(ROOT, relPath)))),
  ];

  const listed = [
    ...REFSHELL_MODULES.map(([, rel]) => `refshell:${rel}`),
    ...LIVE_MODULES.map(([, rel]) => rel),
    ...IIFE_FILES,
  ];
  const bundled = `--[[
  ref_liveview.lua — generated release bundle. Do not edit.

  Build: npm run bundle
  Install as: reframework/autorun/ref_liveview.lua

  Self-contained: ${listed.join(", then ")}.
]]
${parts.join("\n")}`;

  if (!bundled.includes("_G.RefShell")) {
    throw new Error("Bundle must assign _G.RefShell");
  }
  if (!bundled.includes('package.preload["refshell.host"]')) {
    throw new Error("Bundle must preload refshell.host");
  }
  if (!bundled.includes('package.preload["liveview.core"]')) {
    throw new Error("Bundle must preload liveview.core");
  }
  if (!bundled.includes('package.preload["liveview"]')) {
    throw new Error("Bundle must preload liveview");
  }
  if (!bundled.includes("LIVE VIEW")) {
    throw new Error("Bundle must include the Live View menu");
  }
  if (!bundled.includes("LiveView.attach")) {
    throw new Error("Bundle must attach Live View");
  }
  if (bundled.includes("devtools = true")) {
    throw new Error("Live View must not use RefShell devtools");
  }
  if (/end\)\(\)\s*\(function/.test(bundled)) {
    throw new Error("Adjacent IIFEs would be parsed as a call");
  }

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, bundled, "utf8");

  const kb = (Buffer.byteLength(bundled, "utf8") / 1024).toFixed(1);
  console.log(`Wrote ${path.relative(ROOT, OUT)} (${kb} KiB)`);
}

try {
  main();
} catch (err) {
  console.error(`bundle failed: ${err.message}`);
  process.exit(1);
}
