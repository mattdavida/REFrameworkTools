"""
Steam library scan for GAME_DIR.

Same discovery as UE4SSInstaller SteamScanner: Windows registry / well-known
paths, then libraryfolders.vdf and appmanifest_*.acf. No Unreal filter —
we want the RE Engine install folder (Browse local files).
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

_VDF_PATH = re.compile(r'^\s*"path"\s+"(.+)"\s*$', re.IGNORECASE)
_VDF_NAME = re.compile(r'^\s*"name"\s+"(.+)"\s*$', re.IGNORECASE)
_VDF_INSTALLDIR = re.compile(r'^\s*"installdir"\s+"(.+)"\s*$', re.IGNORECASE)
_VDF_APPID = re.compile(r'^\s*"appid"\s+"(.+)"\s*$', re.IGNORECASE)


@dataclass(frozen=True)
class GameSpec:
    slug: str
    aliases: tuple[str, ...]
    installdirs: tuple[str, ...]
    appids: tuple[str, ...]


@dataclass(frozen=True)
class SteamInstall:
    name: str
    installdir: str
    appid: str
    path: Path


class GameNotFound(Exception):
    pass


def _catalog_path() -> Path | None:
    here = Path(__file__).resolve()
    for candidate in (
        here.parents[2] / "steam-games.json",
        here.parents[1] / "steam-games.json",
    ):
        if candidate.is_file():
            return candidate
    return None


def _load_known_games() -> tuple[GameSpec, ...]:
    path = _catalog_path()
    if path is None:
        raise FileNotFoundError(
            "steam-games.json not found next to this repo. "
            "Expected REFrameworkTools/steam-games.json."
        )
    rows = json.loads(path.read_text(encoding="utf-8"))
    return tuple(
        GameSpec(
            slug=str(row["slug"]),
            aliases=tuple(row.get("aliases") or ()),
            installdirs=tuple(row.get("installdirs") or ()),
            appids=tuple(str(appid) for appid in (row.get("appids") or ())),
        )
        for row in rows
    )


# Slugs are what you pass to -game. installdirs are Steam's common/ folder names.
# Shared catalog: ../../steam-games.json (same file deploy's steam.mjs reads).
KNOWN_GAMES: tuple[GameSpec, ...] = _load_known_games()


def normalize(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def unescape_vdf(value: str) -> str:
    return value.replace("\\\\", "\\").replace('\\"', '"')


def existing_dir(path: str | Path) -> Path | None:
    raw = str(path).strip().strip('"')
    if not raw:
        return None
    try:
        full = Path(raw).expanduser().resolve()
    except OSError:
        return None
    return full if full.is_dir() else None


def find_steam_install_path() -> Path | None:
    if sys.platform == "win32":
        found = _steam_from_registry()
        if found:
            return found
        for candidate in (
            r"C:\Program Files (x86)\Steam",
            r"C:\Program Files\Steam",
        ):
            found = existing_dir(candidate)
            if found:
                return found
    for candidate in _unix_steam_candidates():
        found = existing_dir(candidate)
        if found:
            return found
    return None


def _steam_from_registry() -> Path | None:
    try:
        import winreg
    except ImportError:
        return None
    hives = (
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam", "InstallPath"),
        (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Valve\Steam", "SteamPath"),
    )
    for hive, subkey, value_name in hives:
        try:
            with winreg.OpenKey(hive, subkey) as key:
                raw, _ = winreg.QueryValueEx(key, value_name)
        except OSError:
            continue
        if isinstance(raw, str):
            found = existing_dir(unescape_vdf(raw.strip()))
            if found:
                return found
    return None


def _unix_steam_candidates() -> list[str]:
    home = os.environ.get("HOME") or str(Path.home())
    if not home:
        return []
    return [
        str(Path(home) / ".steam" / "steam"),
        str(Path(home) / ".steam" / "root"),
        str(Path(home) / ".local" / "share" / "Steam"),
        str(
            Path(home)
            / ".var"
            / "app"
            / "com.valvesoftware.Steam"
            / ".local"
            / "share"
            / "Steam"
        ),
    ]


def collect_library_paths(steam_path: Path) -> list[Path]:
    libraries: list[Path] = []
    seen: set[str] = set()

    def add(path: Path | None) -> None:
        if path is None:
            return
        key = str(path).casefold()
        if key in seen:
            return
        seen.add(key)
        libraries.append(path)

    add(existing_dir(steam_path))
    for vdf in (
        steam_path / "config" / "libraryfolders.vdf",
        steam_path / "steamapps" / "libraryfolders.vdf",
    ):
        if not vdf.is_file():
            continue
        try:
            lines = vdf.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            match = _VDF_PATH.match(line)
            if match:
                add(existing_dir(unescape_vdf(match.group(1))))
    return libraries


def read_manifest(path: Path) -> SteamInstall | None:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    name = installdir = appid = ""
    for line in lines:
        if not name:
            match = _VDF_NAME.match(line)
            if match:
                name = unescape_vdf(match.group(1)).strip()
        if not installdir:
            match = _VDF_INSTALLDIR.match(line)
            if match:
                installdir = unescape_vdf(match.group(1)).strip()
        if not appid:
            match = _VDF_APPID.match(line)
            if match:
                appid = unescape_vdf(match.group(1)).strip()
        if name and installdir and appid:
            break
    if not name or not installdir:
        return None
    common = path.parent / "common" / installdir
    if not common.is_dir():
        return None
    try:
        resolved = common.resolve()
    except OSError:
        return None
    return SteamInstall(name=name, installdir=installdir, appid=appid, path=resolved)


def scan_installs(steam_path: Path | None = None) -> list[SteamInstall]:
    root = steam_path or find_steam_install_path()
    if root is None:
        return []
    seen: set[str] = set()
    installs: list[SteamInstall] = []
    for library in collect_library_paths(root):
        steamapps = library / "steamapps"
        if not steamapps.is_dir():
            continue
        try:
            manifests = steamapps.glob("appmanifest_*.acf")
        except OSError:
            continue
        for manifest in manifests:
            inst = read_manifest(manifest)
            if inst is None:
                continue
            key = str(inst.path).casefold()
            if key in seen:
                continue
            seen.add(key)
            installs.append(inst)
    return installs


def find_spec(query: str) -> GameSpec | None:
    needle = normalize(query)
    if not needle:
        return None
    for spec in KNOWN_GAMES:
        names = (spec.slug, *spec.aliases, *spec.installdirs, *spec.appids)
        if any(normalize(name) == needle for name in names):
            return spec
    return None


def _matches(query: str, spec: GameSpec | None, inst: SteamInstall) -> bool:
    needle = normalize(query)
    if inst.appid and inst.appid == query.strip():
        return True
    if normalize(inst.installdir) == needle or normalize(inst.name) == needle:
        return True
    if spec is None:
        return False
    if inst.appid and inst.appid in spec.appids:
        return True
    wanted = {normalize(d) for d in spec.installdirs}
    wanted.add(spec.slug)
    return normalize(inst.installdir) in wanted


def _folder_in_libraries(libraries: list[Path], names: tuple[str, ...]) -> Path | None:
    for library in libraries:
        common = library / "steamapps" / "common"
        if not common.is_dir():
            continue
        for name in names:
            found = existing_dir(common / name)
            if found:
                return found
        try:
            kids = list(common.iterdir())
        except OSError:
            continue
        wanted = {normalize(n) for n in names}
        for kid in kids:
            if kid.is_dir() and normalize(kid.name) in wanted:
                return kid.resolve()
    return None


def resolve_game(query: str, steam_path: Path | None = None) -> Path:
    raw = query.strip().strip('"')
    if not raw:
        raise GameNotFound("Empty -game value.")
    as_path = existing_dir(raw)
    if as_path:
        return as_path

    spec = find_spec(raw)
    root = steam_path or find_steam_install_path()
    if root is None:
        raise GameNotFound(
            f"Steam install not found. Pass a full folder: -game \"D:\\SteamLibrary\\steamapps\\common\\{raw}\""
        )

    libraries = collect_library_paths(root)
    installs = scan_installs(root)
    hits = [inst for inst in installs if _matches(raw, spec, inst)]
    if hits:
        return hits[0].path

    names = spec.installdirs if spec else (raw,)
    folder = _folder_in_libraries(libraries, names)
    if folder:
        return folder

    raise GameNotFound(_not_found_message(raw, root, libraries, installs))


def _not_found_message(
    query: str,
    steam_path: Path,
    libraries: list[Path],
    installs: list[SteamInstall],
) -> str:
    slugs = ", ".join(spec.slug for spec in KNOWN_GAMES)
    lines = [
        f"Game not found: {query}",
        f"Steam: {steam_path}",
        "Libraries:",
    ]
    if libraries:
        lines.extend(f"  {lib}" for lib in libraries)
    else:
        lines.append("  (none)")
    lines.append(f"Known slugs: {slugs}")
    if installs:
        lines.append("Installed (first 20):")
        for inst in installs[:20]:
            lines.append(f"  {inst.installdir}  ({inst.name})")
    return "\n".join(lines)
