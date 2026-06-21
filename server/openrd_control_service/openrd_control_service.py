#!/usr/bin/env python3
"""OpenRD minimal public control service.

This service intentionally uses only Python's standard library.  The first
deployment target is a small cloud VM and an RK3588 board that may not have pip.
Vehicle agents actively poll this cloud service, so the vehicle network never
needs an inbound port.
"""

from __future__ import annotations

import argparse
import json
import os
import threading
import time
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse


DEFAULT_VEHICLE_ID = os.environ.get("OPENRD_DEFAULT_VEHICLE_ID", "openrd-001")
DEFAULT_PLAY_URL = os.environ.get(
    "OPENRD_CONTROL_PLAY_URL",
    "http://43.139.25.165:8888/live/openrd.live.flv",
)
DEFAULT_RTSP_URL = os.environ.get(
    "OPENRD_CONTROL_RTSP_URL",
    "rtsp://43.139.25.165/live/openrd",
)
DEFAULT_RTMP_URL = os.environ.get(
    "OPENRD_CONTROL_RTMP_URL",
    "rtmp://43.139.25.165:1935/live/openrd",
)
VIEWER_TOKEN = os.environ.get("OPENRD_CONTROL_VIEWER_TOKEN", "")
AGENT_TOKEN = os.environ.get("OPENRD_CONTROL_AGENT_TOKEN", "")
ALLOW_ORIGIN = os.environ.get("OPENRD_CONTROL_ALLOW_ORIGIN", "*")
DEFAULT_TTL_SEC = int(os.environ.get("OPENRD_CONTROL_DEFAULT_TTL_SEC", "120"))
MAX_TTL_SEC = int(os.environ.get("OPENRD_CONTROL_MAX_TTL_SEC", "600"))
AGENT_TIMEOUT_SEC = int(os.environ.get("OPENRD_CONTROL_AGENT_TIMEOUT_SEC", "45"))
AGENT_POLL_WAIT_SEC = int(os.environ.get("OPENRD_CONTROL_AGENT_POLL_WAIT_SEC", "20"))


@dataclass
class VehicleState:
    vehicle_id: str
    last_agent_seen: float = 0.0
    agent_name: str = ""
    agent_version: str = ""
    video_status: dict[str, Any] = field(default_factory=dict)
    command_queue: list[dict[str, Any]] = field(default_factory=list)
    leases: dict[str, float] = field(default_factory=dict)
    last_result: dict[str, Any] = field(default_factory=dict)
    last_error: str = ""


STATE_LOCK = threading.RLock()
STATE_COND = threading.Condition(STATE_LOCK)
VEHICLES: dict[str, VehicleState] = {}


def now_ms() -> int:
    return int(time.time() * 1000)


def get_vehicle_locked(vehicle_id: str) -> VehicleState:
    vehicle = VEHICLES.get(vehicle_id)
    if vehicle is None:
        vehicle = VehicleState(vehicle_id=vehicle_id)
        VEHICLES[vehicle_id] = vehicle
    return vehicle


def clamp_ttl(value: Any) -> int:
    try:
        ttl = int(value)
    except (TypeError, ValueError):
        ttl = DEFAULT_TTL_SEC
    return max(30, min(ttl, MAX_TTL_SEC))


def agent_online_locked(vehicle: VehicleState) -> bool:
    return time.time() - vehicle.last_agent_seen <= AGENT_TIMEOUT_SEC


def video_state_locked(vehicle: VehicleState) -> str:
    if not agent_online_locked(vehicle):
        return "offline"

    state = str(vehicle.video_status.get("state", "") or "").lower()
    if state in {"running", "starting", "stopping", "stopped", "faulted"}:
        return state

    if vehicle.video_status.get("runtime_running") is True:
        return "running"
    if vehicle.video_status.get("service_active") is True:
        return "running"
    return "unknown" if vehicle.video_status else "stopped"


def max_lease_expires_locked(vehicle: VehicleState) -> float:
    return max(vehicle.leases.values(), default=0.0)


def lease_remaining_locked(vehicle: VehicleState) -> int:
    expires_at = max_lease_expires_locked(vehicle)
    if expires_at <= 0:
        return 0
    return max(0, int(expires_at - time.time()))


def has_pending_command_locked(vehicle: VehicleState, command_type: str) -> bool:
    return any(cmd.get("type") == command_type for cmd in vehicle.command_queue)


