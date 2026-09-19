#!/usr/bin/env python3
"""End-to-end smoke test for Atoll's LocalSend receiving side.

This is the re-runnable form of the checks that were done by hand while the
feature was built: it drives the real HTTP contract over a socket (chunked
framing included, because curl's own framing hid a bug once) and asserts the
protocol answers and the resulting files on disk.

    python3 tests/localsend_smoke.py                 # auto-detect the Debug build
    python3 tests/localsend_smoke.py --app /path/to/Atoll.app
    python3 tests/localsend_smoke.py --no-restart    # app already running

It toggles `localSendAutoAcceptIncoming` (the notch would otherwise wait for a
click), restarting the app for each phase, and always restores the setting and
the app afterwards. Only the files it creates are removed.

Exit code 0 means every case passed.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import plistlib
import socket
import subprocess
import sys
import time
import uuid

HOST = "127.0.0.1"
PORT = 53317
DOMAIN = "com.Ebullioscopic.Atoll.dev"  # the Debug build's bundle id
SETTING = "localSendAutoAcceptIncoming"
DOWNLOADS = os.path.expanduser("~/Downloads")

PASS, FAIL = "PASS", "FAIL"
results: list[tuple[str, str, str]] = []


# ---------------------------------------------------------------- app control


def find_app() -> str:
    pattern = os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/DynamicIsland-*/Build/Products/Debug/Atoll.app"
    )
    matches = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    if not matches:
        sys.exit("Could not find a Debug Atoll.app; pass --app <path>")
    return matches[0]


def app_pid() -> int | None:
    out = subprocess.run(["pgrep", "-x", "Atoll"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def restart_app(app: str) -> None:
    subprocess.run(["pkill", "-x", "Atoll"], capture_output=True)
    time.sleep(2)
    subprocess.run(["open", app], check=True)
    for _ in range(40):
        time.sleep(0.5)
        if listening():
            return
    sys.exit("The app did not start listening on 53317")


def set_auto_accept(enabled: bool) -> None:
    if enabled:
        subprocess.run(["defaults", "write", DOMAIN, SETTING, "-bool", "true"], check=True)
    else:
        subprocess.run(["defaults", "delete", DOMAIN, SETTING], capture_output=True)


def listening() -> bool:
    try:
        with socket.create_connection((HOST, PORT), timeout=1):
            return True
    except OSError:
        return False


# ------------------------------------------------------------- http over tcp


def http(head: bytes, body: bytes = b"", timeout: float = 30) -> tuple[int, bytes]:
    """Sends a raw request and returns (status, response body)."""
    with socket.create_connection((HOST, PORT), timeout=timeout) as sock:
        sock.sendall(head + body)
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = sock.recv(65536)
            if not chunk:
                break
            raw += chunk
        if not raw:
            return 0, b""
        head_bytes, _, rest = raw.partition(b"\r\n\r\n")
        status = int(head_bytes.split(b" ")[1])
        # Drain what the server is willing to send; it closes after answering.
        if b"Content-Length:" in head_bytes:
            length = int(head_bytes.split(b"Content-Length:")[1].split(b"\r\n")[0].strip())
            while len(rest) < length:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                rest += chunk
        return status, rest


def post(path: str, payload: dict | None = None, timeout: float = 30) -> tuple[int, bytes]:
    body = json.dumps(payload).encode() if payload is not None else b""
    head = (
        f"POST {path} HTTP/1.1\r\nHost: smoke\r\n"
        f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n"
    ).encode()
    return http(head, body, timeout)


def chunked_upload(session: str, file_id: str, token: str, data: bytes, timeout: float = 60) -> tuple[int, bytes]:
    frames = b"".join(
        b"%x\r\n" % len(part) + part + b"\r\n"
        for part in (data[i : i + 65536] for i in range(0, len(data), 65536))
    ) + b"0\r\n\r\n"
    target = f"/api/localsend/v2/upload?sessionId={session}&fileId={file_id}&token={token}"
    head = (
        f"POST {target} HTTP/1.1\r\nHost: smoke\r\n"
        f"Transfer-Encoding: chunked\r\n\r\n"
    ).encode()
    return http(head, frames, timeout)


def prepare(files: list[dict], alias: str = "smoke", timeout: float = 30) -> tuple[int, dict]:
    payload = {
        "info": {"alias": alias, "version": "2.2", "fingerprint": "smoke"},
        "files": {f["id"]: f for f in files},
    }
    status, body = post("/api/localsend/v2/prepare-upload", payload, timeout)
    try:
        return status, json.loads(body)
    except json.JSONDecodeError:
        return status, {}


def file_spec(name: str, data: bytes) -> dict:
    return {
        "id": uuid.uuid4().hex,
        "fileName": name,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def versioned(name: str) -> str:
    """A name unique to this run, so de-duplication cannot interfere."""
    stem, dot, ext = name.partition(".")
    return f"{stem}-{uuid.uuid4().hex[:8]}{dot}{ext}"


# ------------------------------------------------------------------- cases


def record(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, PASS if ok else FAIL, detail))
    print(f"  [{PASS if ok else FAIL}] {name}" + (f" — {detail}" if detail else ""))


def case_server_up() -> None:
    status, body = http(b"GET /api/localsend/v2/info HTTP/1.1\r\nHost: smoke\r\n\r\n")
    fingerprint = ""
    try:
        fingerprint = json.loads(body).get("fingerprint", "")
    except json.JSONDecodeError:
        pass
    record(
        "info answers with a certificate fingerprint",
        status == 200 and len(fingerprint) == 64 and fingerprint.upper() == fingerprint,
        f"status={status} fingerprint={fingerprint[:16]}…",
    )


def case_chunked_upload() -> None:
    data = bytes(range(256)) * 800
    name = versioned("smoke-upload.bin")
    status, session = prepare([file_spec(name, data)])
    if status != 200:
        return record("chunked upload stores the file", False, f"prepare={status}")
    up, _ = chunked_upload(session["sessionId"], list(session["files"])[0], session["files"][list(session["files"])[0]], data)
    landed = os.path.join(DOWNLOADS, name)
    identical = os.path.exists(landed) and hashlib.sha256(open(landed, "rb").read()).hexdigest() == hashlib.sha256(data).hexdigest()
    if os.path.exists(landed):
        os.remove(landed)
    record("chunked upload stores the file", up == 200 and identical, f"upload={up} identical={identical}")


def case_checksum_mismatch() -> None:
    data = b"mismatch"
    spec = file_spec(versioned("smoke-bad.bin"), data)
    spec["sha256"] = "deadbeef"
    status, session = prepare([spec])
    if status != 200:
        return record("a wrong checksum is rejected", False, f"prepare={status}")
    up, _ = chunked_upload(session["sessionId"], spec["id"], session["files"][spec["id"]], data)
    record("a wrong checksum is rejected", up == 422, f"upload={up}")
    post("/api/localsend/v2/cancel")


def case_overflow_frames() -> None:
    data = b"A" * 1024
    spec = file_spec(versioned("smoke-attack.bin"), data)
    status, session = prepare([spec])
    if status != 200:
        return record("a chunk of Int.max cannot crash the app", False, f"prepare={status}")
    frames = b"400\r\n" + data + b"\r\n7FFFFFFFFFFFFFFF\r\n" + b"B" * 64
    head = (
        f"POST /api/localsend/v2/upload?sessionId={session['sessionId']}&fileId={spec['id']}"
        f"&token={session['files'][spec['id']]} HTTP/1.1\r\nHost: smoke\r\n"
        f"Transfer-Encoding: chunked\r\n\r\n"
    ).encode()
    code, _ = http(head, frames, timeout=20)
    alive = app_pid() is not None
    record("a chunk of Int.max cannot crash the app", code == 400 and alive, f"status={code} alive={alive}")
    post("/api/localsend/v2/cancel")


def case_discovery_survives_an_upload() -> None:
    """register/info must answer while an upload is streaming (compat boundary)."""
    data = bytes(range(256)) * 400
    name = versioned("smoke-busy.bin")
    status, session = prepare([file_spec(name, data)])
    if status != 200:
        return record("register answers while an upload is in flight", False, f"prepare={status}")
    sock = socket.create_connection((HOST, PORT), timeout=30)
    file_id = list(session["files"])[0]
    target = f"/api/localsend/v2/upload?sessionId={session['sessionId']}&fileId={file_id}&token={session['files'][file_id]}"
    sock.sendall(f"POST {target} HTTP/1.1\r\nHost: smoke\r\nTransfer-Encoding: chunked\r\n\r\n".encode())
    sock.sendall(b"10000\r\n" + data[: len(data) // 2] + b"\r\n")  # half the file, then hold
    time.sleep(0.5)
    register = json.dumps({"alias": "smoke", "version": "2.2", "fingerprint": "probe"}).encode()
    reg_status, _ = http(
        f"POST /api/localsend/v2/register HTTP/1.1\r\nHost: smoke\r\nContent-Length: {len(register)}\r\n\r\n".encode(),
        register,
        timeout=10,
    )
    info_status, _ = http(b"GET /api/localsend/v2/info HTTP/1.1\r\nHost: smoke\r\n\r\n", timeout=10)
    sock.close()
    time.sleep(0.5)
    post("/api/localsend/v2/cancel")
    os.path.exists(os.path.join(DOWNLOADS, name)) and os.remove(os.path.join(DOWNLOADS, name))
    record(
        "register/info answer while an upload is in flight",
        reg_status == 200 and info_status == 200,
        f"register={reg_status} info={info_status}",
    )


def case_empty_files() -> None:
    status, _ = post("/api/localsend/v2/prepare-upload", {"info": {"alias": "smoke", "fingerprint": "smoke"}, "files": {}})
    record("an empty file map is a bad request", status == 400, f"status={status}")


def case_multi_file_with_one_failure() -> None:
    """A mixed session keeps the failed file's retry window, then frees the slot.

    The failed file stays for its retry window (ADR-0001 decision 4), so a fresh
    `prepare-upload` is refused straight away — but the slot must come back on its
    own, which is what used to leave the notch claiming to receive forever.
    """
    good = bytes(range(256)) * 400
    bad = file_spec(versioned("smoke-first-bad.bin"), b"bad")
    bad["sha256"] = "deadbeef"
    ok = file_spec(versioned("smoke-second-ok.bin"), good)
    status, session = prepare([bad, ok])
    if status != 200:
        return record("a mixed session frees its slot again", False, f"prepare={status}")
    first, _ = chunked_upload(session["sessionId"], bad["id"], session["files"][bad["id"]], b"bad")
    time.sleep(0.5)
    second, _ = chunked_upload(session["sessionId"], ok["id"], session["files"][ok["id"]], good)
    landed = os.path.join(DOWNLOADS, ok["fileName"])
    stored = os.path.exists(landed)
    if stored:
        os.remove(landed)

    immediate, _ = prepare([file_spec(versioned("smoke-probe.bin"), b"probe")], timeout=5)
    deadline = time.time() + 60
    released = False
    while time.time() < deadline:
        time.sleep(5)
        try:
            later, _ = prepare([file_spec(versioned("smoke-probe2.bin"), b"probe")], timeout=4)
        except socket.timeout:
            # A busy slot answers 409 immediately, so a timeout here cannot prove
            # anything: record it as unresolved rather than as success.
            later = 0
        if later == 200:
            released = True
            break
    post("/api/localsend/v2/cancel")
    record(
        "a mixed session frees its slot again",
        first == 422 and second == 200 and stored and immediate == 409 and released,
        f"first={first} second={second} stored={stored} immediate={immediate} released={released} last={later}",
    )


# -------------------------------------------------- phase 2: manual decisions


def case_peer_leaves_pending_decision() -> None:
    """A sender that gives up before accepting simply disconnects; the slot must free."""
    spec = file_spec(versioned("smoke-abandon.bin"), b"x")
    body = json.dumps({"info": {"alias": "smoke", "fingerprint": "smoke"}, "files": {spec["id"]: spec}}).encode()
    head = (
        f"POST /api/localsend/v2/prepare-upload HTTP/1.1\r\nHost: smoke\r\n"
        f"Content-Length: {len(body)}\r\n\r\n"
    ).encode()
    sock = socket.create_connection((HOST, PORT), timeout=10)
    sock.sendall(head + body)
    time.sleep(1.5)
    sock.close()  # the v2 sender cannot send /cancel before it knows the session id
    time.sleep(1.0)
    try:
        status, _ = prepare([file_spec(versioned("smoke-after-abandon.bin"), b"y")], timeout=4)
        freed = status == 200
    except socket.timeout:
        freed = True  # reached the decision state, so the slot was free
        post("/api/localsend/v2/cancel")
    record("a sender that leaves the decision frees the slot", freed)


def case_cancel_during_decision() -> None:
    spec = file_spec(versioned("smoke-cancel.bin"), b"x")
    payload = {"info": {"alias": "smoke", "fingerprint": "smoke"}, "files": {spec["id"]: spec}}
    body = json.dumps(payload).encode()
    head = (
        f"POST /api/localsend/v2/prepare-upload HTTP/1.1\r\nHost: smoke\r\n"
        f"Content-Length: {len(body)}\r\n\r\n"
    ).encode()
    sock = socket.create_connection((HOST, PORT), timeout=15)
    sock.sendall(head + body)
    time.sleep(1.0)
    cancel_status, _ = post("/api/localsend/v2/cancel")
    time.sleep(0.5)
    sock.settimeout(5)
    try:
        answered = sock.recv(4096).split(b"\r\n")[0].decode()
    except socket.timeout:
        answered = "<no answer>"
    sock.close()
    record(
        "cancelling during the decision answers 403 Cancelled by sender",
        cancel_status == 200 and "403" in answered,
        f"cancel={cancel_status} pending={answered}",
    )


# -------------------------------------------------------------------- runner


def run_phase(name: str, cases) -> None:
    print(f"\n{name}")
    for case in cases:
        try:
            case()
        except Exception as error:  # a broken case must not stop the rest
            record(getattr(case, "__name__", str(case)), False, f"raised {type(error).__name__}: {error}")
        time.sleep(0.3)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", help="path to Atoll.app (default: newest DerivedData Debug build)")
    parser.add_argument("--no-restart", action="store_true", help="assume the app is already running in the needed mode")
    args = parser.parse_args()

    app = args.app or find_app()
    print(f"app: {app}")
    previous = subprocess.run(["defaults", "read", DOMAIN, SETTING], capture_output=True, text=True).stdout.strip()

    try:
        if not args.no_restart:
            set_auto_accept(True)
            restart_app(app)
        run_phase(
            "auto-accept phase",
            [
                case_server_up,
                case_chunked_upload,
                case_checksum_mismatch,
                case_overflow_frames,
                case_empty_files,
                case_discovery_survives_an_upload,
                case_multi_file_with_one_failure,
            ],
        )

        if not args.no_restart:
            set_auto_accept(False)
            restart_app(app)
        run_phase("manual-decision phase", [case_peer_leaves_pending_decision, case_cancel_during_decision])
    finally:
        if not args.no_restart:
            if previous:
                subprocess.run(["defaults", "write", DOMAIN, SETTING, "-bool", previous], check=False)
            else:
                set_auto_accept(False)
            restart_app(app)

    failed = [name for name, outcome, _ in results if outcome == FAIL]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    for name, _, detail in results:
        if name in failed:
            print(f"  failed: {name} — {detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
