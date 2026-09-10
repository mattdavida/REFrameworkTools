import json
from pathlib import Path

import pytest

from backend.steam import (
    KNOWN_GAMES,
    GameNotFound,
    collect_library_paths,
    find_spec,
    normalize,
    read_manifest,
    resolve_game,
    scan_installs,
    unescape_vdf,
)


def test_normalize_slug() -> None:
    assert normalize("MonsterHunterWilds") == "monsterhunterwilds"
    assert normalize("mh-wilds") == "mhwilds"
    assert find_spec("MonsterHunterWilds") is not None
    assert find_spec("mhwilds").slug == "monsterhunterwilds"
    assert find_spec("dmc5").appids == ("601150",)
    assert find_spec("mhrise").slug == "monsterhunterrise"


def test_shared_catalog() -> None:
    catalog = Path(__file__).resolve().parents[2] / "steam-games.json"
    rows = json.loads(catalog.read_text(encoding="utf-8"))
    assert [spec.slug for spec in KNOWN_GAMES] == [row["slug"] for row in rows]


def test_unescape_vdf() -> None:
    assert unescape_vdf(r"D:\\SteamLibrary") == r"D:\SteamLibrary"


def _vdf_path(path: Path) -> str:
    return str(path.resolve()).replace("\\", "\\\\")


def _write_library(root: Path, extra: Path) -> None:
    steamapps = root / "steamapps"
    steamapps.mkdir(parents=True)
    (root / "config").mkdir()
    (root / "config" / "libraryfolders.vdf").write_text(
        "\n".join(
            [
                '"libraryfolders"',
                "{",
                '\t"0"',
                "\t{",
                f'\t\t"path"\t\t"{_vdf_path(root)}"',
                "\t}",
                '\t"1"',
                "\t{",
                f'\t\t"path"\t\t"{_vdf_path(extra)}"',
                "\t}",
                "}",
                "",
            ]
        ),
        encoding="utf-8",
    )


def _write_game(library: Path, appid: str, name: str, installdir: str) -> Path:
    steamapps = library / "steamapps"
    steamapps.mkdir(parents=True, exist_ok=True)
    install = steamapps / "common" / installdir
    install.mkdir(parents=True)
    (steamapps / f"appmanifest_{appid}.acf").write_text(
        "\n".join(
            [
                '"AppState"',
                "{",
                f'\t"appid"\t\t"{appid}"',
                f'\t"name"\t\t"{name}"',
                f'\t"installdir"\t\t"{installdir}"',
                "}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return install


def test_collect_libraries_and_resolve(tmp_path: Path) -> None:
    steam = tmp_path / "Steam"
    extra = tmp_path / "SteamLibrary"
    extra.mkdir()
    _write_library(steam, extra)
    wilds = _write_game(extra, "2246340", "Monster Hunter Wilds", "MonsterHunterWilds")
    _write_game(steam, "601150", "Devil May Cry 5", "Devil May Cry 5")

    libs = collect_library_paths(steam)
    assert steam.resolve() in libs
    assert extra.resolve() in libs

    installs = {inst.installdir: inst for inst in scan_installs(steam)}
    assert "MonsterHunterWilds" in installs
    assert installs["MonsterHunterWilds"].appid == "2246340"

    assert resolve_game("MonsterHunterWilds", steam) == wilds.resolve()
    assert resolve_game("mhwilds", steam) == wilds.resolve()
    assert resolve_game("2246340", steam) == wilds.resolve()
    assert resolve_game(str(wilds), steam) == wilds.resolve()


def test_resolve_missing(tmp_path: Path) -> None:
    steam = tmp_path / "Steam"
    extra = tmp_path / "EmptyLib"
    extra.mkdir()
    _write_library(steam, extra)
    with pytest.raises(GameNotFound, match="Game not found"):
        resolve_game("NotARealGame", steam)
