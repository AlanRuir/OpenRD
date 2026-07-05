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
DRIVE_COMMAND_TTL_MS = int(os.environ.get("OPENRD_DRIVE_COMMAND_TTL_MS", "300"))
DRIVE_MAX_SPEED_LIMIT = int(os.environ.get("OPENRD_DRIVE_MAX_SPEED_LIMIT", "500"))
DRIVE_DEFAULT_SPEED_LIMIT = int(
    os.environ.get("OPENRD_DRIVE_DEFAULT_SPEED_LIMIT", "300")
)
VIDEO_LATENCY_STATUS_FILE = os.environ.get(
    "OPENRD_VIDEO_LATENCY_STATUS_FILE",
    "/tmp/openrd-video-latency.json",
)
VIDEO_LATENCY_STALE_MS = int(os.environ.get("OPENRD_VIDEO_LATENCY_STALE_MS", "5000"))

VIDEO_LATENCY_INT_FIELDS = {
    "video_latency_ms",
    "video_latency_avg_ms",
    "video_latency_p50_ms",
    "video_latency_p95_ms",
    "video_frame_seq",
    "video_latency_updated_ms",
    "sidecar_first_sei_seen_ms",
    "sidecar_first_sei_frame_seq",
    "sidecar_first_sei_latency_ms",
    "reconnect_count",
}
VIDEO_LATENCY_STATES = {
    "ok",
    "no_stream",
    "no_sei",
    "clock_unsynced",
    "stale",
    "error",
    "unknown",
}


@dataclass
class VehicleState:
    vehicle_id: str
    last_video_agent_seen: float = 0.0
    video_agent_name: str = ""
    video_agent_version: str = ""
    last_drive_agent_seen: float = 0.0
    drive_agent_name: str = ""
    drive_agent_version: str = ""
    video_status: dict[str, Any] = field(default_factory=dict)
    drive_status: dict[str, Any] = field(default_factory=dict)
    video_command_queue: list[dict[str, Any]] = field(default_factory=list)
    drive_command_queue: list[dict[str, Any]] = field(default_factory=list)
    leases: dict[str, float] = field(default_factory=dict)
    video_last_result: dict[str, Any] = field(default_factory=dict)
    drive_last_result: dict[str, Any] = field(default_factory=dict)
    video_last_error: str = ""
    drive_last_error: str = ""
    last_drive_frontend_seen: float = 0.0
    last_drive_seq: int = 0


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


def video_agent_online_locked(vehicle: VehicleState) -> bool:
    return time.time() - vehicle.last_video_agent_seen <= AGENT_TIMEOUT_SEC


def drive_agent_online_locked(vehicle: VehicleState) -> bool:
    return time.time() - vehicle.last_drive_agent_seen <= AGENT_TIMEOUT_SEC


def is_drive_agent(agent_name: str) -> bool:
    value = agent_name.lower()
    return "control-agent" in value or "drive-agent" in value


def video_state_locked(vehicle: VehicleState) -> str:
    if not video_agent_online_locked(vehicle):
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
    return any(cmd.get("type") == command_type for cmd in vehicle.video_command_queue)


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
    vehicle.video_command_queue.append(command)
    STATE_COND.notify_all()
    return command


