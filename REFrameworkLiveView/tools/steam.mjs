/**
 * Steam library scan for GAME_DIR.
 * Same slugs / aliases / libraryfolders.vdf rules as liveview-agent (backend/steam.py).
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

export class GameNotFound extends Error {
  constructor(message) {
    super(message);
    this.name = "GameNotFound";
  }
}

/** Slugs are what you pass to -game. installdirs are Steam's common/ folder names. */
export const KNOWN_GAMES = [
  {
    slug: "monsterhunterwilds",
    aliases: ["mhwilds", "mh-wilds", "mhws", "wilds"],
    installdirs: ["MonsterHunterWilds", "Monster Hunter Wilds"],
    appids: ["2246340"],
  },
  {
    slug: "monsterhunterrise",
    aliases: ["mhrise", "mh-rise", "mhr", "rise"],
    installdirs: ["MonsterHunterRise", "Monster Hunter Rise"],
    appids: ["1446780"],
  },
  {
    slug: "onimushawots",
    aliases: ["onimusha", "wots"],
    installdirs: ["OnimushaWotS"],
    appids: [],
  },
  {
    slug: "dmc5",
    aliases: ["devilmaycry5", "devilmaycry", "dmc"],
    installdirs: ["Devil May Cry 5", "DevilMayCry5"],
    appids: ["601150"],
  },
];

export function normalize(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "");
}

