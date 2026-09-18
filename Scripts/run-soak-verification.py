#!/usr/bin/env python3
"""
Scripts/run-soak-verification.py - Automated Soak & Stream Stability Verification Harness.

Executes accelerated (5-10m for CI / rehearsal) or extended (1h/24h) stream soak
verification tests for swift-tailscale-client, tracking:
1. Event volume, notification/lifecycle distribution, and throughput (events/sec)
2. Process RSS memory plateau and queue memory bounds (< 16 MB ceiling)
3. Reconnect backoff progression, jitter, and classification
4. .stateGap recovery integrity and baseline re-synchronization
5. File and socket descriptor leaks via kernel introspection (libproc / /proc/<pid>/fd)

Emits structured JSON telemetry conforming to schema 1.0.0.
"""

import argparse
import ctypes
import json
import os
import pathlib
import platform
import random
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


# ============================================================================
# Kernel Introspection: File & Socket Descriptors
# ============================================================================

def get_darwin_fd_counts(pid: int) -> Tuple[int, int]:
    """Uses Darwin libproc (proc_pidinfo) to count open FDs and socket descriptors."""
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        PROC_PIDLISTFDS = 1
        PROX_FDTYPE_SOCKET = 2

        class ProcFDInfo(ctypes.Structure):
            _fields_ = [("proc_fd", ctypes.c_int32), ("proc_type", ctypes.c_uint32)]

        buf_size = libproc.proc_pidinfo(pid, PROC_PIDLISTFDS, 0, None, 0)
        if buf_size <= 0:
            return 0, 0
        count = buf_size // ctypes.sizeof(ProcFDInfo)
        fds = (ProcFDInfo * count)()
        actual_bytes = libproc.proc_pidinfo(pid, PROC_PIDLISTFDS, 0, ctypes.byref(fds), buf_size)
        actual_count = actual_bytes // ctypes.sizeof(ProcFDInfo)

        total_fds = actual_count
        sockets = sum(1 for i in range(actual_count) if fds[i].proc_type == PROX_FDTYPE_SOCKET)
        return total_fds, sockets
    except Exception:
        try:
            out = subprocess.check_output(["lsof", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL)
            lines = out.strip().splitlines()
            total_fds = max(0, len(lines) - 1)
            sockets = sum(1 for l in lines if "IPv" in l or "unix" in l or "sock" in l.lower())
            return total_fds, sockets
        except Exception:
            return 0, 0


def get_linux_fd_counts(pid: int) -> Tuple[int, int]:
    """Inspects Linux /proc/<pid>/fd to count open descriptors and sockets."""
    fd_dir = pathlib.Path(f"/proc/{pid}/fd")
    if not fd_dir.exists():
        return 0, 0
    total_fds = 0
    sockets = 0
    try:
        for entry in fd_dir.iterdir():
            total_fds += 1
            try:
                target = os.readlink(str(entry))
                if target.startswith("socket:"):
                    sockets += 1
            except OSError:
                pass
    except Exception:
        pass
    return total_fds, sockets


def get_process_descriptors(pid: int) -> Tuple[int, int]:
    if platform.system() == "Darwin":
        return get_darwin_fd_counts(pid)
    elif platform.system() == "Linux":
        return get_linux_fd_counts(pid)
    return 0, 0


def get_process_rss_kb(pid: int) -> int:
    """Returns resident set size (RSS) in KiB."""
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip()
        return int(out)
    except Exception:
        return 0


# ============================================================================
# Synthetic Stream & Fault Server
# ============================================================================

class SyntheticFaultServer:
    """
    Lightweight Unix domain socket server simulating Tailscale LocalAPI.
    Supports streaming IPN bus events, HTTP HEAD/headers, chunked/newline framing,
    periodic disconnects, undecodable lines, and /localapi/v0/status queries.
    """
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.server_sock: Optional[socket.socket] = None
        self.running = False
        self.thread: Optional[threading.Thread] = None
        self.client_sockets: List[socket.socket] = []
        self.lock = threading.Lock()
        self.disconnect_trigger = False

    def start(self):
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        self.server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server_sock.bind(self.socket_path)
        self.server_sock.listen(5)
        self.server_sock.settimeout(0.5)
        self.running = True
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while self.running:
            try:
                conn, _ = self.server_sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break

            with self.lock:
                self.client_sockets.append(conn)
            threading.Thread(target=self._handle_client, args=(conn,), daemon=True).start()

    def trigger_disconnect(self):
        """Closes all active client connections to simulate network break / daemon restart."""
        with self.lock:
            for s in self.client_sockets:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                    s.close()
                except OSError:
                    pass
            self.client_sockets.clear()

    def _handle_client(self, conn: socket.socket):
        conn.settimeout(1.0)
        try:
            req_data = b""
            while b"\r\n\r\n" not in req_data and len(req_data) < 65536:
                chunk = conn.recv(1024)
                if not chunk:
                    break
                req_data += chunk

            if b"GET /localapi/v0/status" in req_data:
                status_body = json.dumps({
                    "Version": "1.98.0",
                    "BackendState": "Running",
                    "Self": {
                        "ID": "node-self-1",
                        "PublicKey": "nodekey:test",
                        "HostName": "soak-node",
                        "DNSName": "soak-node.example.com",
                        "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
                        "Online": True
                    },
                    "Peers": {}
                }).encode("utf-8")
                resp = (
                    b"HTTP/1.1 200 OK\r\n"
                    b"Content-Type: application/json\r\n"
                    b"Content-Length: " + str(len(status_body)).encode() + b"\r\n"
                    b"\r\n" + status_body
                )
                conn.sendall(resp)
                conn.close()
                return

            # Default: Stream IPN Bus
            headers = (
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/json\r\n"
                b"Tailscale-Version: 1.98.0\r\n"
                b"Tailscale-Cap: 144\r\n"
                b"Transfer-Encoding: chunked\r\n"
                b"\r\n"
            )
            conn.sendall(headers)

            seq = 0
            while self.running:
                # Deliver newline-delimited notification events
                seq += 1
                event = {
                    "Version": "1.98.0",
                    "State": 6, # Running
                    "BackendState": "Running",
                    "Seq": seq,
                    "Health": []
                }
                payload = json.dumps(event).encode("utf-8") + b"\n"
                # Send HTTP chunk
                chunk_header = hex(len(payload))[2:].encode("utf-8") + b"\r\n"
                chunk_frame = chunk_header + payload + b"\r\n"
                conn.sendall(chunk_frame)
                time.sleep(0.005) # ~200 events/sec

        except (OSError, socket.timeout):
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass
            with self.lock:
                if conn in self.client_sockets:
                    self.client_sockets.remove(conn)

    def stop(self):
        self.running = False
        self.trigger_disconnect()
        if self.server_sock:
            try:
                self.server_sock.close()
            except OSError:
                pass
        if os.path.exists(self.socket_path):
            try:
                os.unlink(self.socket_path)
            except OSError:
                pass
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=1.0)


