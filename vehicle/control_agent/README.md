# openrd-control-agent

Host-side RK3588 agent for public chassis control.

The agent runs on the RK3588 Debian host, actively polls the cloud control
service, and forwards safe motor targets to the ESP32 OpenRD-Driver HTTP API:

```text
openrd-control-service
  -> openrd-control-agent
  -> http://192.168.100.114/control
  -> ESP32 OpenRD-Driver
```

It does not expose a public inbound port on the vehicle network.

## Safety Behavior

- The agent clamps steering/throttle and `speed_limit`;
- default max speed is `300`;
- if frontend/cloud commands stop arriving for `350ms`, the agent sends
  `m1=m2=m3=m4=0`;
- if the cloud connection fails, the local watchdog still stops the chassis;
- `estop` locks the agent until `reset_estop`;
- ESP32/OpenRD-Driver must still keep its own control timeout.

## Run Manually

```bash
cd /home/linaro/OpenRD
python3 vehicle/control_agent/openrd-control-agent
```

## Install On RK3588

```bash
cd /home/linaro/OpenRD
bash tools/rk3588/install_openrd_control_agent.sh
sudo systemctl start openrd-control-agent.service
systemctl status openrd-control-agent.service --no-pager
```

Optional local overrides are written to:

```text
/home/linaro/OpenRD/vehicle/control_agent/run/openrd-control-agent.env
```

Supported environment variables:

```text
OPENRD_DRIVE_AGENT_CLOUD_URL=http://43.139.25.165:8790
OPENRD_DRIVE_AGENT_VEHICLE_ID=openrd-001
OPENRD_DRIVE_AGENT_TOKEN=
OPENRD_DRIVE_AGENT_DRIVER_URL=http://192.168.100.114
OPENRD_DRIVE_AGENT_MAX_SPEED=300
OPENRD_DRIVE_AGENT_COMMAND_TIMEOUT_SEC=0.35
OPENRD_DRIVE_AGENT_POLL_WAIT_SEC=0.12
OPENRD_DRIVE_AGENT_STATUS_INTERVAL_SEC=1.0
OPENRD_DRIVE_AGENT_HTTP_TIMEOUT_SEC=0.8
OPENRD_DRIVE_AGENT_READ_VOL_INTERVAL_SEC=30
```

## Cloud API Used

```text
POST /api/agent/poll
```

The cloud service distinguishes this agent by:

```json
{"agent":"openrd-control-agent"}
```

The agent accepts only:

```text
drive.drive
drive.stop
drive.estop
drive.reset_estop
drive.status
```