export function unescapeVdf(value) {
  return String(value).replace(/\\\\/g, "\\").replace(/\\"/g, '"');
}

export function existingDir(raw) {
  const text = String(raw || "").trim().replace(/^["']|["']$/g, "");
  if (!text) {
    return null;
  }
  try {
    const full = path.resolve(text);
    return fs.existsSync(full) && fs.statSync(full).isDirectory() ? full : null;
  } catch {
    return null;
  }
}

function steamFromRegistry() {
  if (process.platform !== "win32") {
    return null;
  }
  const keys = [
    ["HKLM\\SOFTWARE\\WOW6432Node\\Valve\\Steam", "InstallPath"],
    ["HKLM\\SOFTWARE\\Valve\\Steam", "InstallPath"],
    ["HKCU\\SOFTWARE\\Valve\\Steam", "SteamPath"],
  ];
  for (const [key, valueName] of keys) {
    const result = spawnSync("reg", ["query", key, "/v", valueName], {
      encoding: "utf8",
      windowsHide: true,
    });
    if (result.status !== 0 || !result.stdout) {
      continue;
    }
    const match = result.stdout.match(/REG_(?:SZ|EXPAND_SZ)\s+(.+\S)/);
    if (!match) {
      continue;
    }
    const found = existingDir(unescapeVdf(match[1].trim()));
    if (found) {
      return found;
    }
  }
  return null;
}

function unixSteamCandidates() {
  const home = process.env.HOME || os.homedir();
  if (!home) {
    return [];
  }
  return [
    path.join(home, ".steam", "steam"),
    path.join(home, ".steam", "root"),
    path.join(home, ".local", "share", "Steam"),
    path.join(home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam"),
  ];
}

export function findSteamInstallPath() {
  if (process.platform === "win32") {
    const fromReg = steamFromRegistry();
    if (fromReg) {
      return fromReg;
    }
    for (const candidate of [
      "C:\\Program Files (x86)\\Steam",
      "C:\\Program Files\\Steam",
    ]) {
      const found = existingDir(candidate);
      if (found) {
        return found;
      }
    }
  }
  for (const candidate of unixSteamCandidates()) {
    const found = existingDir(candidate);
    if (found) {
      return found;
    }
  }
  return null;
}

export function collectLibraryPaths(steamPath) {
  const libraries = [];
  const seen = new Set();

  function add(dir) {
    if (!dir) {
      return;
    }
    const key = dir.toLowerCase();
    if (seen.has(key)) {
      return;
    }
    seen.add(key);
    libraries.push(dir);
  }

  add(existingDir(steamPath));
  for (const rel of ["config/libraryfolders.vdf", "steamapps/libraryfolders.vdf"]) {
    const vdf = path.join(steamPath, rel);
    if (!fs.existsSync(vdf)) {
      continue;
    }
    let text = "";
    try {
      text = fs.readFileSync(vdf, "utf8");
    } catch {
      continue;
    }
    for (const line of text.split(/\r?\n/)) {
      const match = line.match(/^\s*"path"\s+"(.+)"\s*$/i);
      if (match) {
        add(existingDir(unescapeVdf(match[1])));
      }
    }
  }
  return libraries;
}

function readManifest(manifestPath) {
  let text = "";
  try {
    text = fs.readFileSync(manifestPath, "utf8");
  } catch {
    return null;
  }
  let name = "";
  let installdir = "";
  let appid = "";
  for (const line of text.split(/\r?\n/)) {
    if (!name) {
      const match = line.match(/^\s*"name"\s+"(.+)"\s*$/i);
      if (match) {
        name = unescapeVdf(match[1]).trim();
      }
    }
    if (!installdir) {
      const match = line.match(/^\s*"installdir"\s+"(.+)"\s*$/i);
      if (match) {
        installdir = unescapeVdf(match[1]).trim();
      }
    }
    if (!appid) {
      const match = line.match(/^\s*"appid"\s+"(.+)"\s*$/i);
      if (match) {
        appid = unescapeVdf(match[1]).trim();
      }
    }
    if (name && installdir && appid) {
      break;
    }
  }
  if (!name || !installdir) {
    return null;
  }
  const common = path.join(path.dirname(manifestPath), "common", installdir);
  const resolved = existingDir(common);
  if (!resolved) {
    return null;
  }
  return { name, installdir, appid, path: resolved };
}

export function scanInstalls(steamPath) {
  const root = steamPath || findSteamInstallPath();
  if (!root) {
    return [];
  }
  const seen = new Set();
  const installs = [];
  for (const library of collectLibraryPaths(root)) {
    const steamapps = path.join(library, "steamapps");
    if (!fs.existsSync(steamapps)) {
      continue;
    }
    let names = [];
    try {
      names = fs.readdirSync(steamapps);
    } catch {
      continue;
    }
    for (const file of names) {
      if (!/^appmanifest_.*\.acf$/i.test(file)) {
        continue;
      }
      const inst = readManifest(path.join(steamapps, file));
      if (!inst) {
        continue;
      }
      const key = inst.path.toLowerCase();
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      installs.push(inst);
    }
  }
  return installs;
}

export function findSpec(query) {
  const needle = normalize(query);
  if (!needle) {
    return null;
  }
  for (const spec of KNOWN_GAMES) {
    const names = [spec.slug, ...spec.aliases, ...spec.installdirs, ...spec.appids];
    if (names.some((name) => normalize(name) === needle)) {
      return spec;
    }
  }
  return null;
}

function matches(query, spec, inst) {
  const needle = normalize(query);
  if (inst.appid && inst.appid === String(query).trim()) {
    return true;
  }
  if (normalize(inst.installdir) === needle || normalize(inst.name) === needle) {
    return true;
  }
  if (!spec) {
    return false;
  }
  if (inst.appid && spec.appids.includes(inst.appid)) {
    return true;
  }
  const wanted = new Set(spec.installdirs.map(normalize));
  wanted.add(spec.slug);
  return wanted.has(normalize(inst.installdir));
}

function folderInLibraries(libraries, names) {
  const wanted = new Set(names.map(normalize));
  for (const library of libraries) {
    const common = path.join(library, "steamapps", "common");
    if (!fs.existsSync(common)) {
      continue;
    }
    for (const name of names) {
      const found = existingDir(path.join(common, name));
      if (found) {
        return found;
      }
    }
    let kids = [];
    try {
      kids = fs.readdirSync(common, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const kid of kids) {
      if (kid.isDirectory() && wanted.has(normalize(kid.name))) {
        return path.resolve(common, kid.name);
      }
    }
  }
  return null;
}

function notFoundMessage(query, steamPath, libraries, installs) {
  const slugs = KNOWN_GAMES.map((spec) => spec.slug).join(", ");
  const lines = [
    `Game not found: ${query}`,
    `Steam: ${steamPath}`,
    "Libraries:",
  ];
  if (libraries.length) {
    for (const lib of libraries) {
      lines.push(`  ${lib}`);
    }
  } else {
    lines.push("  (none)");
  }
  lines.push(`Known slugs: ${slugs}`);
  if (installs.length) {
    lines.push("Installed (first 20):");
    for (const inst of installs.slice(0, 20)) {
      lines.push(`  ${inst.installdir}  (${inst.name})`);
    }
  }
  return lines.join("\n");
}

export function resolveGame(query, steamPath) {
  const raw = String(query || "").trim().replace(/^["']|["']$/g, "");
  if (!raw) {
    throw new GameNotFound("Empty -game value.");
  }
  const asPath = existingDir(raw);
  if (asPath) {
    return asPath;
  }

  const spec = findSpec(raw);
  const root = steamPath || findSteamInstallPath();
  if (!root) {
    throw new GameNotFound(
      `Steam install not found. Pass a full folder: -game "D:\\SteamLibrary\\steamapps\\common\\${raw}"`,
    );
  }

  const libraries = collectLibraryPaths(root);
  const installs = scanInstalls(root);
  const hits = installs.filter((inst) => matches(raw, spec, inst));
  if (hits.length) {
    return hits[0].path;
  }

  const names = spec ? spec.installdirs : [raw];
  const folder = folderInLibraries(libraries, names);
  if (folder) {
    return folder;
  }

  throw new GameNotFound(notFoundMessage(raw, root, libraries, installs));
}

export function parseGameArg(argv = process.argv.slice(2)) {
  let positional = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "-game" || arg === "--game") {
      return argv[i + 1] || "";
    }
    if (arg.startsWith("--game=")) {
      return arg.slice("--game=".length);
    }
    if (arg.startsWith("-game=")) {
      return arg.slice("-game=".length);
    }
    if (!arg.startsWith("-") && positional === null) {
      positional = arg;
    }
  }
  // npm run deploy -game MonsterHunterWilds eats -game and leaves the folder name.
  const fromNpm = process.env.npm_config_game;
  if (fromNpm && fromNpm !== "true") {
    return fromNpm;
  }
  return positional;
}
