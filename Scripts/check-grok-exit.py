#!/usr/bin/env python3
"""Check normal app-exit cleanup with fake Grok processes; run with python3."""

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="codex-limits-grok-exit-") as temporary:
    work = Path(temporary)
    main = work / "main.swift"
    main.write_text("""import Darwin
import Foundation
@main struct ExitProbe {
    static func main() async {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let record = CommandLine.arguments[2]
        Task { _ = try? await GrokBillingClient().fetch(executableURL: executable) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: record)
            && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: record) else { exit(2) }
        exit(0)
    }
}
""")
    parent = work / "parent"
    subprocess.run([
        "/usr/bin/xcrun", "swiftc", "-parse-as-library",
        "-module-cache-path", str(work / "modules"),
        str(root / "Sources/CodexLimits/GrokBillingClient.swift"),
        str(main), "-o", str(parent),
    ], check=True, timeout=120)

    for mode in ("graceful", "forced"):
        record = work / f"{mode}.pids"
        fake = work / f"fake-{mode}"
        setup = "trap '' TERM\n" if mode == "forced" else ""
        cleanup = "" if mode == "forced" else (
            "trap 'kill \"$child\" 2>/dev/null; wait \"$child\" 2>/dev/null; exit 0' TERM\n"
        )
        fake.write_text(
            "#!/bin/sh\n" + setup + "/bin/sleep 60 &\nchild=$!\n" + cleanup
            + 'printf \'%s %s\\n\' "$$" "$child" > "$GROK_EXIT_CHECK_RECORD"\n'
            + 'wait "$child"\n'
        )
        fake.chmod(0o700)
        environment = {**os.environ, "GROK_EXIT_CHECK_RECORD": str(record)}
        process = subprocess.Popen(
            [str(parent), str(fake), str(record)], env=environment,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        started = time.monotonic()
        try:
            assert process.wait(timeout=5) == 0, f"{mode}: parent failed"
            elapsed = time.monotonic() - started
            assert elapsed < 3, f"{mode}: exit took {elapsed:.3f}s"
            pids = [int(value) for value in record.read_text().split()]
            assert len(pids) == 2, f"{mode}: missing fake process IDs"
            deadline = time.monotonic() + 1
            while any(alive(pid) for pid in pids) and time.monotonic() < deadline:
                time.sleep(0.01)
            assert not any(alive(pid) for pid in pids), f"{mode}: orphaned fake process"
            print(f"{mode}: normal exit in {elapsed:.3f}s; CLI and child absent")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if record.exists():
                recorded = [int(value) for value in record.read_text().split()]
                if any(alive(pid) for pid in recorded):
                    try:
                        os.killpg(recorded[0], signal.SIGKILL)
                    except ProcessLookupError:
                        pass
