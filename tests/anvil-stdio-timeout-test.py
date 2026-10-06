#!/usr/bin/env python3
"""Black-box contract checks for bounded anvil-stdio emacsclient calls."""
import argparse
import json
import os
import pathlib
import platform
import shutil
import signal
import subprocess
import tempfile
import time
from contextlib import contextmanager


def alive(pid):
    try:
        os.kill(pid, 0)
        stat_file = pathlib.Path(f"/proc/{pid}/stat")
        if stat_file.exists():
            # A zombie cannot retain descriptors or execute code.
            stat = stat_file.read_text().split()
            return len(stat) < 3 or stat[2] != "Z"
        ps = shutil.which("ps")
        if ps:
            result = subprocess.run([ps, "-o", "stat=", "-p", str(pid)],
                                    capture_output=True, text=True)
            if result.returncode != 0:
                return True
            state = result.stdout.strip()
            return not state.startswith("Z")
        return True
    except (ProcessLookupError, FileNotFoundError):
        return False
    except PermissionError:
        return True


def frame(body):
    return f"Content-Length: {len(body.encode())}\r\n\r\n{body}"


def request(method, ident=None):
    value = {"jsonrpc": "2.0", "method": method}
    if ident is not None:
        value["id"] = ident
    return json.dumps(value, separators=(",", ":"))


def check(ok, message):
    if not ok:
        raise AssertionError(message)


