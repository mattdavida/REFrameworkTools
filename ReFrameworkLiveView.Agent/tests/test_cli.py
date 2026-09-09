from pathlib import Path

from backend.cli import (
    build_parser,
    cmd_install,
    cmd_isup,
    cmd_start,
    cmd_stop,
    wait_for_ready,
)


def test_isup_down(monkeypatch) -> None:
    monkeypatch.setattr("backend.cli.fetch_health", lambda port, timeout_s=1.5: None)
    assert cmd_isup(3002) == 1


def test_isup_up(monkeypatch, capsys) -> None:
    monkeypatch.setattr(
        "backend.cli.fetch_health",
        lambda port, timeout_s=1.5: {
            "product": "liveview-agent",
            "bridge": "connected",
            "mcp": "http://127.0.0.1:3002/mcp",
        },
    )
    assert cmd_isup(3002) == 0
    out = capsys.readouterr().out
    assert "up" in out
    assert "bridge=connected" in out


def test_stop_already_down(monkeypatch, capsys) -> None:
    monkeypatch.setattr("backend.cli.fetch_health", lambda port, timeout_s=1.5: None)
    monkeypatch.setattr("backend.cli.load_state", lambda: {})
    monkeypatch.setattr("backend.cli.pid_on_port", lambda port: None)
    monkeypatch.setattr("backend.cli.clear_state", lambda: None)
    assert cmd_stop(3002) == 0
    assert "already down" in capsys.readouterr().out


def test_start_already_running(monkeypatch, capsys) -> None:
    monkeypatch.setattr(
        "backend.cli.fetch_health",
        lambda port, timeout_s=1.5: {"product": "liveview-agent", "bridge": "waiting", "mcp": ""},
    )
    monkeypatch.setattr("backend.cli.load_state", lambda: {"game_dir": r"D:\SteamLibrary\steamapps\common\MonsterHunterWilds"})
    monkeypatch.setattr("backend.cli.resolve_game", lambda query: Path(r"D:\SteamLibrary\steamapps\common\MonsterHunterWilds"))
    assert cmd_start(3002, "MonsterHunterWilds") == 0
    assert "already running" in capsys.readouterr().out


def test_wait_for_ready(monkeypatch, capsys) -> None:
    hits = {"n": 0}

    def health(port: int, timeout_s: float = 1.5):
        hits["n"] += 1
        if hits["n"] < 3:
            return None
        return {"product": "liveview-agent", "bridge": "waiting"}

    class Proc:
        def poll(self):
            return None

    monkeypatch.setattr("backend.cli.fetch_health", health)
    monkeypatch.setattr("backend.cli.HEALTH_WAIT_S", 2)
    monkeypatch.setattr("backend.cli.time.sleep", lambda _s: None)
    body = wait_for_ready(3002, Proc())
    assert body["product"] == "liveview-agent"
    assert "waiting for" in capsys.readouterr().out


def test_parser_game_flag() -> None:
    args = build_parser().parse_args(["start", "-game", "MonsterHunterWilds"])
    assert args.cmd == "start"
    assert args.game == "MonsterHunterWilds"


def test_parser_install() -> None:
    args = build_parser().parse_args(["install"])
    assert args.cmd == "install"


def test_install_runs_pipx(monkeypatch, capsys, tmp_path: Path) -> None:
    calls: list[list[str]] = []

    def fake_run(cmd, check=False, capture_output=False):
        calls.append(list(cmd))
        return type("R", (), {"returncode": 0})()

    monkeypatch.setattr("backend.cli.ensure_pipx", lambda: ["pipx"])
    monkeypatch.setattr("backend.cli.subprocess.run", fake_run)
    monkeypatch.setattr("backend.cli.user_bin_dir", lambda: tmp_path)
    monkeypatch.setattr("backend.cli.repo_root", lambda: tmp_path / "repo")

    assert cmd_install() == 0
    assert calls[0][:2] == ["pipx", "ensurepath"]
    assert calls[1][:3] == ["pipx", "install", "--force"]
    assert "--editable" in calls[1]
    assert "installed" in capsys.readouterr().out
