/**
 * Bundle Live View and copy it into a REFramework game install.
 *
 * Same -game flag as liveview-agent start:
 *   npm run deploy -- -game MonsterHunterRise
 *   npm run deploy -- -game MonsterHunterWilds
 *   npm run deploy -- -game "D:\\SteamLibrary\\steamapps\\common\\OnimushaWotS"
 *
 * Or GAME_DIR=... npm run deploy
 *
 * Work in this repo. Deploy writes:
 *   <game>/reframework/autorun/ref_liveview.lua
 *   <game>/reframework/plugins/ref_cursor.dll
 *   <game>/reframework/plugins/ref_live.dll
 *
 * Does not copy or delete onimusha_qol.lua. Does not touch dinput8.dll,
 * REF config, or type dumps.
 */

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { GameNotFound, parseGameArg, resolveGame } from "./steam.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const DIST = path.join(ROOT, "dist");
const BUNDLE_OUT = path.join(DIST, "cache", "ref_liveview.lua");
const SCRIPT_NAME = "ref_liveview.lua";
const REFSHELL_ROOT = path.resolve(
  process.env.REFSHELL_DIR
    || path.join(ROOT, "..", "..", "REFrameworkMods", "REFrameworkRefShell"),
);

function run(cmd, args, opts = {}) {
  const result = spawnSync(cmd, args, { stdio: "inherit", ...opts });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${cmd} ${args.join(" ")} exited with ${result.status}`);
  }
}

function resolveGameDir() {
  const game = parseGameArg();
  if (game) {
    return resolveGame(game);
  }
  if (process.env.GAME_DIR) {
    return resolveGame(process.env.GAME_DIR);
  }
  throw new Error(
    "Game folder not found. Use the steamapps\\common folder name, same as liveview-agent:\n"
    + "  npm run deploy -- -game MonsterHunterWilds\n"
    + "  npm run deploy MonsterHunterWilds\n"
    + "  node tools/deploy.mjs -game MonsterHunterRise",
  );
}

function main() {
  const gameDir = resolveGameDir();
  const autorun = path.join(gameDir, "reframework", "autorun");
  const dataDir = path.join(gameDir, "reframework", "data");
  const dest = path.join(autorun, SCRIPT_NAME);

  run(process.execPath, [path.join(ROOT, "tools", "bundle.mjs"), BUNDLE_OUT], {
    cwd: ROOT,
  });

  if (!fs.existsSync(BUNDLE_OUT)) {
    throw new Error(`Bundle missing after build: ${BUNDLE_OUT}`);
  }

  fs.mkdirSync(autorun, { recursive: true });
  fs.copyFileSync(BUNDLE_OUT, dest);

  function copyPlugin(name, fromRoot) {
    const src = path.join(fromRoot, "reframework", "plugins", name);
    const dest = path.join(gameDir, "reframework", "plugins", name);
    if (!fs.existsSync(src)) {
      throw new Error(`${name} missing: ${src}`);
    }
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    try {
      fs.copyFileSync(src, dest);
      console.log(`Copied ${name} -> ${dest}`);
    } catch (err) {
      if (err && (err.code === "EBUSY" || err.code === "EPERM")) {
        console.log(`Skipped ${name} (locked — close the game to update)`);
        return;
      }
      throw err;
    }
  }

  copyPlugin("ref_cursor.dll", REFSHELL_ROOT);
  copyPlugin("ref_live.dll", ROOT);

  // Avoid a second Live View if leftover live-edit copies are still in autorun.
  // Do not touch Onimusha QoL files.
  for (const leftover of ["main.lua", "refshell.lua", "liveview.lua"]) {
    const leftoverPath = path.join(autorun, leftover);
    if (fs.existsSync(leftoverPath)) {
      fs.rmSync(leftoverPath);
      console.log(`Removed leftover ${leftover}`);
    }
  }
  const leftoverDir = path.join(autorun, "refshell");
  if (fs.existsSync(leftoverDir)) {
    fs.rmSync(leftoverDir, { recursive: true, force: true });
    console.log("Removed leftover refshell/");
  }
  const leftoverReset = path.join(gameDir, "reframework", "plugins", "ref_reset.dll");
  if (fs.existsSync(leftoverReset)) {
    try {
      fs.rmSync(leftoverReset);
      console.log("Removed leftover ref_reset.dll");
    } catch (err) {
      if (!err || (err.code !== "EBUSY" && err.code !== "EPERM")) {
        throw err;
      }
      console.log("Skipped leftover ref_reset.dll (locked — close the game to remove)");
    }
  }
  if (fs.existsSync(dataDir)) {
    for (const leftover of ["liveview_reload.lua", "refshell_live_reload.lua"]) {
      const leftoverPath = path.join(dataDir, leftover);
      if (fs.existsSync(leftoverPath)) {
        fs.rmSync(leftoverPath);
        console.log(`Removed leftover ${leftover}`);
      }
    }
  }

  const kb = (fs.statSync(dest).size / 1024).toFixed(1);
  console.log(`Copied ${SCRIPT_NAME} -> ${dest} (${kb} KiB)`);
  console.log(`Game  ${gameDir}`);
}

try {
  main();
} catch (err) {
  const prefix = err instanceof GameNotFound ? "deploy" : "deploy failed";
  console.error(`${prefix}: ${err.message}`);
  process.exit(1);
}