def enqueue_drive_command_locked(
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

    if command_type in {"drive.stop", "drive.estop", "drive.reset_estop"}:
        vehicle.drive_command_queue.clear()
    elif command_type == "drive.drive":
        vehicle.drive_command_queue = [
            cmd for cmd in vehicle.drive_command_queue if cmd.get("type") != "drive.drive"
        ]

    vehicle.drive_command_queue.append(command)
    STATE_COND.notify_all()
    return command


def clamp_float(value: Any, low: float, high: float, default: float = 0.0) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        parsed = default
    return max(low, min(high, parsed))


def clamp_int(value: Any, low: int, high: int, default: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = default
    return max(low, min(high, parsed))


def optional_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def video_latency_status(vehicle_id: str) -> dict[str, Any]:
    if not VIDEO_LATENCY_STATUS_FILE:
        return {"video_latency_state": "unknown"}

    try:
        with open(VIDEO_LATENCY_STATUS_FILE, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError:
        return {"video_latency_state": "unknown"}

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return {"video_latency_state": "error", "video_latency_error": "invalid_json"}
    if not isinstance(parsed, dict):
        return {"video_latency_state": "error", "video_latency_error": "invalid_json"}

    status_vehicle = str(parsed.get("vehicle_id") or "")
    if status_vehicle and status_vehicle != vehicle_id:
        return {"video_latency_state": "unknown"}

    result: dict[str, Any] = {}
    for field_name in VIDEO_LATENCY_INT_FIELDS:
        value = optional_int(parsed.get(field_name))
        if value is not None:
            result[field_name] = value

    state = str(parsed.get("video_latency_state") or "unknown")
    if state not in VIDEO_LATENCY_STATES:
        state = "unknown"

    updated_ms = optional_int(parsed.get("video_latency_updated_ms"))
    if updated_ms is not None and now_ms() - updated_ms > VIDEO_LATENCY_STALE_MS:
        state = "stale"

    result["video_latency_state"] = state
    last_error = str(parsed.get("last_error") or parsed.get("video_latency_error") or "")
    if last_error:
        result["video_latency_error"] = last_error
    return result


def sanitize_drive_command(body: dict[str, Any], forced_type: str | None = None) -> tuple[str, dict[str, Any]]:
    raw_type = str(forced_type or body.get("type") or "").lower()
    stop = bool(body.get("stop")) or raw_type == "stop"
    estop = bool(body.get("estop")) or raw_type == "estop"

    if raw_type == "reset_estop":
        command_type = "drive.reset_estop"
    elif estop:
        command_type = "drive.estop"
    elif stop:
        command_type = "drive.stop"
    else:
        command_type = "drive.drive"

    seq = clamp_int(body.get("seq"), 0, 2_147_483_647, 0)
    speed_limit = clamp_int(
        body.get("speed_limit"),
        0,
        DRIVE_MAX_SPEED_LIMIT,
        DRIVE_DEFAULT_SPEED_LIMIT,
    )
    client_time_ms = clamp_int(
        body.get("client_time_ms", body.get("timestamp_ms")),
        0,
        9_999_999_999_999,
        0,
    )
    payload = {
        "seq": seq,
        "client_time_ms": client_time_ms,
        "server_time_ms": now_ms(),
        "deadline_ms": now_ms() + DRIVE_COMMAND_TTL_MS,
        "steering": round(clamp_float(body.get("steering"), -1.0, 1.0), 3),
        "throttle": round(clamp_float(body.get("throttle"), -1.0, 1.0), 3),
        "brake": round(clamp_float(body.get("brake"), 0.0, 1.0), 3),
        "speed_limit": speed_limit,
        "enable": bool(body.get("enable", True)),
        "source": str(body.get("source") or "frontend"),
    }
    if command_type in {"drive.stop", "drive.estop"}:
        payload.update({"steering": 0.0, "throttle": 0.0, "brake": 1.0, "speed_limit": 0})
    return command_type, payload


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
            video_agent_online_locked(vehicle)
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
    payload = {
        "ok": True,
        "vehicle_id": vehicle.vehicle_id,
        "vehicle_online": video_agent_online_locked(vehicle),
        "agent": vehicle.video_agent_name,
        "agent_version": vehicle.video_agent_version,
        "video_state": state,
        "service_active": service_active,
        "mode": vehicle.video_status.get("mode", "rtmp"),
        "play_url": vehicle.video_status.get("play_url") or DEFAULT_PLAY_URL,
        "rtsp_url": vehicle.video_status.get("rtsp_url") or DEFAULT_RTSP_URL,
        "rtmp_url": vehicle.video_status.get("rtmp_url") or DEFAULT_RTMP_URL,
        "lease_count": len(vehicle.leases),
        "lease_expires_in_sec": lease_remaining_locked(vehicle),
        "pending_commands": len(vehicle.video_command_queue),
        "last_agent_seen_ms": int(vehicle.last_video_agent_seen * 1000)
        if vehicle.last_video_agent_seen
        else 0,
        "last_error": vehicle.video_last_error
        or str(vehicle.video_status.get("last_error", "") or ""),
        "last_result": vehicle.video_last_result,
        "drive_agent_online": drive_agent_online_locked(vehicle),
        "drive_state": str(vehicle.drive_status.get("state", "") or "unknown"),
        "server_time_ms": now_ms(),
    }
    payload.update(video_latency_status(vehicle.vehicle_id))
    return payload


def drive_snapshot_locked(vehicle: VehicleState) -> dict[str, Any]:
    online = drive_agent_online_locked(vehicle)
    status = vehicle.drive_status
    drive_state = str(status.get("state") or ("unknown" if online else "offline"))
    last_cmd_age_ms = int(max(0.0, time.time() - vehicle.last_drive_frontend_seen) * 1000)
    if vehicle.last_drive_frontend_seen <= 0:
        last_cmd_age_ms = 0

    return {
        "ok": True,
        "vehicle_id": vehicle.vehicle_id,
        "vehicle_online": online,
        "drive_agent_online": online,
        "agent": vehicle.drive_agent_name,
        "agent_version": vehicle.drive_agent_version,
        "drive_state": drive_state,
        "control_state": drive_state,
        "esp32_online": bool(status.get("esp32_online")),
        "backend": status.get("backend", "esp32_http"),
        "target": status.get("target", [0, 0, 0, 0]),
        "battery_voltage_v": status.get("battery_voltage_v", 0),
        "battery_profile": status.get("battery_profile", "12V_3S"),
        "battery_age_ms": status.get("battery_age_ms", 0),
        "estop": bool(status.get("estop")),
        "speed_limit": status.get("speed_limit", DRIVE_DEFAULT_SPEED_LIMIT),
        "last_cmd_seq": status.get("last_cmd_seq", vehicle.last_drive_seq),
        "last_cmd_age_ms": status.get("last_cmd_age_ms", last_cmd_age_ms),
        "last_agent_seen_ms": int(vehicle.last_drive_agent_seen * 1000)
        if vehicle.last_drive_agent_seen
        else 0,
        "pending_commands": len(vehicle.drive_command_queue),
        "last_error": vehicle.drive_last_error
        or str(status.get("last_error", "") or ""),
        "last_result": vehicle.drive_last_result,
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

        if self._is_vehicle_drive_path(parts, "status"):
            if not self._auth_ok(VIEWER_TOKEN):
                self._send_json(401, {"ok": False, "error": "unauthorized"})
                return
            vehicle_id = parts[2]
            with STATE_COND:
                vehicle = get_vehicle_locked(vehicle_id)
                payload = drive_snapshot_locked(vehicle)
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

        if len(parts) == 5 and parts[:2] == ["api", "vehicles"] and parts[3] == "drive":
            action = parts[4]
            if action in {"command", "stop", "estop", "reset_estop"}:
                self._handle_drive_action(parts[2], action)
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
        try:
            wait_sec = float(body.get("wait_sec") or AGENT_POLL_WAIT_SEC)
        except (TypeError, ValueError):
            wait_sec = float(AGENT_POLL_WAIT_SEC)
        wait_sec = max(0.05, min(wait_sec, 30.0))
        agent_name = str(body.get("agent") or "")
        drive_agent = is_drive_agent(agent_name)

        with STATE_COND:
            vehicle = get_vehicle_locked(vehicle_id)
            if drive_agent:
                vehicle.last_drive_agent_seen = time.time()
                vehicle.drive_agent_name = agent_name or vehicle.drive_agent_name
                vehicle.drive_agent_version = str(
                    body.get("version") or vehicle.drive_agent_version
                )
                command_queue = vehicle.drive_command_queue
            else:
                vehicle.last_video_agent_seen = time.time()
                vehicle.video_agent_name = agent_name or vehicle.video_agent_name
                vehicle.video_agent_version = str(
                    body.get("version") or vehicle.video_agent_version
                )
                command_queue = vehicle.video_command_queue

            status = body.get("status")
            if isinstance(status, dict):
                if drive_agent:
                    vehicle.drive_status = status
                    vehicle.drive_last_error = str(status.get("last_error", "") or "")
                else:
                    vehicle.video_status = status
                    vehicle.video_last_error = str(status.get("last_error", "") or "")

            result = body.get("result")
            if isinstance(result, dict) and result:
                if drive_agent:
                    vehicle.drive_last_result = result
                    if result.get("ok") is False:
                        vehicle.drive_last_error = str(result.get("last_error", "") or "")
                else:
                    vehicle.video_last_result = result
                    if result.get("ok") is False:
                        vehicle.video_last_error = str(result.get("last_error", "") or "")

            expire_leases_locked()
            if not command_queue:
                STATE_COND.wait(timeout=wait_sec)
                if drive_agent:
                    vehicle.last_drive_agent_seen = time.time()
                    command_queue = vehicle.drive_command_queue
                else:
                    vehicle.last_video_agent_seen = time.time()
                    command_queue = vehicle.video_command_queue
                expire_leases_locked()

            command = (
                command_queue.pop(0)
                if command_queue
                else {"type": "noop", "request_id": ""}
            )
            payload = {
                "ok": True,
                "command": command,
                "lease_expires_in_sec": lease_remaining_locked(vehicle),
                "server_time_ms": now_ms(),
            }

        self._send_json(200, payload)

    def _handle_drive_action(self, vehicle_id: str, action: str) -> None:
        if not self._auth_ok(VIEWER_TOKEN):
            self._send_json(401, {"ok": False, "error": "unauthorized"})
            return

        body = self._read_json()
        forced_type = None if action == "command" else action
        command_type, payload = sanitize_drive_command(body, forced_type)

        with STATE_COND:
            vehicle = get_vehicle_locked(vehicle_id)
            online = drive_agent_online_locked(vehicle)
            if not online:
                snapshot = drive_snapshot_locked(vehicle)
                snapshot.update({"ok": False, "error": "drive_agent_offline"})
                self._send_json(409, snapshot)
                return

            vehicle.last_drive_frontend_seen = time.time()
            vehicle.last_drive_seq = int(payload.get("seq") or vehicle.last_drive_seq)
            command = enqueue_drive_command_locked(vehicle, command_type, payload)
            snapshot = drive_snapshot_locked(vehicle)
            snapshot.update(
                {
                    "accepted": True,
                    "command_type": command_type,
                    "request_id": command["request_id"],
                }
            )
        self._send_json(202, snapshot)

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
            online = video_agent_online_locked(vehicle)

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

    @staticmethod
    def _is_vehicle_drive_path(parts: list[str], action: str) -> bool:
        return (
            len(parts) == 5
            and parts[:2] == ["api", "vehicles"]
            and parts[3] == "drive"
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