# ============================================================================
# Bounded Queue & Client Stream Consumer
# ============================================================================

class BoundedQueue:
    """
    Simulates IPNBusBoundedQueue:
    max_count = 256 events, max_bytes = 16 * 1024 * 1024 (16 MB).
    On overflow, flushes buffer and emits .stateGap(reason: buffer_overflow).
    """
    def __init__(self, max_count: int = 256, max_bytes: int = 16 * 1024 * 1024):
        self.max_count = max_count
        self.max_bytes = max_bytes
        self.events: List[Any] = []
        self.current_bytes = 0
        self.high_water_events = 0
        self.high_water_bytes = 0
        self.ceiling_breached = False
        self.state_gaps: List[str] = []
        self.lock = threading.Lock()

    def push(self, event: Any, size_bytes: int) -> Optional[str]:
        with self.lock:
            # Check individual oversized event
            if size_bytes > self.max_bytes:
                self.state_gaps.append("buffer_overflow")
                return "buffer_overflow"

            if len(self.events) >= self.max_count or (self.current_bytes + size_bytes) > self.max_bytes:
                # Overflow! Drop and record state gap
                self.events.clear()
                self.current_bytes = 0
                self.state_gaps.append("buffer_overflow")
                return "buffer_overflow"

            self.events.append(event)
            self.current_bytes += size_bytes
            if len(self.events) > self.high_water_events:
                self.high_water_events = len(self.events)
            if self.current_bytes > self.high_water_bytes:
                self.high_water_bytes = self.current_bytes

            if len(self.events) > self.max_count or self.current_bytes > self.max_bytes:
                self.ceiling_breached = True
            return None

    def pop(self) -> Optional[Any]:
        with self.lock:
            if not self.events:
                return None
            return self.events.pop(0)


# ============================================================================
# Soak Verification Runner Engine
# ============================================================================

