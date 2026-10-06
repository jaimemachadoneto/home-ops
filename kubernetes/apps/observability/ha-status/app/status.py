"""Publish cluster and backup health to Home Assistant as an MQTT device.

Follows Home Assistant's MQTT discovery conventions:

- Device-based discovery: one retained config on
  homeassistant/device/home-ops/config creates the "Home-Ops" device and all
  its entities.
- Availability by Last Will: the connection registers a retained "offline"
  will on home-ops/availability and publishes a retained "online" once
  connected. If this process, its node, the cluster or the network dies, the
  broker publishes the will and Home Assistant marks every entity unavailable.
  That is the heartbeat; expire_after on each entity is a backstop.
- Birth message: when Home Assistant publishes "online" on
  homeassistant/status (it restarted), discovery and state are sent again.

Standard library only, so the stock Python image runs it as-is. The MQTT
3.1.1 client below covers just what this needs: CONNECT with will and
login, QoS 0 PUBLISH/SUBSCRIBE, PINGREQ, DISCONNECT. Any connection error
exits the process and Kubernetes restarts it.
"""

import json
import os
import random
import select
import signal
import socket
import struct
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PROMETHEUS_URL = os.environ["PROMETHEUS_URL"]
ALERTMANAGER_URL = os.environ["ALERTMANAGER_URL"]
MQTT_HOST = os.environ["MQTT_HOST"]
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
MQTT_USERNAME = os.environ["MQTT_USERNAME"]
MQTT_PASSWORD = os.environ["MQTT_PASSWORD"]
INTERVAL = int(os.environ.get("INTERVAL", "60"))
CONFIGURATION_URL = os.environ.get("CONFIGURATION_URL")
DISCOVERY_PREFIX = os.environ.get("DISCOVERY_PREFIX", "homeassistant")

VERSION = "1.0.0"
NODE_ID = "home-ops"
STATE_TOPIC = f"{NODE_ID}/status"
AVAILABILITY_TOPIC = f"{NODE_ID}/availability"
DISCOVERY_TOPIC = f"{DISCOVERY_PREFIX}/device/{NODE_ID}/config"
HA_STATUS_TOPIC = f"{DISCOVERY_PREFIX}/status"
# The broker publishes the will after 1.5x this with no traffic from us.
KEEPALIVE = 60
CEPH_HEALTH = {0: "HEALTH_OK", 1: "HEALTH_WARN", 2: "HEALTH_ERR"}

# Thresholds for the "Backups" problem sensor; they match the Prometheus alerts.
MAX_POSTGRES_BACKUP_AGE_H = 26
MAX_POSTGRES_WAL_AGE_MIN = 60


def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} {msg}", file=sys.stderr, flush=True)


# --- Prometheus -------------------------------------------------------------