@contextmanager
def managed_tempdir(processes, pid_file):
    """Reap bridge groups and fake clients before TemporaryDirectory removes PID records."""
    with tempfile.TemporaryDirectory(prefix="anvil-stdio-timeout-") as td:
        root = pathlib.Path(td)
        try:
            yield root
        finally:
            for proc in processes:
                if proc.poll() is None:
                    try: os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            try:
                pids = map(int, pid_file[0].read_text().splitlines()) if pid_file[0] else ()
                for pid in pids:
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            except FileNotFoundError:
                pass
            for proc in processes:
                if proc.poll() is None:
                    try: proc.communicate(timeout=2)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        try: proc.communicate(timeout=1)
                        except subprocess.TimeoutExpired: pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True, type=pathlib.Path)
    ap.add_argument("--baseline", action="store_true")
    ap.add_argument("--force-cleanup-check", action="store_true")
    ap.add_argument("--backend", choices=("gnu", "perl"), default="gnu")
    args = ap.parse_args()
    script = args.script.resolve()
    timeout = shutil.which("timeout")
    if args.backend == "gnu":
        if platform.system() != "Linux" or not timeout:
            print("SKIP GNU timeout contract requires Linux coreutils")
            return
        version = subprocess.run([timeout, "--version"], capture_output=True, text=True).stdout
        if "GNU coreutils" not in version:
            print("SKIP GNU timeout contract requires Linux coreutils")
            return
    elif not shutil.which("perl"):
        print("SKIP Perl timeout contract requires Perl")
        return
    bash = shutil.which("bash")
    if not bash:
        raise RuntimeError("bash unavailable")
    passed = 0
    processes = []
    pid_file = [None]
    with managed_tempdir(processes, pid_file) as root:
        run_script = script
        if args.backend == "perl":
            run_script = root / "anvil-stdio-installed.sh"
            shutil.copy2(script, run_script)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        path_dir = bin_dir
        if args.backend == "perl":
            path_dir = root / "perl-path"
            path_dir.mkdir()
            for name in ("awk", "base64", "cut", "date", "dirname", "env", "grep", "head",
                         "perl", "ps", "python3", "rm", "sed", "sleep", "tr", "wc"):
                executable = shutil.which(name)
                if executable:
                    (path_dir / name).symlink_to(executable)
        state = root / "state"
        log = root / "calls.jsonl"
        pids = root / "pids"
        pid_file[0] = pids
        state.write_text("0")
        client = bin_dir / "emacsclient"
        client.write_text('''#!/usr/bin/env python3
import base64, json, os, pathlib, signal, sys, time
root = pathlib.Path(os.environ["CASE_ROOT"])
args = sys.argv[1:]
expr = args[args.index("-e") + 1]
if expr.startswith("(") and not "base64-decode-string" in expr:
    with (root / "calls.jsonl").open("a") as f: f.write(expr + "\\n")
    print("nil")
    raise SystemExit
encoded = expr.split('base64-decode-string "', 1)[1].split('"', 1)[0]
req = json.loads(base64.b64decode(encoded))
method = req["method"]
with (root / "calls.jsonl").open("a") as f: f.write(json.dumps(req) + "\\n")
if method == "hang":
    child = os.fork()
    if child == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGALRM, signal.SIG_IGN)
        with (root / "pids").open("a") as f: f.write(str(os.getpid()) + "\\n")
        while True: time.sleep(1)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGALRM, signal.SIG_IGN)
    with (root / "pids").open("a") as f: f.write(str(os.getpid()) + "\\n")
    while True: time.sleep(1)
if method == "orphan":
    read_fd, write_fd = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(read_fd)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with (root / "pids").open("a") as f: f.write(str(os.getpid()) + "\\n")
        os.write(write_fd, b"1")
        os.close(write_fd)
        while True: time.sleep(1)
    os.close(write_fd)
    os.read(read_fd, 1)
    os.close(read_fd)
if method == "retry":
    n = int((root / "state").read_text())
    (root / "state").write_text(str(n + 1))
    if n == 0:
        print("", file=sys.stderr); print("can't find socket", file=sys.stderr)
        raise SystemExit(1)
if method == "exhaust":
    print("can't find socket", file=sys.stderr)
    raise SystemExit(1)
if method == "immediate":
    print("elisp evaluation failed", file=sys.stderr)
    raise SystemExit(1)
if "id" not in req:
    print('""')
    raise SystemExit
body = {"jsonrpc":"2.0", "id":req.get("id"), "result":{"method":method}}
encoded = base64.b64encode(json.dumps(body, separators=(",", ":")).encode()).decode()
print('"' + encoded + '"')
''')
        client.chmod(0o755)
        env = os.environ.copy()
        path = str(bin_dir) + os.pathsep + str(path_dir)
        if args.backend == "gnu":
            path += os.pathsep + env.get("PATH", "")
        env.update(PATH=path,
                   CASE_ROOT=str(root), ANVIL_EMACSCLIENT_TIMEOUT="0.15",
                   ANVIL_EMACSCLIENT_RETRY_MAX="2", ANVIL_EMACSCLIENT_RETRY_DELAY_MS="0")

        def run(data, framed=False, timeout_value="0.15", init=False, force_fail=False):
            env["ANVIL_EMACSCLIENT_TIMEOUT"] = timeout_value
            cmd = [str(run_script)]
            if init:
                cmd += ["--init-function=init-fn", "--stop-function=stop-fn"]
            start = time.monotonic()
            proc = subprocess.Popen([bash] + cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=env, start_new_session=True)
            processes.append(proc)
            try:
                if force_fail:
                    proc.stdin.write(data)
                    proc.stdin.flush()
                    for _ in range(40):
                        if pids.exists() and len(pids.read_text().splitlines()) >= 2: break
                        time.sleep(0.05)
                    raise RuntimeError("injected harness failure")
                out, err = proc.communicate(data, timeout=6)
            except BaseException:
                try: os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                for pid in map(int, pids.read_text().splitlines()) if pids.exists() else ():
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                proc.communicate(timeout=2)
                raise
            return proc.returncode, out, err, time.monotonic() - start

        if args.force_cleanup_check:
            try:
                run((request("hang", 1) + "\n").encode(), force_fail=True)
            except RuntimeError as exc:
                check(str(exc) == "injected harness failure", "unexpected forced failure")
            else:
                raise AssertionError("forced harness failure did not occur")
            ids = list(map(int, pids.read_text().splitlines()))
            for _ in range(40):
                if all(not alive(pid) for pid in ids): break
                time.sleep(0.05)
            check(len(ids) == 2 and all(not alive(pid) for pid in ids),
                  f"forced failure leaked fake client process group: {[(pid, alive(pid)) for pid in ids]}")
            passed = 1
        elif args.baseline:
            # The pre-patch implementation must hang past the outer watchdog.
            data = (request("hang") + "\n" + request("after", 2) + "\n").encode()
            env["ANVIL_EMACSCLIENT_TIMEOUT"] = "1"
            proc = subprocess.Popen([bash, str(script)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=env, start_new_session=True)
            processes.append(proc)
            try:
                proc.communicate(data, timeout=3.5)
                raise AssertionError("baseline unexpectedly bounded TERM-resistant client")
            except subprocess.TimeoutExpired:
                try: os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                for pid in map(int, pids.read_text().splitlines()) if pids.exists() else ():
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                proc.communicate(timeout=2)
                ids = list(map(int, pids.read_text().splitlines())) if pids.exists() else []
                for _ in range(40):
                    if all(not alive(pid) for pid in ids): break
                    time.sleep(0.05)
                check(len(ids) == 2 and all(not alive(pid) for pid in ids),
                      f"baseline cleanup leaked client group: {[(pid, alive(pid)) for pid in ids]}")
            passed += 1
        else:
            # Timeout notification is silent; bridge remains usable, both wire modes.
            for framed in (False, True):
                previous_ids = len(pids.read_text().splitlines()) if pids.exists() else 0
                data = [request("hang", 1), request("hang"), request("after", 2)]
                wire = "".join(frame(x) if framed else x + "\n" for x in data).encode()
                rc, out, err, elapsed = run(wire, framed=framed)
                expected = {"jsonrpc":"2.0", "id":2, "result":{"method":"after"}}
                expected_body = json.dumps(expected, separators=(",", ":"))
                if framed:
                    header, rest = out.split(b"\r\n\r\n", 1)
                    failure_len = int(header.split(b":", 1)[1])
                    failure_body = rest[:failure_len]
                    next_frame = rest[failure_len:]
                    next_body = expected_body.encode()
                else:
                    next_frame = None
                    failure_body, next_body = out.splitlines()
                failure_obj = json.loads(failure_body)
                message = failure_obj.get("error", {}).get("message", "")
                check(failure_obj.get("id") == 1 and "Bridge synthetic error" in message and
                      message.endswith(("rc=124)", "rc=137)")),
                      f"timeout response mismatch: {failure_obj!r}")
                check(rc == 0 and next_body == expected_body.encode(),
                      f"framing/next request mismatch: {rc} {out!r} {err!r}")
                if framed:
                    check(next_frame == frame(expected_body).encode(),
                          f"next Content-Length frame mismatch: {next_frame!r}")
                check(1.0 <= elapsed < 4.0, f"unexpected timeout duration {elapsed:.2f}s")
                ids = list(map(int, pids.read_text().splitlines()))[previous_ids:]
                # Each hanging call and its same-group child must be gone.
                for _ in range(20):
                    if all(not alive(pid) for pid in ids): break
                    time.sleep(0.05)
                check(len(ids) == 4 and all(not alive(pid) for pid in ids),
                      f"TERM-resistant process survived: {[(pid, alive(pid)) for pid in ids]}")
                passed += 2
            if args.backend == "perl":
                # Fractional timeout above and integer timeout here both
                # bound a TERM and ALRM-resistant process group.
                previous_ids = len(pids.read_text().splitlines())
                rc, out, _, elapsed = run((request("hang", 8) + "\n").encode(), timeout_value="1")
                check(rc == 0 and b"Bridge synthetic error" in out and b"rc=124" in out,
                      "integer timeout response mismatch")
                check(1.8 <= elapsed < 4.0, f"integer timeout duration was {elapsed:.2f}s")
                ids = list(map(int, pids.read_text().splitlines()))[previous_ids:]
                check(len(ids) == 2 and all(not alive(pid) for pid in ids),
                      f"integer timeout leaked process group: {[(pid, alive(pid)) for pid in ids]}")
                passed += 2
                previous_ids = len(pids.read_text().splitlines())
                rc, out, _, elapsed = run((request("orphan", 9) + "\n" +
                                           request("after", 13) + "\n").encode())
                expected = [
                    {"jsonrpc": "2.0", "id": 9, "result": {"method": "orphan"}},
                    {"jsonrpc": "2.0", "id": 13, "result": {"method": "after"}},
                ]
                check(rc == 0 and [json.loads(x) for x in out.splitlines()] == expected
                      and elapsed < 3.0, "orphan response or subsequent request failed")
                ids = list(map(int, pids.read_text().splitlines()))[previous_ids:]
                check(len(ids) == 1 and all(not alive(pid) for pid in ids),
                      f"orphan holding stdout survived: {[(pid, alive(pid)) for pid in ids]}")
                passed += 2
            # Retry success, init/stop counts, and timeout=0 path.
            state.write_text("0")
            data = (request("retry", 3) + "\n" + request("plain", 4) + "\n").encode()
            rc, out, _, _ = run(data, init=True)
            check(rc == 0 and out.count(b'"id":3') == 1 and out.count(b'"id":4') == 1,
                  "retry/init/stop or ordinary success failed")
            calls = log.read_text().splitlines()
            check(sum("init-fn" in x for x in calls) == 1 and sum("stop-fn" in x for x in calls) == 1,
                  "init/stop call count mismatch")
            passed += 3
            # Exhausted socket retries stay bounded; non-socket errors are single-shot.
            before = len(calls)
            rc, out, _, _ = run((request("exhaust", 6) + "\n" + request("immediate", 7) + "\n" +
                                 request("notice") + "\n").encode())
            after_calls = log.read_text().splitlines()[before:]
            check(rc == 0 and b"Bridge synthetic error" in out and b'"id":7' in out,
                  "error classification output mismatch")
            check(sum('"method": "exhaust"' in x for x in after_calls) == 2 and
                  sum('"method": "immediate"' in x for x in after_calls) == 1 and
                  sum('"method": "notice"' in x for x in after_calls) == 1,
                  "retry exhaustion / immediate error / notification counts mismatch")
            passed += 2
            rc, out, _, _ = run((request("plain", 5) + "\n").encode(), timeout_value="0")
            check(rc == 0 and b'"id":5' in out, "timeout=0 bypass failed")
            passed += 1
            if args.backend == "perl":
                # Invalid timeout/backend setups fail before dispatching.
                call_count = len(log.read_text().splitlines())
                rc, out, _, _ = run((request("plain", 10) + "\n").encode(), timeout_value="1e2")
                check(rc == 0 and b"rc=69" in out and len(log.read_text().splitlines()) == call_count,
                      "malformed timeout was dispatched")
                passed += 1
                perl_link = path_dir / "perl"
                perl_link.unlink()
                call_count = len(log.read_text().splitlines())
                rc, out, _, _ = run((request("plain", 11) + "\n").encode(), timeout_value="1")
                check(rc == 0 and b"rc=69" in out and
                      len(log.read_text().splitlines()) == call_count,
                      "missing Perl timeout backend dispatched the client")
                passed += 1
                rc, out, _, _ = run((request("plain", 12) + "\n").encode(), timeout_value="0")
                check(rc == 0 and b'"id":12' in out and
                      len(log.read_text().splitlines()) == call_count + 1,
                      "timeout=0 did not bypass the missing supervisor")
                passed += 1
    print(f"PASS {passed} checks")


if __name__ == "__main__":
    main()
