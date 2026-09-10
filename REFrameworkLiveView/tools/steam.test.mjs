import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  KNOWN_GAMES,
  collectLibraryPaths,
  findSpec,
  normalize,
  parseGameArg,
  resolveGame,
  scanInstalls,
  unescapeVdf,
  GameNotFound,
} from "./steam.mjs";

const CATALOG = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "steam-games.json",
);

function vdfPath(dir) {
  return dir.replaceAll("\\", "\\\\");
}

function writeLibrary(root, extra) {
  fs.mkdirSync(path.join(root, "steamapps"), { recursive: true });
  fs.mkdirSync(path.join(root, "config"), { recursive: true });
  fs.writeFileSync(
    path.join(root, "config", "libraryfolders.vdf"),
    [
      '"libraryfolders"',
      "{",
      '\t"0"',
      "\t{",
      `\t\t"path"\t\t"${vdfPath(root)}"`,
      "\t}",
      '\t"1"',
      "\t{",
      `\t\t"path"\t\t"${vdfPath(extra)}"`,
      "\t}",
      "}",
      "",
    ].join("\n"),
    "utf8",
  );
}

function writeGame(library, appid, name, installdir) {
  const steamapps = path.join(library, "steamapps");
  const install = path.join(steamapps, "common", installdir);
  fs.mkdirSync(install, { recursive: true });
  fs.writeFileSync(
    path.join(steamapps, `appmanifest_${appid}.acf`),
    [
      '"AppState"',
      "{",
      `\t"appid"\t\t"${appid}"`,
      `\t"name"\t\t"${name}"`,
      `\t"installdir"\t\t"${installdir}"`,
      "}",
      "",
    ].join("\n"),
    "utf8",
  );
  return fs.realpathSync(install);
}

test("catalog is the shared steam-games.json", () => {
  const rows = JSON.parse(fs.readFileSync(CATALOG, "utf8"));
  assert.deepEqual(
    KNOWN_GAMES.map((row) => row.slug),
    rows.map((row) => row.slug),
  );
  assert.ok(findSpec("mhrise"));
  assert.equal(findSpec("mhrise").slug, "monsterhunterrise");
});

test("normalize slug", () => {
  assert.equal(normalize("MonsterHunterWilds"), "monsterhunterwilds");
  assert.equal(normalize("mh-wilds"), "mhwilds");
  assert.ok(findSpec("MonsterHunterWilds"));
  assert.equal(findSpec("mhwilds").slug, "monsterhunterwilds");
  assert.deepEqual(findSpec("dmc5").appids, ["601150"]);
});

test("unescape vdf", () => {
  assert.equal(unescapeVdf("D:\\\\SteamLibrary"), "D:\\SteamLibrary");
});

test("collect libraries and resolve", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "liveview-steam-"));
  try {
    const steam = path.join(tmp, "Steam");
    const extra = path.join(tmp, "SteamLibrary");
    fs.mkdirSync(extra);
    writeLibrary(steam, extra);
    const wilds = writeGame(extra, "2246340", "Monster Hunter Wilds", "MonsterHunterWilds");
    writeGame(steam, "601150", "Devil May Cry 5", "Devil May Cry 5");

    const libs = collectLibraryPaths(steam);
    assert.ok(libs.some((dir) => path.resolve(dir) === path.resolve(steam)));
    assert.ok(libs.some((dir) => path.resolve(dir) === path.resolve(extra)));

    const installs = Object.fromEntries(
      scanInstalls(steam).map((inst) => [inst.installdir, inst]),
    );
    assert.equal(installs.MonsterHunterWilds.appid, "2246340");

    assert.equal(resolveGame("MonsterHunterWilds", steam), wilds);
    assert.equal(resolveGame("mhwilds", steam), wilds);
    assert.equal(resolveGame("2246340", steam), wilds);
    assert.equal(resolveGame(wilds, steam), wilds);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("resolve missing", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "liveview-steam-"));
  try {
    const steam = path.join(tmp, "Steam");
    const extra = path.join(tmp, "EmptyLib");
    fs.mkdirSync(extra);
    writeLibrary(steam, extra);
    assert.throws(() => resolveGame("NotARealGame", steam), GameNotFound);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("parseGameArg", () => {
  assert.equal(parseGameArg(["-game", "MonsterHunterWilds"]), "MonsterHunterWilds");
  assert.equal(parseGameArg(["--game=dmc5"]), "dmc5");
  assert.equal(parseGameArg(["MonsterHunterRise"]), "MonsterHunterRise");
});
