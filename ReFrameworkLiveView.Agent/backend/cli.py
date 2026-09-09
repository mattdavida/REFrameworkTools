"""
liveview-agent start | stop | isup

Process manager for the sidecar on 3002. Does not import backend.config
(Azure fail-fast). start always launches uvicorn from this repo.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from backend.steam import GameNotFound, resolve_game

DEFAULT_PORT = 3002
PRODUCT = "liveview-agent"
HEALTH_WAIT_S = 20.0
_SPIN = "|/-\\"


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def state_dir() -> Path:
    override = os.environ.get("LIVEVIEW_AGENT_STATE_DIR")
    if override:
        return Path(override)
    if os.environ.get("LOCALAPPDATA"):
        return Path(os.environ["LOCALAPPDATA"]) / "liveview-agent"
    return Path.home() / ".local" / "share" / "liveview-agent"


def state_path() -> Path:
    return state_dir() / "agent.json"


def log_path() -> Path:
    return state_dir() / "agent.log"


def read_dotenv(root: Path) -> dict[str, str]:
    path = root / ".env"
    if not path.is_file():
        return {}
    try:
        from dotenv import dotenv_values
    except ImportError:
        return _parse_env_file(path)
    values = dotenv_values(path)
    return {k: v for k, v in values.items() if k and v is not None}


def _parse_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value.strip().strip('"').strip("'")
    return out


def default_port(root: Path | None = None) -> int:
    env_port = os.environ.get("API_PORT")
    if env_port:
        try:
            return int(env_port)
        except ValueError:
            pass
    values = read_dotenv(root or repo_root())
    raw = values.get("API_PORT", str(DEFAULT_PORT))
    try:
        return int(raw)
    except ValueError:
        return DEFAULT_PORT


def health_url(port: int) -> str:
    return f"http://127.0.0.1:{port}/api/health"


def fetch_health(port: int, timeout_s: float = 1.5) -> dict[str, Any] | None:
    req = urllib.request.Request(health_url(port), method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None
    return body if isinstance(body, dict) else None


def is_ours(body: dict[str, Any] | None) -> bool:
    return bool(body) and body.get("product") == PRODUCT


def _stdout_tty() -> bool:
    return hasattr(sys.stdout, "isatty") and sys.stdout.isatty()


_VT_ENABLED = False


def _enable_windows_color() -> None:
    global _VT_ENABLED
    if _VT_ENABLED or sys.platform != "win32":
        return
    try:
        import ctypes

        handle = ctypes.windll.kernel32.GetStdHandle(-11)
        mode = ctypes.c_uint32()
        if ctypes.windll.kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            ctypes.windll.kernel32.SetConsoleMode(handle, mode.value | 0x0004)
        _VT_ENABLED = True
    except (AttributeError, OSError):
        return


def use_color() -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR"):
        _enable_windows_color()
        return True
    if not _stdout_tty():
        return False
    _enable_windows_color()
    return True


def paint(code: str, text: str) -> str:
    if not use_color():
        return text
    return f"\033[{code}m{text}\033[0m"


def dim(text: str) -> str:
    return paint("2", text)


def _tag(kind: str) -> str:
    labels = {
        "info": ("36", "info"),
        "ok": ("32", "ok"),
        "warn": ("33", "warn"),
        "err": ("31", "err"),
    }
    code, label = labels[kind]
    return paint(code, f"{label:4}")


def say(kind: str, message: str, *, err: bool = False) -> None:
    stream = sys.stderr if err else sys.stdout
    print(f"{_tag(kind)}  {message}", file=stream, flush=True)


def note(message: str) -> None:
    print(f"      {dim(message)}", flush=True)


def bridge_text(state: str) -> str:
    if state == "connected":
        return paint("32", state)
    if state in {"waiting", "stale"}:
        return paint("33", state)
    return paint("31", state)


def _spin_update(text: str) -> None:
    if not _stdout_tty():
        return
    sys.stdout.write(f"\r\033[K{text}")
    sys.stdout.flush()


def _spin_clear() -> None:
    if not _stdout_tty():
        return
    sys.stdout.write("\r\033[K")
    sys.stdout.flush()


def wait_for_ready(port: int, proc: subprocess.Popen[Any] | None) -> dict[str, Any] | None:
    started = time.time()
    deadline = started + HEALTH_WAIT_S
    ready: dict[str, Any] | None = None
    frame = 0
    tty = _stdout_tty()
    if not tty:
        say("info", f"waiting for {health_url(port)}")
    while time.time() < deadline:
        if proc is not None and proc.poll() is not None:
            break
        ready = fetch_health(port)
        if is_ours(ready):
            break
        if tty:
            elapsed = time.time() - started
            glyph = paint("36", _SPIN[frame % len(_SPIN)])
            _spin_update(
                f"{glyph} {paint('36', 'waiting')} for health on {port}  {dim(f'{elapsed:.1f}s')}"
            )
            frame += 1
        time.sleep(0.12)
    _spin_clear()
    return ready


def load_state() -> dict[str, Any]:
    path = state_path()
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def save_state(payload: dict[str, Any]) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def clear_state() -> None:
    path = state_path()
    try:
        path.unlink(missing_ok=True)
    except OSError:
        pass


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if sys.platform == "win32":
        result = subprocess.run(
            ["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            check=False,
        )
        return str(pid) in (result.stdout or "")
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def pid_on_port(port: int) -> int | None:
    result = subprocess.run(
        ["netstat", "-ano", "-p", "TCP"],
        capture_output=True,
        text=True,
        check=False,
    )
    needle = f":{port}"
    for line in (result.stdout or "").splitlines():
        if "LISTENING" not in line.upper() or needle not in line:
            continue
        parts = line.split()
        if not parts:
            continue
        try:
            pid = int(parts[-1])
        except ValueError:
            continue
        local = parts[1] if len(parts) > 1 else ""
        if local.endswith(needle) or f"]{needle}" in local:
            return pid
    return None


def kill_pid(pid: int) -> None:
    if pid <= 0:
        return
    if sys.platform == "win32":
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            capture_output=True,
            check=False,
        )
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return
    deadline = time.time() + 5
    while time.time() < deadline and pid_alive(pid):
        time.sleep(0.1)
    if pid_alive(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


def cmd_isup(port: int) -> int:
    body = fetch_health(port)
    if not is_ours(body):
        say("err", "down", err=False)
        note(f"nothing on {port}")
        return 1
    assert body is not None
    bridge = str(body.get("bridge", "unknown"))
    mcp = body.get("mcp", "")
    say("ok", f"up  bridge={bridge_text(bridge)}  mcp={mcp}")
    return 0


def cmd_stop(port: int) -> int:
    body = fetch_health(port)
    state = load_state()
    pids: list[int] = []
    for raw in (state.get("pid"), pid_on_port(port)):
        if isinstance(raw, int) and raw > 0 and raw not in pids:
            pids.append(raw)
        elif isinstance(raw, str) and raw.isdigit():
            num = int(raw)
            if num > 0 and num not in pids:
                pids.append(num)
    if not pids and not is_ours(body):
        say("info", "already down")
        clear_state()
        return 0
    for pid in pids:
        kill_pid(pid)
    deadline = time.time() + 8
    while time.time() < deadline:
        if fetch_health(port) is None:
            break
        time.sleep(0.15)
    clear_state()
    if is_ours(fetch_health(port)):
        say("err", f"stop failed — still answering on {port}", err=True)
        return 1
    say("ok", "stopped")
    return 0


def cmd_start(port: int, game: str | None) -> int:
    root = repo_root()
    body = fetch_health(port)
    if is_ours(body):
        game_dir = None
        if game:
            try:
                game_dir = resolve_game(game)
            except GameNotFound as exc:
                say("err", str(exc), err=True)
                return 1
        state = load_state()
        current = state.get("game_dir")
        if game_dir and current and Path(str(current)) != game_dir:
            say(
                "warn",
                f"already running on {port} for {current}. "
                f"stop first to switch to {game_dir}",
                err=True,
            )
            return 1
        say("ok", f"already running on {port}")
        cmd_isup(port)
        return 0

    game_dir: Path | None = None
    if game:
        say("info", f"resolving {game}")
        try:
            game_dir = resolve_game(game)
        except GameNotFound as exc:
            say("err", str(exc), err=True)
            return 1

    where = game_dir or read_dotenv(root).get("GAME_DIR") or "(GAME_DIR from .env)"
    say("info", f"starting on {port}")
    note(f"game  {where}")

    env = os.environ.copy()
    env.setdefault("PYTHONPATH", str(root))
    if game_dir:
        env["GAME_DIR"] = str(game_dir)
        env.pop("LIVEVIEW_BRIDGE_DIR", None)

    state_dir().mkdir(parents=True, exist_ok=True)
    log = log_path()
    cmd = [
        sys.executable,
        "-m",
        "uvicorn",
        "backend.main:app",
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
    ]
    popen_kw: dict[str, Any] = {
        "cwd": str(root),
        "env": env,
        "stdout": log.open("a", encoding="utf-8"),
        "stderr": subprocess.STDOUT,
    }
    if sys.platform == "win32":
        no_window = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        popen_kw["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | no_window
    else:
        popen_kw["start_new_session"] = True

    proc = subprocess.Popen(cmd, **popen_kw)
    popen_kw["stdout"].close()

    ready = wait_for_ready(port, proc)

    if not is_ours(ready):
        if proc.poll() is None:
            kill_pid(proc.pid)
        say(
            "err",
            f"start failed — no {PRODUCT} on {health_url(port)}",
            err=True,
        )
        note(f"log  {log}")
        return 1

    save_state(
        {
            "pid": proc.pid,
            "port": port,
            "game_dir": str(game_dir) if game_dir else read_dotenv(root).get("GAME_DIR"),
        }
    )
    where = game_dir or read_dotenv(root).get("GAME_DIR") or "(GAME_DIR from .env)"
    say("ok", f"started on {port}")
    note(f"game  {where}")
    cmd_isup(port)
    return 0


def user_bin_dir() -> Path:
    if sys.platform == "win32":
        return Path.home() / ".local" / "bin"
    local = os.environ.get("XDG_BIN_HOME")
    if local:
        return Path(local)
    return Path.home() / ".local" / "bin"


def pipx_invocation() -> list[str] | None:
    found = shutil.which("pipx")
    if found:
        return [found]
    probe = subprocess.run(
        [sys.executable, "-m", "pipx", "--version"],
        capture_output=True,
        check=False,
    )
    if probe.returncode == 0:
        return [sys.executable, "-m", "pipx"]
    return None


def ensure_pipx() -> list[str]:
    existing = pipx_invocation()
    if existing:
        return existing
    say("info", "installing pipx")
    result = subprocess.run(
        [sys.executable, "-m", "pip", "install", "pipx"],
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("pip install pipx failed")
    again = pipx_invocation()
    if again:
        return again
    raise RuntimeError("pipx installed but is not callable. Open a new terminal and retry.")


def cmd_install() -> int:
    """Editable pipx install: one liveview-agent shim on PATH, isolated venv."""
    root = repo_root()
    try:
        pipx = ensure_pipx()
    except RuntimeError as exc:
        say("err", str(exc), err=True)
        return 1

    ensure = subprocess.run([*pipx, "ensurepath"], check=False)
    if ensure.returncode != 0:
        say("err", "pipx ensurepath failed", err=True)
        return ensure.returncode

    result = subprocess.run(
        [*pipx, "install", "--force", "--editable", str(root)],
        check=False,
    )
    if result.returncode != 0:
        say("err", "pipx install failed", err=True)
        return result.returncode

    shim = user_bin_dir() / ("liveview-agent.exe" if sys.platform == "win32" else "liveview-agent")
    say("ok", f"installed {shim}")
    note("that folder is the only PATH entry (not .venv\\Scripts)")
    note("open a new terminal if this one cannot find liveview-agent")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="liveview-agent",
        description="Start, stop, or check the Live View sidecar (port 3002).",
    )
    parser.add_argument("--port", type=int, default=None, help=f"default {DEFAULT_PORT}")
    sub = parser.add_subparsers(dest="cmd", required=True)

    start = sub.add_parser("start", help="Start uvicorn (no --reload)")
    start.add_argument(
        "-game",
        "--game",
        dest="game",
        help="Steam slug, app id, install folder name, or full path "
        "(example: MonsterHunterWilds)",
    )

    sub.add_parser("stop", help="Stop the sidecar on this port")
    sub.add_parser("isup", help="Exit 0 if this product answers /api/health")
    sub.add_parser(
        "install",
        help="Put liveview-agent on PATH (pipx, same idea as npm i -g)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.cmd == "install":
        return cmd_install()
    port = args.port if args.port is not None else default_port()
    if args.cmd == "start":
        return cmd_start(port, args.game)
    if args.cmd == "stop":
        return cmd_stop(port)
    if args.cmd == "isup":
        return cmd_isup(port)
    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