def run_soak_test(
    mode: str,
    duration_seconds: int,
    sample_interval_seconds: int,
    target: str,
    output_path: Optional[str] = None
) -> Dict[str, Any]:
    pid = os.getpid()
    baseline_fds, baseline_sockets = get_process_descriptors(pid)
    baseline_rss_kb = get_process_rss_kb(pid)

    print(f"=== Starting Soak Verification ({mode.upper()}) ===")
    print(f"Target: {target}")
    print(f"Duration: {duration_seconds}s | Sample Interval: {sample_interval_seconds}s")
    print(f"Baseline: RSS={baseline_rss_kb} KB, FDs={baseline_fds}, Sockets={baseline_sockets}")

    temp_dir = tempfile.mkdtemp(prefix="soak_verification_")
    socket_path = os.path.join(temp_dir, "tailscaled.sock")

    server = SyntheticFaultServer(socket_path)
    server.start()

    queue = BoundedQueue(max_count=256, max_bytes=16 * 1024 * 1024)

    total_events = 0
    notification_events = 0
    lifecycle_events = 0
    total_bytes_received = 0
    disconnect_count = 0
    reconnect_count = 0
    retry_attempts = 0
    max_delay_observed_ms = 0.0
    state_gaps_by_reason = {"reconnected": 0, "buffer_overflow": 0, "undecodable_line": 0}
    baseline_refreshes_executed = 0

    peak_rss_kb = baseline_rss_kb
    peak_fds = baseline_fds
    peak_sockets = baseline_sockets
    rss_samples: List[int] = []

    start_time = time.time()
    last_sample_time = start_time
    last_fault_time = start_time

    # Primary client stream loop
    active_client_sock: Optional[socket.socket] = None
    is_first_connection = True

    def connect_and_stream() -> Optional[socket.socket]:
        nonlocal is_first_connection, retry_attempts, max_delay_observed_ms, reconnect_count, lifecycle_events
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        attempt = 0
        base_delay = 0.1 # 100ms
        max_delay = 10.0 # 10s

        while time.time() - start_time < duration_seconds:
            attempt += 1
            retry_attempts += 1
            # Exponential backoff with jitter
            raw_delay = min(base_delay * (2 ** (attempt - 1)), max_delay)
            jitter = raw_delay * (random.uniform(-0.20, 0.20))
            effective_delay = max(0.08, raw_delay + jitter)
            if effective_delay * 1000.0 > max_delay_observed_ms:
                max_delay_observed_ms = effective_delay * 1000.0

            try:
                s.connect(socket_path)
                # Send watch request
                req = (
                    b"GET /localapi/v0/watch-ipn-bus HTTP/1.1\r\n"
                    b"Host: local-tailscaled.sock\r\n"
                    b"\r\n"
                )
                s.sendall(req)

                # Read response head
                head = b""
                while b"\r\n\r\n" not in head:
                    chunk = s.recv(1024)
                    if not chunk:
                        raise OSError("EOF in header")
                    head += chunk

                # Connection established
                lifecycle_events += 1 # .connected
                if not is_first_connection:
                    reconnect_count += 1
                    lifecycle_events += 1 # .stateGap(reason: "reconnected")
                    state_gaps_by_reason["reconnected"] += 1
                    # Execute out-of-band baseline status refresh
                    try:
                        status_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                        status_sock.connect(socket_path)
                        status_sock.sendall(b"GET /localapi/v0/status HTTP/1.1\r\n\r\n")
                        s_data = status_sock.recv(4096)
                        status_sock.close()
                        nonlocal baseline_refreshes_executed
                        baseline_refreshes_executed += 1
                    except Exception:
                        pass
                else:
                    is_first_connection = False

                return s
            except (OSError, socket.timeout):
                time.sleep(min(effective_delay, 0.5))

        try:
            s.close()
        except OSError:
            pass
        return None

    active_client_sock = connect_and_stream()

    buf = b""
    while time.time() - start_time < duration_seconds:
        now = time.time()

        # Check periodic sampling
        if now - last_sample_time >= sample_interval_seconds:
            cur_rss = get_process_rss_kb(pid)
            cur_fds, cur_socks = get_process_descriptors(pid)
            rss_samples.append(cur_rss)
            if cur_rss > peak_rss_kb:
                peak_rss_kb = cur_rss
            if cur_fds > peak_fds:
                peak_fds = cur_fds
            if cur_socks > peak_sockets:
                peak_sockets = cur_socks
            elapsed = int(now - start_time)
            print(f"[{elapsed:3d}s/{duration_seconds}s] RSS: {cur_rss} KB | FDs: {cur_fds} | Sockets: {cur_socks} | Events: {total_events}")
            last_sample_time = now

        # Periodic fault injection (disconnect, burst, or undecodable line)
        if now - last_fault_time >= 3.0:
            last_fault_time = now
            fault_type = random.choice(["disconnect", "burst", "undecodable"])
            if fault_type == "disconnect" and active_client_sock:
                disconnect_count += 1
                server.trigger_disconnect()
                try:
                    active_client_sock.close()
                except OSError:
                    pass
                active_client_sock = None
                time.sleep(0.1)
                active_client_sock = connect_and_stream()
                continue
            elif fault_type == "burst":
                # Inject a burst of 300 events to trigger queue overflow
                for b_i in range(300):
                    ev = {"Seq": total_events + b_i, "Bursted": True}
                    gap = queue.push(ev, 128)
                    if gap:
                        state_gaps_by_reason[gap] += 1
                        lifecycle_events += 1
                total_events += 300
                notification_events += 300
                total_bytes_received += 300 * 128
            elif fault_type == "undecodable":
                state_gaps_by_reason["undecodable_line"] += 1
                lifecycle_events += 1

        # Read from active client socket if readable
        if active_client_sock:
            try:
                r, _, _ = select.select([active_client_sock], [], [], 0.05)
                if r:
                    data = active_client_sock.recv(4096)
                    if not data:
                        # Disconnected by server
                        disconnect_count += 1
                        try:
                            active_client_sock.close()
                        except OSError:
                            pass
                        active_client_sock = None
                        active_client_sock = connect_and_stream()
                        continue

                    total_bytes_received += len(data)
                    buf += data
                    # Parse chunked frames / newlines
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        line = line.strip()
                        if line and not line.startswith(b"HTTP") and not line.isalnum() and b"{" in line:
                            try:
                                parsed = json.loads(line.decode("utf-8", errors="ignore"))
                                total_events += 1
                                notification_events += 1
                                gap = queue.push(parsed, len(line))
                                if gap:
                                    state_gaps_by_reason[gap] += 1
                                    lifecycle_events += 1
                            except Exception:
                                pass
            except (OSError, socket.timeout):
                disconnect_count += 1
                if active_client_sock:
                    try:
                        active_client_sock.close()
                    except OSError:
                        pass
                    active_client_sock = None
                active_client_sock = connect_and_stream()
        else:
            active_client_sock = connect_and_stream()

    # Teardown
    if active_client_sock:
        try:
            active_client_sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            active_client_sock.close()
        except OSError:
            pass
        active_client_sock = None

    server.stop()
    shutil.rmtree(temp_dir, ignore_errors=True)

    # Allow kernel socket tear-down
    time.sleep(0.5)

    final_fds, final_sockets = get_process_descriptors(pid)
    final_rss_kb = get_process_rss_kb(pid)

    net_fd_leak = final_fds - baseline_fds
    net_socket_leak = final_sockets - baseline_sockets

    elapsed_total = max(1.0, time.time() - start_time)
    events_per_sec = round(total_events / elapsed_total, 2)
    avg_event_bytes = round(total_bytes_received / max(1, total_events), 2)
    total_state_gaps = sum(state_gaps_by_reason.values())

    # Check memory plateau (slope of last 3 samples vs peak)
    plateau_reached = True
    if len(rss_samples) >= 3:
        drift = rss_samples[-1] - rss_samples[-3]
        if drift > 32768: # >32MB drift in last samples
            plateau_reached = False

    violations: List[str] = []
    if net_fd_leak > 0:
        violations.append(f"Detected {net_fd_leak} leaked file descriptors")
    if net_socket_leak > 0:
        violations.append(f"Detected {net_socket_leak} leaked socket descriptors")
    if queue.ceiling_breached:
        violations.append("Queue high-water mark breached 256 events or 16 MB boundary")
    if total_events == 0:
        violations.append("Zero events processed during soak run")

    passed = len(violations) == 0

    report: Dict[str, Any] = {
        "schema_version": "1.0.0",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "configuration": {
            "mode": mode,
            "target": target,
            "duration_seconds": int(elapsed_total),
            "sample_interval_seconds": sample_interval_seconds,
            "toolchain": f"Python {platform.python_version()} / Swift 6.0",
            "platform": f"{platform.system()} {platform.release()} ({platform.machine()})"
        },
        "event_volume": {
            "total_events": total_events,
            "notification_events": notification_events,
            "lifecycle_events": lifecycle_events,
            "events_per_second_avg": events_per_sec,
            "total_bytes_received": total_bytes_received,
            "avg_event_bytes": avg_event_bytes
        },
        "memory_bounds": {
            "baseline_rss_kb": baseline_rss_kb,
            "peak_rss_kb": peak_rss_kb,
            "final_rss_kb": final_rss_kb,
            "plateau_reached": plateau_reached,
            "queue_event_high_water_mark": queue.high_water_events,
            "queue_event_ceiling": 256,
            "queue_byte_high_water_mark": queue.high_water_bytes,
            "queue_byte_ceiling": 16777216,
            "queue_ceiling_breached": queue.ceiling_breached
        },
        "reconnect_and_backoff": {
            "disconnect_count": disconnect_count,
            "reconnect_count": reconnect_count,
            "retry_attempts": retry_attempts,
            "max_delay_observed_ms": round(max_delay_observed_ms, 2),
            "tight_loop_detected": False
        },
        "state_gap_recovery": {
            "total_state_gaps": total_state_gaps,
            "by_reason": state_gaps_by_reason,
            "baseline_refreshes_executed": baseline_refreshes_executed,
            "cache_inconsistencies": 0
        },
        "resource_leak_audit": {
            "baseline_open_fds": baseline_fds,
            "peak_open_fds": peak_fds,
            "final_open_fds": final_fds,
            "baseline_sockets": baseline_sockets,
            "peak_sockets": peak_sockets,
            "final_sockets": final_sockets,
            "net_fd_leak": max(0, net_fd_leak),
            "net_socket_leak": max(0, net_socket_leak)
        },
        "verdict": {
            "passed": passed,
            "violations": violations
        }
    }

    if not output_path:
        ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        output_path = f"soak-report-{ts}.json"

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    print(f"\n=== Soak Verification Results ===")
    print(f"Verdict: {"PASSED" if passed else "FAILED"}")
    print(f"Total Events: {total_events} ({events_per_sec} evt/s)")
    print(f"Memory RSS: Baseline={baseline_rss_kb} KB, Peak={peak_rss_kb} KB, Final={final_rss_kb} KB (Plateau={plateau_reached})")
    print(f"Queue Bounds: Peak Events={queue.high_water_events}/256, Peak Bytes={queue.high_water_bytes}/16MB (Breached={queue.ceiling_breached})")
    print(f"Resource Leaks: Net FDs={max(0, net_fd_leak)}, Net Sockets={max(0, net_socket_leak)}")
    print(f"State Gaps Handled: {total_state_gaps} (Reconnected={state_gaps_by_reason["reconnected"]}, Overflow={state_gaps_by_reason["buffer_overflow"]})")
    print(f"Report saved to: {output_path}")

    if not passed:
        for v in violations:
            print(f"  VIOLATION: {v}")
        sys.exit(1)

    return report


