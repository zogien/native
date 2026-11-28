"""Build and drive a real single-instance TypeScript app on macOS or Linux."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time


REPO = Path(__file__).resolve().parents[2]
CLI = REPO / "zig-out/bin/native"


def wait_for(check, process, timeout=30):
    deadline = time.monotonic() + timeout
    while not check():
        assert process.poll() is None, f"primary exited with {process.returncode}"
        assert time.monotonic() < deadline, "timed out waiting for the primary"
        time.sleep(0.05)


@contextlib.contextmanager
def primary(binary, cwd, env, *args):
    with subprocess.Popen([binary, *args], cwd=cwd, env=env) as process:
        try:
            yield process
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)


def secondary(binary, cwd, env, *args, expect=0):
    code = subprocess.run([binary, *args], cwd=cwd, env=env, timeout=15).returncode
    assert code == expect, f"expected exit {expect}, got {code}"


@contextlib.contextmanager
def separate_session(env):
    if sys.platform != "linux":
        yield env
        return
    # Two GTK primaries with the same bundle id need independent session buses.
    with subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1"],
                          stdout=subprocess.PIPE, text=True) as bus:
        try:
            address = bus.stdout.readline().strip()
            assert address, "private D-Bus session failed to start"
            yield dict(env, DBUS_SESSION_BUS_ADDRESS=address)
        finally:
            bus.terminate()


def exercise_routing(binary, work, *, distinct_runtime):
    work.mkdir()
    cwd = work / "caller"
    cwd.mkdir()
    logs = [work / "a.bin", work / "b.bin"]
    envs = []
    for name, log in zip(("a", "b"), logs):
        home = work / f"home-{name}"
        home.mkdir()
        runtime = work / (f"ipc-{name}" if distinct_runtime else "ipc")
        runtime.mkdir(mode=0o700, exist_ok=True)
        env = dict(os.environ, HOME=str(home), TMPDIR=str(runtime), XDG_RUNTIME_DIR=str(runtime),
                   LAUNCH_PROBE_LOG=str(log))
        env.pop("XDG_DATA_HOME", None)
        env.pop("NATIVE_SDK_DATA_DIR", None)
        if distinct_runtime:
            env["NATIVE_SDK_DATA_DIR"] = str(work / f"root-{name}")
        envs.append(env)

    def payload(arg):
        return os.fsencode(cwd.resolve()) + b"\0" + os.fsencode(arg)

    a, b = envs
    with primary(binary, work, a) as first:
        wait_for(logs[0].exists, first)
        assert any(Path(a["TMPDIR"]).glob("*.sock"))
        secondary(binary, cwd, a, "control-a")
        wait_for(lambda: logs[0].read_bytes() == payload("control-a"), first)
        with separate_session(b) as b, primary(binary, work, b) as second:
            wait_for(logs[1].exists, second)
            assert any(Path(b["TMPDIR"]).glob("*.sock"))
            secondary(binary, cwd, b, "control-b")
            wait_for(lambda: logs[1].read_bytes() == payload("control-b"), second)
            caller = dict(a, TMPDIR=b["TMPDIR"], XDG_RUNTIME_DIR=b["XDG_RUNTIME_DIR"])
            code = subprocess.run([binary, "intended-for-a"], cwd=cwd, env=caller, timeout=15).returncode
            if code == 0:
                wait_for(lambda: any(log.read_bytes() == payload("intended-for-a") for log in logs), first)
            observed = [log.read_bytes() for log in logs]
            print(f"{work.name}: exit={code}, A={observed[0]!r}, B={observed[1]!r}", flush=True)
            assert (code, observed) == (0, [payload("intended-for-a"), payload("control-b")])
            caller = dict(b, TMPDIR=a["TMPDIR"], XDG_RUNTIME_DIR=a["XDG_RUNTIME_DIR"])
            secondary(binary, cwd, caller, "intended-for-b")
            wait_for(lambda: logs[1].read_bytes() == payload("intended-for-b"), second)
            assert logs[0].read_bytes() == payload("intended-for-a")
            print(f"{work.name} reverse: exit=0, A={logs[0].read_bytes()!r}, B={logs[1].read_bytes()!r}", flush=True)
            assert first.poll() is None and second.poll() is None


def exercise(binary, work, bundle_id):
    runtime = work / "ipc"
    runtime.mkdir(mode=0o700)
    home = work / "home"
    home.mkdir()
    cwd = work / "second cwd"
    cwd.mkdir()
    log = work / "received.bin"
    env = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home / "data"),
               XDG_RUNTIME_DIR=str(runtime), TMPDIR=str(runtime), LAUNCH_PROBE_LOG=str(log))
    env.pop("NATIVE_SDK_DATA_DIR", None)
    data = (home / "Library/Application Support" if sys.platform == "darwin" else home / "data") / bundle_id
    with primary(binary, work, env) as owner:
        wait_for(log.exists, owner)
        secondary(binary, cwd, env, "--open", "two words", "")
        expected = os.fsencode(cwd.resolve()) + b"\0--open\0two words\0"
        wait_for(lambda: log.read_bytes() == expected, owner)
        print(f"default primary {owner.pid} received {expected!r}", flush=True)
        assert (data / ".native-sdk-instance.lock").is_file()
        sock, = runtime.glob("*.sock")
        assert stat.S_IMODE(sock.stat().st_mode) == 0o600
        assert stat.S_IMODE(runtime.stat().st_mode) == 0o700
        secondary(binary, cwd, env, "a" * 4097, expect=6)

    # SIGKILL leaves the socket behind and releases the kernel lock.
    assert owner.returncode == -signal.SIGKILL and sock.exists()
    log.unlink()
    with primary(binary, work, env) as replacement:
        wait_for(log.exists, replacement)
        secondary(binary, cwd, env, "recovered")
        wait_for(lambda: log.read_bytes().endswith(b"\0recovered"), replacement)

    root = work / ("profile" * 20)
    log.unlink()
    with primary(binary, work, env, "--native-data-dir", str(root)) as owner:
        wait_for(log.exists, owner)
        alias = str(root / ".." / root.name)
        secondary(binary, cwd, dict(env, NATIVE_SDK_DATA_DIR=alias), "via-env")
        wait_for(lambda: log.read_bytes().endswith(b"\0via-env"), owner)
        secondary(binary, cwd, env, "--native-data-dir", alias, "via-flag")
        wait_for(lambda: log.read_bytes() == os.fsencode(cwd.resolve()) + b"\0via-flag", owner)
        if sys.platform == "darwin":
            other_log = work / "other.bin"
            other_env = dict(env, LAUNCH_PROBE_LOG=str(other_log))
            with primary(binary, work, other_env, "--native-data-dir", str(work / "other")) as other:
                wait_for(other_log.exists, other)
                assert owner.poll() is None

    # Concurrent first opens of a previously absent lock file must converge
    # on one live primary. A burst can legitimately fill the core's queue.
    race_root = work / "concurrent"
    log.unlink()
    with contextlib.ExitStack() as stack:
        contenders = [stack.enter_context(primary(binary, work, env, "--native-data-dir",
                                                   str(race_root), str(i))) for i in range(12)]
        deadline = time.monotonic() + 15
        while sum(p.poll() is None for p in contenders) > 1 and time.monotonic() < deadline:
            time.sleep(0.02)
        codes = [p.poll() for p in contenders]
        assert codes.count(None) == 1 and all(c in (None, 0, 5) for c in codes), codes
        wait_for(log.exists, next(p for p in contenders if p.poll() is None))

    # The lock holder can exit between taking the lock and binding its socket.
    # An already-started secondary must then claim the directory itself.
    log.unlink()
    with (root / "data/.native-sdk-instance.lock").open("r+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with primary(binary, work, env, "--native-data-dir", str(root)) as waiting:
            time.sleep(0.25)
            assert waiting.poll() is None and not log.exists()
            fcntl.flock(lock, fcntl.LOCK_UN)
            wait_for(log.exists, waiting)
            secondary(binary, cwd, env, "--native-data-dir", str(root), "took-over")
            wait_for(lambda: log.read_bytes().endswith(b"\0took-over"), waiting)

    silent_env = env.copy()
    del silent_env["LAUNCH_PROBE_LOG"]
    # A fresh runtime directory makes the listener's publication observable.
    silent_runtime = work / "silent-ipc"
    silent_runtime.mkdir(mode=0o700)
    silent_env.update(TMPDIR=str(silent_runtime), XDG_RUNTIME_DIR=str(silent_runtime))
    with primary(binary, work, silent_env) as owner:
        wait_for(lambda: any(silent_runtime.glob("*.sock")), owner)
        start = time.monotonic()
        secondary(binary, cwd, silent_env, expect=4)
        elapsed = time.monotonic() - start
        assert 4.8 <= elapsed < 10, f"unexpected hold time {elapsed}"
        print(f"unopened source returned exit 4 after {elapsed:.2f}s", flush=True)


def main():
    subprocess.run(["zig", "build", "cli", "test-single-instance"], cwd=REPO, check=True)
    with tempfile.TemporaryDirectory(prefix="nsl-", dir="/tmp") as temp:
        work = Path(temp).resolve()
        subprocess.run([CLI, "init", "launch-probe", "--framework", REPO], cwd=work, check=True)
        app = work / "launch-probe"
        manifest = app / "app.json"
        config = json.loads(manifest.read_text())
        config["single_instance"] = True
        config["permissions"].append("filesystem")
        manifest.write_text(json.dumps(config))
        (app / "src/core.ts").write_bytes(Path(__file__).with_name("core.ts").read_bytes())
        (app / "src/app.native").write_text("<column><text>Launch probe</text></column>\n")
        subprocess.run([CLI, "build"], cwd=app, check=True)
        exercise(app / "zig-out/bin/launch-probe", work, config["id"])
        exercise_routing(app / "zig-out/bin/launch-probe", work / "different-runtime", distinct_runtime=True)
        exercise_routing(app / "zig-out/bin/launch-probe", work / "different-home", distinct_runtime=False)


if __name__ == "__main__":
    main()