def enqueue_command_locked(
    vehicle: VehicleState,
    command_type: str,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    command = {
        "request_id": uuid.uuid4().hex,
        "type": command_type,
        "created_ms": now_ms(),
        **(payload or {}),
    }
    vehicle.command_queue.append(command)
    STATE_COND.notify_all()
    return command


def expire_leases_locked() -> None:
    current = time.time()
    for vehicle in VEHICLES.values():
        expired = [
            viewer_id
            for viewer_id, expires_at in vehicle.leases.items()
            if expires_at <= current
        ]
        for viewer_id in expired:
            vehicle.leases.pop(viewer_id, None)

        state = video_state_locked(vehicle)
        if (
            agent_online_locked(vehicle)
            and not vehicle.leases
            and state in {"running", "starting"}
            and not has_pending_command_locked(vehicle, "video.stop")
        ):
            enqueue_command_locked(
                vehicle,
                "video.stop",
                {"reason": "cloud_lease_expired", "lease_sec": 0},
            )


def snapshot_locked(vehicle: VehicleState) -> dict[str, Any]:
    state = video_state_locked(vehicle)
    service_active = bool(vehicle.video_status.get("service_active")) or state == "running"
    return {
        "ok": True,
        "vehicle_id": vehicle.vehicle_id,
        "vehicle_online": agent_online_locked(vehicle),
        "agent": vehicle.agent_name,
        "agent_version": vehicle.agent_version,
        "video_state": state,
        "service_active": service_active,
        "mode": vehicle.video_status.get("mode", "rtmp"),
        "play_url": vehicle.video_status.get("play_url") or DEFAULT_PLAY_URL,
        "rtsp_url": vehicle.video_status.get("rtsp_url") or DEFAULT_RTSP_URL,
        "rtmp_url": vehicle.video_status.get("rtmp_url") or DEFAULT_RTMP_URL,
        "lease_count": len(vehicle.leases),
        "lease_expires_in_sec": lease_remaining_locked(vehicle),
        "pending_commands": len(vehicle.command_queue),
        "last_agent_seen_ms": int(vehicle.last_agent_seen * 1000)
        if vehicle.last_agent_seen
        else 0,
        "last_error": vehicle.last_error
        or str(vehicle.video_status.get("last_error", "") or ""),
        "last_result": vehicle.last_result,
        "server_time_ms": now_ms(),
    }


def json_bytes(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class ControlHandler(BaseHTTPRequestHandler):
    server_version = "OpenRDControl/0.1"

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self._send_cors_headers()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path in {"/", "/health"}:
            self._send_json(
                200,
                {
                    "ok": True,
                    "service": "openrd-control-service",
                    "server_time_ms": now_ms(),
                },
            )
            return

        parts = self._path_parts()
        if self._is_vehicle_video_path(parts, "status"):
            if not self._auth_ok(VIEWER_TOKEN):
                self._send_json(401, {"ok": False, "error": "unauthorized"})
                return
            vehicle_id = parts[2]
            with STATE_COND:
                expire_leases_locked()
                vehicle = get_vehicle_locked(vehicle_id)
                payload = snapshot_locked(vehicle)
            self._send_json(200, payload)
            return

        self._send_json(404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:
        parts = self._path_parts()
        if parts == ["api", "agent", "poll"]:
            self._handle_agent_poll()
            return

        if len(parts) == 5 and parts[:2] == ["api", "vehicles"] and parts[3] == "video":
            action = parts[4]
            if action in {"start", "stop", "renew"}:
                self._handle_video_action(parts[2], action)
                return

        self._send_json(404, {"ok": False, "error": "not_found"})

    def log_message(self, fmt: str, *args: Any) -> None:
        print(
            f"{self.log_date_time_string()} {self.address_string()} {fmt % args}",
            flush=True,
        )

    def _handle_agent_poll(self) -> None:
        if not self._auth_ok(AGENT_TOKEN):
            self._send_json(401, {"ok": False, "error": "unauthorized"})
            return

        body = self._read_json()
        vehicle_id = str(body.get("vehicle_id") or DEFAULT_VEHICLE_ID)
        wait_sec = max(1, min(int(body.get("wait_sec") or AGENT_POLL_WAIT_SEC), 30))

        with STATE_COND:
            vehicle = get_vehicle_locked(vehicle_id)
            vehicle.last_agent_seen = time.time()
            vehicle.agent_name = str(body.get("agent") or vehicle.agent_name)
            vehicle.agent_version = str(body.get("version") or vehicle.agent_version)

            status = body.get("status")
            if isinstance(status, dict):
                vehicle.video_status = status
                vehicle.last_error = str(status.get("last_error", "") or "")

            result = body.get("result")
            if isinstance(result, dict) and result:
                vehicle.last_result = result
                if result.get("ok") is False:
                    vehicle.last_error = str(result.get("last_error", "") or "")

            expire_leases_locked()
            if not vehicle.command_queue:
                STATE_COND.wait(timeout=wait_sec)
                vehicle.last_agent_seen = time.time()
                expire_leases_locked()

            command = (
                vehicle.command_queue.pop(0)
                if vehicle.command_queue
                else {"type": "noop", "request_id": ""}
            )
            payload = {
                "ok": True,
                "command": command,
                "lease_expires_in_sec": lease_remaining_locked(vehicle),
                "server_time_ms": now_ms(),
            }

        self._send_json(200, payload)

    def _handle_video_action(self, vehicle_id: str, action: str) -> None:
        if not self._auth_ok(VIEWER_TOKEN):
            self._send_json(401, {"ok": False, "error": "unauthorized"})
            return

        body = self._read_json()
        viewer_id = str(body.get("viewer_id") or "default-viewer")
        ttl = clamp_ttl(body.get("ttl_sec"))

        with STATE_COND:
            expire_leases_locked()
            vehicle = get_vehicle_locked(vehicle_id)
            online = agent_online_locked(vehicle)

            if action in {"start", "renew"} and not online:
                payload = snapshot_locked(vehicle)
                payload.update({"ok": False, "error": "vehicle_offline"})
                self._send_json(409, payload)
                return

            if action == "start":
                vehicle.leases[viewer_id] = time.time() + ttl
                enqueue_command_locked(
                    vehicle,
                    "video.start",
                    {"viewer_id": viewer_id, "lease_sec": ttl, "stream": "openrd"},
                )
                payload = snapshot_locked(vehicle)
                payload.update({"accepted": True, "state": "starting"})
                self._send_json(202, payload)
                return

            if action == "renew":
                vehicle.leases[viewer_id] = time.time() + ttl
                enqueue_command_locked(
                    vehicle,
                    "video.renew",
                    {"viewer_id": viewer_id, "lease_sec": ttl, "stream": "openrd"},
                )
                self._send_json(200, snapshot_locked(vehicle))
                return

            force = bool(body.get("force"))
            if force or not viewer_id:
                vehicle.leases.clear()
            else:
                vehicle.leases.pop(viewer_id, None)
            if not vehicle.leases and online:
                enqueue_command_locked(
                    vehicle,
                    "video.stop",
                    {"viewer_id": viewer_id, "reason": "viewer_stop", "lease_sec": 0},
                )
            payload = snapshot_locked(vehicle)
            payload.update({"accepted": True, "state": "stopping"})
            self._send_json(202, payload)

    def _path_parts(self) -> list[str]:
        return [part for part in urlparse(self.path).path.split("/") if part]

    @staticmethod
    def _is_vehicle_video_path(parts: list[str], action: str) -> bool:
        return (
            len(parts) == 5
            and parts[:2] == ["api", "vehicles"]
            and parts[3] == "video"
            and parts[4] == action
        )

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return {}
        return parsed if isinstance(parsed, dict) else {}

    def _auth_ok(self, expected_token: str) -> bool:
        if not expected_token:
            return True
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {expected_token}":
            return True
        return self.headers.get("X-OpenRD-Token", "") == expected_token

    def _send_cors_headers(self) -> None:
        origin = self.headers.get("Origin")
        allow_origin = origin if ALLOW_ORIGIN == "echo" and origin else ALLOW_ORIGIN
        self.send_header("Access-Control-Allow-Origin", allow_origin)
        self.send_header("Vary", "Origin")

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        data = json_bytes(payload)
        self.send_response(status)
        self._send_cors_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def lease_janitor(stop_event: threading.Event) -> None:
    while not stop_event.wait(5):
        with STATE_COND:
            expire_leases_locked()


def main() -> int:
    parser = argparse.ArgumentParser(description="OpenRD public control service")
    parser.add_argument("--host", default=os.environ.get("OPENRD_CONTROL_HOST", "0.0.0.0"))
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("OPENRD_CONTROL_PORT", "8790")),
    )
    args = parser.parse_args()

    stop_event = threading.Event()
    threading.Thread(target=lease_janitor, args=(stop_event,), daemon=True).start()

    httpd = ThreadingHTTPServer((args.host, args.port), ControlHandler)
    print(f"openrd-control-service listening on {args.host}:{args.port}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