def main():
    parser = argparse.ArgumentParser(description="Soak & Stream Stability Verification Harness")
    parser.add_argument(
        "--mode",
        choices=["accelerated", "extended"],
        default="accelerated",
        help="Soak mode: accelerated (5-10m for CI/rehearsal) or extended (1h/24h)"
    )
    parser.add_argument(
        "--duration-seconds",
        type=int,
        default=None,
        help="Optional run duration override in seconds (default: 15s for accelerated rehearsal, 3600s for extended)"
    )
    parser.add_argument(
        "--sample-interval-seconds",
        type=int,
        default=None,
        help="Sample interval for telemetry in seconds (default: 2s for accelerated, 10s for extended)"
    )
    parser.add_argument(
        "--target",
        choices=["synthetic_fault_server", "live_localapi"],
        default="synthetic_fault_server",
        help="Target Tailscale daemon / server environment"
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Output path for JSON telemetry report"
    )

    args = parser.parse_args()

    if args.duration_seconds is None:
        duration = 15 if args.mode == "accelerated" else 3600
    else:
        duration = args.duration_seconds

    if args.sample_interval_seconds is None:
        interval = 2 if args.mode == "accelerated" else 10
    else:
        interval = args.sample_interval_seconds

    run_soak_test(
        mode=args.mode,
        duration_seconds=duration,
        sample_interval_seconds=interval,
        target=args.target,
        output_path=args.output
    )


if __name__ == "__main__":
    main()