def http_get(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read()


def prom_query(expr):
    url = f"{PROMETHEUS_URL}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    body = json.loads(http_get(url))
    if body.get("status") != "success":
        raise RuntimeError(f"query failed: {expr}: {body}")
    return body["data"]["result"]


def prom_scalar(expr):
    """First sample's value, or None when the series does not exist."""
    result = prom_query(expr)
    return float(result[0]["value"][1]) if result else None


def collect():
    status = {"updated": datetime.now(timezone.utc).isoformat(timespec="seconds")}

    try:
        http_get(f"{ALERTMANAGER_URL}/-/healthy")
        status["alertmanager"] = "ON"
    except Exception as exc:  # any failure means "not healthy"
        log(f"alertmanager: {exc}")
        status["alertmanager"] = "OFF"

    try:
        critical = prom_query('ALERTS{alertstate="firing", severity="critical"}')
        out_of_sync = prom_query("volsync_volume_out_of_sync == 1")
        nodes_ready = prom_scalar('sum(kube_node_status_condition{condition="Ready", status="true"})')
        nodes_total = prom_scalar('count(kube_node_status_condition{condition="Ready", status="true"})')
        ceph = prom_scalar("max(ceph_health_status)")
        pg_backup = prom_scalar(
            'time() - max(cnpg_collector_last_available_backup_timestamp{namespace="database", pod=~"postgres16-[0-9]+"})'
        )
        pg_wal = prom_scalar(
            'min(cnpg_pg_stat_archiver_seconds_since_last_archival{namespace="database", pod=~"postgres16-[0-9]+"})'
        )
    except Exception as exc:
        # Everything below is unknown, not zero: publish nulls.
        log(f"prometheus: {exc}")
        status["prometheus"] = "OFF"
        return status

    status["prometheus"] = "ON"
    status["critical_alerts"] = len(critical)
    status["critical_alert_names"] = sorted({r["metric"].get("alertname", "?") for r in critical})
    status["volsync_out_of_sync"] = len(out_of_sync)
    status["volsync_out_of_sync_names"] = sorted(
        f'{r["metric"].get("obj_namespace", "?")}/{r["metric"].get("obj_name", "?")}' for r in out_of_sync
    )
    status["nodes_ready"] = None if nodes_ready is None else int(nodes_ready)
    status["nodes_total"] = None if nodes_total is None else int(nodes_total)
    status["ceph_health"] = None if ceph is None else CEPH_HEALTH.get(int(ceph), str(int(ceph)))
    status["postgres_backup_age_h"] = None if pg_backup is None else round(pg_backup / 3600, 1)
    status["postgres_wal_age_min"] = None if pg_wal is None else round(pg_wal / 60, 1)

    problems = [f"volsync out of sync: {name}" for name in status["volsync_out_of_sync_names"]]
    if pg_backup is None:
        problems.append("postgres backup metric missing")
    elif status["postgres_backup_age_h"] > MAX_POSTGRES_BACKUP_AGE_H:
        problems.append(f'postgres base backup {status["postgres_backup_age_h"]}h old')
    if pg_wal is not None and status["postgres_wal_age_min"] > MAX_POSTGRES_WAL_AGE_MIN:
        problems.append(f'postgres WAL archive {status["postgres_wal_age_min"]}min old')
    status["backup_problem"] = "ON" if problems else "OFF"
    status["backup_problems"] = problems
    return status


# --- Discovery --------------------------------------------------------------


def discovery_config():
    def component(platform, key, name, **extra):
        cfg = {
            "p": platform,
            "unique_id": f"home_ops_{key}",
            "default_entity_id": f"{platform}.home_ops_{key}",
            "name": name,
            "expire_after": INTERVAL * 3,
        }
        cfg.update(extra)
        return cfg

    def attributes(template):
        return {"json_attributes_topic": STATE_TOPIC, "json_attributes_template": template}

    def names(key):
        return attributes("{{ {'names': value_json.%s | default([])} | tojson }}" % key)

    def value(key):
        return "{{ value_json.%s | default(none) }}" % key

    components = {
        "status": component(
            "binary_sensor", "status", "Status",
            device_class="connectivity", value_template="ON",
        ),
        "backup_problem": component(
            "binary_sensor", "backup_problem", "Backups",
            device_class="problem", value_template=value("backup_problem"),
            **attributes("{{ {'problems': value_json.backup_problems | default([])} | tojson }}"),
        ),
        "critical_alerts": component(
            "sensor", "critical_alerts", "Critical alerts",
            value_template=value("critical_alerts"), state_class="measurement",
            icon="mdi:alert", **names("critical_alert_names"),
        ),
        "volsync_out_of_sync": component(
            "sensor", "volsync_out_of_sync", "VolSync apps out of sync",
            value_template=value("volsync_out_of_sync"), state_class="measurement",
            icon="mdi:backup-restore", **names("volsync_out_of_sync_names"),
        ),
        "postgres_backup_age": component(
            "sensor", "postgres_backup_age", "Postgres last backup age",
            value_template=value("postgres_backup_age_h"), device_class="duration",
            unit_of_measurement="h", state_class="measurement", suggested_display_precision=1,
        ),
        "postgres_wal_age": component(
            "sensor", "postgres_wal_age", "Postgres last WAL archive age",
            value_template=value("postgres_wal_age_min"), device_class="duration",
            unit_of_measurement="min", state_class="measurement", suggested_display_precision=0,
        ),
        "nodes_ready": component(
            "sensor", "nodes_ready", "Nodes ready",
            value_template=value("nodes_ready"), state_class="measurement", icon="mdi:server",
            **attributes("{{ {'total': value_json.nodes_total | default(none)} | tojson }}"),
        ),
        "ceph_health": component(
            "sensor", "ceph_health", "Ceph health",
            value_template=value("ceph_health"), device_class="enum",
            options=list(CEPH_HEALTH.values()), icon="mdi:harddisk",
        ),
        "prometheus": component(
            "binary_sensor", "prometheus", "Prometheus",
            device_class="connectivity", value_template=value("prometheus"),
            entity_category="diagnostic",
        ),
        "alertmanager": component(
            "binary_sensor", "alertmanager", "Alertmanager",
            device_class="connectivity", value_template=value("alertmanager"),
            entity_category="diagnostic",
        ),
        "last_update": component(
            "sensor", "last_update", "Last update",
            value_template=value("updated"), device_class="timestamp",
            entity_category="diagnostic",
        ),
    }
    device = {
        "ids": [NODE_ID],
        "name": "Home-Ops",
        "mf": "home-ops",
        "mdl": "Kubernetes cluster",
    }
    if CONFIGURATION_URL:
        device["cu"] = CONFIGURATION_URL
    return {
        "dev": device,
        "o": {"name": "home-ops ha-status", "sw": VERSION, "url": "https://github.com/jaimemachadoneto/home-ops"},
        "avty_t": AVAILABILITY_TOPIC,
        "stat_t": STATE_TOPIC,
        "cmps": components,
    }


# --- MQTT -------------------------------------------------------------------


def _remaining_length(n):
    out = bytearray()
    while True:
        byte, n = n % 128, n // 128
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _str(s):
    data = s.encode() if isinstance(s, str) else s
    return struct.pack("!H", len(data)) + data


def _packet(header, body=b""):
    return bytes([header]) + _remaining_length(len(body)) + body


class MQTT:
    def __init__(self):
        self.sock = socket.create_connection((MQTT_HOST, MQTT_PORT), timeout=10)
        self.buf = b""
        self.last_sent = self.last_received = time.monotonic()
        # username, password, will retain, will flag, clean session
        flags = 0x80 | 0x40 | 0x20 | 0x04 | 0x02
        body = _str("MQTT") + bytes([4, flags]) + struct.pack("!H", KEEPALIVE)
        body += _str(f"{NODE_ID}-ha-status") + _str(AVAILABILITY_TOPIC) + _str("offline")
        body += _str(MQTT_USERNAME) + _str(MQTT_PASSWORD)
        self._send(_packet(0x10, body))
        header, payload = self._read_packet(timeout=10)
        if header != 0x20 or len(payload) != 2 or payload[1] != 0:
            raise ConnectionError(f"MQTT connection refused: {header:#x} {payload!r}")

    def _send(self, data):
        self.sock.sendall(data)
        self.last_sent = time.monotonic()

    def publish(self, topic, payload, retain=False):
        self._send(_packet(0x30 | (0x01 if retain else 0), _str(topic) + payload.encode()))

    def subscribe(self, topic):
        self._send(_packet(0x82, struct.pack("!H", 1) + _str(topic) + b"\x00"))

    def ping_if_idle(self):
        if time.monotonic() - self.last_sent >= KEEPALIVE / 2:
            self._send(_packet(0xC0))
        if time.monotonic() - self.last_received > KEEPALIVE * 1.5:
            raise ConnectionError("no traffic from broker")

    def disconnect(self):
        self._send(_packet(0xE0))
        self.sock.close()

    def _parse(self):
        """One complete packet from the buffer, or None."""
        if len(self.buf) < 2:
            return None
        length, mult, i = 0, 1, 1
        while True:
            if i >= len(self.buf):
                return None
            byte = self.buf[i]
            length += (byte & 0x7F) * mult
            mult *= 128
            i += 1
            if not byte & 0x80:
                break
        if len(self.buf) < i + length:
            return None
        packet = (self.buf[0], self.buf[i:i + length])
        self.buf = self.buf[i + length:]
        return packet

    def _read_packet(self, timeout):
        deadline = time.monotonic() + timeout
        while (packet := self._parse()) is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ConnectionError("timed out waiting for broker")
            self.wait(remaining)
        return packet

    def wait(self, timeout):
        """Read whatever arrives within timeout into the buffer."""
        readable, _, _ = select.select([self.sock], [], [], max(timeout, 0))
        if readable:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("broker closed the connection")
            self.buf += chunk
            self.last_received = time.monotonic()

    def messages(self):
        """Incoming PUBLISH packets as (topic, payload); other packets are dropped."""
        while (packet := self._parse()) is not None:
            header, body = packet
            if header >> 4 == 3:
                n = struct.unpack("!H", body[:2])[0]
                offset = 2 + n + (2 if header & 0x06 else 0)
                yield body[2:2 + n].decode(), body[offset:]


# --- Main loop --------------------------------------------------------------


def main():
    stopping = False

    def stop(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    mqtt = MQTT()
    log(f"connected to {MQTT_HOST}:{MQTT_PORT}")
    mqtt.publish(AVAILABILITY_TOPIC, "online", retain=True)
    mqtt.subscribe(HA_STATUS_TOPIC)

    announce = True
    next_publish = 0.0
    while not stopping:
        if announce:
            # Retained, so Home Assistant has it on start even without our birth reply.
            mqtt.publish(DISCOVERY_TOPIC, json.dumps(discovery_config()), retain=True)
            announce = False
            next_publish = 0.0
        if time.monotonic() >= next_publish:
            status = collect()
            # Not retained: availability covers restarts, and a stale status
            # must never be replayed as current.
            mqtt.publish(STATE_TOPIC, json.dumps(status))
            next_publish = time.monotonic() + INTERVAL
        mqtt.ping_if_idle()
        try:
            mqtt.wait(min(5.0, next_publish - time.monotonic()))
        except InterruptedError:
            continue
        for topic, payload in mqtt.messages():
            if topic == HA_STATUS_TOPIC and payload == b"online":
                log("Home Assistant came online; announcing again")
                # Home Assistant asks for a short random delay before re-announcing.
                time.sleep(random.uniform(1, 5))
                announce = True

    # A clean DISCONNECT suppresses the will, so say offline explicitly.
    mqtt.publish(AVAILABILITY_TOPIC, "offline", retain=True)
    mqtt.disconnect()
    log("stopped")


if __name__ == "__main__":
    main()
