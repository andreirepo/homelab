#!/usr/bin/env python3
"""Telegram alerts for containers that actually need attention.

Docker is noisy about normal things, and a monitor that reports them is a
monitor you learn to ignore:

  * a deploy recreates containers on purpose: die, then start a few seconds
    later under the same name;
  * ``docker run --rm`` removes its container as soon as it exits;
  * every container start emits a ``health_status`` event twice, first
    ``starting`` and then ``healthy``;
  * a container in a restart loop emits die + start every few seconds.

So the rules here are:

  * a container is "down" only if it is still not running DEBOUNCE_SECONDS
    after it died -- a deploy or a restart never reaches that state;
  * a destroyed container is never an alert;
  * health is reported when it goes unhealthy, never when it goes healthy;
  * a container restarting CRASH_THRESHOLD times inside CRASH_WINDOW_SECONDS
    is reported once, as a crash loop;
  * every alert is rate limited per container and per kind.

Environment:
    TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID   required
    SERVER_NAME                            label in the message
    CHECK_INTERVAL                         status scan period, default 30
    DEBOUNCE_SECONDS                       default 30
    COOLDOWN_SECONDS                       per-container repeat guard, default 1800
    UNHEALTHY_GRACE_SECONDS                default 60
    CRASH_WINDOW_SECONDS / CRASH_THRESHOLD default 600 / 3
    STARTUP_QUIET_SECONDS                  startup message guard, default 21600
    IGNORE_CONTAINERS                      comma separated names
"""

import logging
import os
import queue
import signal
import sys
import threading
import time
from datetime import datetime, timezone

import docker
import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("docker-monitor")

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
SERVER_NAME = os.environ.get("SERVER_NAME", "dev-server")
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", "30"))
SEVERITY = os.environ.get("SEVERITY", "warning")
DEBOUNCE = int(os.environ.get("DEBOUNCE_SECONDS", "30"))
COOLDOWN = int(os.environ.get("COOLDOWN_SECONDS", "1800"))
UNHEALTHY_GRACE = int(os.environ.get("UNHEALTHY_GRACE_SECONDS", "60"))
CRASH_WINDOW = int(os.environ.get("CRASH_WINDOW_SECONDS", "600"))
CRASH_THRESHOLD = int(os.environ.get("CRASH_THRESHOLD", "3"))
STARTUP_QUIET = int(os.environ.get("STARTUP_QUIET_SECONDS", "21600"))
IGNORE = {
    name.strip()
    for name in os.environ.get("IGNORE_CONTAINERS", "").split(",")
    if name.strip()
}
IGNORE.add("docker-telegram-monitor")

if not BOT_TOKEN or not CHAT_ID:
    log.error("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set")
    sys.exit(1)

TELEGRAM_API = f"https://api.telegram.org/bot{BOT_TOKEN}"
SEVERITY_EMOJI = {"info": "ℹ️", "warning": "⚠️", "error": "🚨", "critical": "🔴"}


def esc(value):
    return (
        str(value)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def parse_docker_time(value):
    """Docker timestamps look like 2026-11-05T12:00:00.123456789Z."""
    if not value or value.startswith("0001-"):
        return 0.0
    try:
        trimmed = value.split(".")[0].replace("Z", "")
        return datetime.strptime(trimmed, "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=timezone.utc
        ).timestamp()
    except ValueError:
        return 0.0


def send_telegram(text):
    try:
        response = requests.post(
            f"{TELEGRAM_API}/sendMessage",
            data={"chat_id": CHAT_ID, "text": text, "parse_mode": "HTML"},
            timeout=10,
        )
        if response.status_code != 200:
            log.error("Telegram API error: %s - %s", response.status_code, response.text)
        return response.status_code == 200
    except Exception as error:  # noqa: BLE001 - never let alerting kill the loop
        log.error("Failed to send Telegram message: %s", error)
        return False


class Monitor:
    def __init__(self, client):
        self.client = client
        self.events = queue.Queue()
        self.pending_down = {}
        self.alerted_down = {}
        self.last_alert = {}
        self.starts = {}
        self.unhealthy_since = {}
        self.started_at = time.time()
        self.last_startup_message = 0.0

    # ----------------------------------------------------------------- helpers

    def can_alert(self, kind, name):
        key = (kind, name)
        return time.time() - self.last_alert.get(key, 0.0) >= COOLDOWN

    def mark_alert(self, kind, name):
        self.last_alert[(kind, name)] = time.time()

    def get_container(self, name):
        try:
            return self.client.containers.get(name)
        except docker.errors.NotFound:
            return None
        except Exception as error:  # noqa: BLE001
            log.warning("Could not inspect %s: %s", name, error)
            return None

    def describe(self, container):
        """Restart count and last log lines, or empty strings."""
        if container is None:
            return 0, ""
        try:
            restarts = container.attrs.get("RestartCount", 0)
            raw = container.logs(tail=6).decode("utf-8", errors="replace").strip()
            lines = "\n".join(raw.splitlines()[-5:])
            return restarts, esc(lines)[:900]
        except Exception as error:  # noqa: BLE001
            log.debug("No details for %s: %s", container.name, error)
            return 0, ""

    # ---------------------------------------------------------------- messages

    def header(self):
        return f"🖥️ <b>{SERVER_NAME}</b>"

    def msg_down(self, name, image, exit_code, oom, restarts, logs):
        emoji = SEVERITY_EMOJI.get(SEVERITY, "⚠️")
        lines = [
            self.header(),
            "",
            f"{emoji} <b>Container down</b>",
            "",
            f"<b>Name:</b> <code>{esc(name)}</code>",
            f"<b>Image:</b> <code>{esc(image)}</code>",
        ]
        if oom:
            lines.append("<b>Killed by:</b> the OOM killer")
        else:
            lines.append(f"<b>Exit code:</b> <code>{esc(exit_code)}</code>")
        lines.append(f"<b>Restarts:</b> <code>{restarts}</code>")
        if logs:
            lines += ["", "<b>Last logs:</b>", f"<pre>{logs}</pre>"]
        lines += ["", f"<i>Still down {DEBOUNCE}s after it stopped.</i>"]
        return "\n".join(lines)

    def msg_recovered(self, name, image):
        return "\n".join(
            [
                self.header(),
                "",
                "✅ <b>Container recovered</b>",
                "",
                f"<b>Name:</b> <code>{esc(name)}</code>",
                f"<b>Image:</b> <code>{esc(image)}</code>",
            ]
        )

    def msg_unhealthy(self, name, image, restarts, logs):
        lines = [
            self.header(),
            "",
            "🚨 <b>Container unhealthy</b>",
            "",
            f"<b>Name:</b> <code>{esc(name)}</code>",
            f"<b>Image:</b> <code>{esc(image)}</code>",
            f"<b>Restarts:</b> <code>{restarts}</code>",
        ]
        if logs:
            lines += ["", "<b>Last logs:</b>", f"<pre>{logs}</pre>"]
        return "\n".join(lines)

    def msg_crash_loop(self, name, image, starts):
        return "\n".join(
            [
                self.header(),
                "",
                "🔄 <b>Crash loop</b>",
                "",
                f"<b>Name:</b> <code>{esc(name)}</code>",
                f"<b>Image:</b> <code>{esc(image)}</code>",
                f"<b>Started:</b> <code>{starts}</code> times in "
                f"<code>{CRASH_WINDOW // 60}</code> min",
            ]
        )

    # ------------------------------------------------------------------ events

    def on_event(self, event):
        # Docker 29 sends "Action" and no legacy "status" field; older daemons
        # send the opposite. Accept both, and normalise health events, which
        # arrive as "health_status: healthy" rather than as an attribute.
        action = event.get("Action") or event.get("status") or ""
        actor = event.get("Actor", {})
        attributes = actor.get("Attributes", {}) or {}
        name = attributes.get("name", "")
        image = attributes.get("image", "unknown")
        container_id = actor.get("ID", "")

        if not name or name in IGNORE:
            return

        health = None
        if action.startswith("health_status"):
            health = attributes.get("health") or action.partition(":")[2].strip()
            action = "health_status"

        if action == "die":
            exit_code = attributes.get("exitCode", "unknown")
            if name in self.pending_down:
                return
            self.pending_down[name] = {
                "deadline": time.time() + DEBOUNCE,
                "exit_code": exit_code,
                "oom": attributes.get("oomkilled", "false") == "true",
                "image": image,
            }
            log.info(
                "died: %s (exit %s), checking again in %ss",
                name,
                exit_code,
                DEBOUNCE,
            )

        elif action == "destroy":
            # Recreated or removed on purpose: forget it, including any alert
            # history, because the container behind the name is now different.
            self.pending_down.pop(name, None)
            self.alerted_down.pop(name, None)
            self.unhealthy_since.pop(name, None)
            log.info("destroyed: %s, no alert", name)

        elif action == "start":
            if self.pending_down.pop(name, None):
                log.info(
                    "back within %ss (deploy or restart), no alert: %s",
                    DEBOUNCE,
                    name,
                )
            if self.alerted_down.pop(name, None):
                log.info("recovered: %s", name)
                send_telegram(self.msg_recovered(name, image))
            self.track_start(name, container_id, image)

        elif action == "health_status":
            if health == "unhealthy":
                self.report_unhealthy(name, image)
            # "starting" and "healthy" are not news.

        elif action == "oom":
            if self.can_alert("oom", name):
                self.mark_alert("oom", name)
                container = self.get_container(name)
                restarts, logs = self.describe(container)
                send_telegram(self.msg_down(name, image, "unknown", True, restarts, logs))

    def track_start(self, name, container_id, image):
        entry = self.starts.setdefault(name, {"id": container_id, "times": []})
        if entry["id"] != container_id:
            entry["id"] = container_id
            entry["times"] = []
        now = time.time()
        entry["times"] = [t for t in entry["times"] if now - t <= CRASH_WINDOW]
        entry["times"].append(now)
        if len(entry["times"]) >= CRASH_THRESHOLD and self.can_alert("crash", name):
            self.mark_alert("crash", name)
            send_telegram(self.msg_crash_loop(name, image, len(entry["times"])))

    # ------------------------------------------------------------------ checks

    def report_unhealthy(self, name, image):
        if not self.can_alert("unhealthy", name):
            return
        first_seen = self.unhealthy_since.setdefault(name, time.time())
        if time.time() - first_seen < UNHEALTHY_GRACE:
            return
        container = self.get_container(name)
        restarts, logs = self.describe(container)
        if send_telegram(self.msg_unhealthy(name, image, restarts, logs)):
            self.mark_alert("unhealthy", name)

    def check_pending(self):
        now = time.time()
        for name, info in list(self.pending_down.items()):
            if now < info["deadline"]:
                continue
            self.pending_down.pop(name, None)
            container = self.get_container(name)
            if container is None:
                log.info("gone before the debounce ended, no alert: %s", name)
                continue
            if container.status == "running":
                log.info("back at the deadline, no alert: %s", name)
                continue
            if not self.can_alert("down", name):
                log.info("down again inside the cooldown, staying quiet: %s", name)
                continue
            restarts, logs = self.describe(container)
            message = self.msg_down(
                name,
                info["image"],
                info["exit_code"],
                info["oom"],
                restarts,
                logs,
            )
            if send_telegram(message):
                self.mark_alert("down", name)
                self.alerted_down[name] = now
                log.warning(
                    "alerted down: %s (exit %s)", name, info["exit_code"]
                )

    def scan(self):
        try:
            containers = self.client.containers.list(all=True)
        except Exception as error:  # noqa: BLE001
            log.warning("Status scan failed: %s", error)
            return

        for container in containers:
            name = container.name
            if name in IGNORE:
                continue
            state = container.attrs.get("State", {})
            health = state.get("Health", {}).get("Status", "none")
            try:
                image = container.image.tags[0] if container.image.tags else container.image.short_id
            except Exception:  # noqa: BLE001
                image = "unknown"

            if health == "unhealthy":
                self.report_unhealthy(name, image)
            else:
                self.unhealthy_since.pop(name, None)

            if container.status in ("exited", "dead") and name not in self.pending_down:
                finished = parse_docker_time(state.get("FinishedAt", ""))
                # Ignore anything that was already stopped before we started
                # watching: a long-dead container is history, not an incident.
                if finished < self.started_at - DEBOUNCE:
                    continue
                if not self.can_alert("down", name):
                    continue
                exit_code = state.get("ExitCode", "unknown")
                oom = state.get("OOMKilled", False)
                restarts, logs = self.describe(container)
                message = self.msg_down(name, image, exit_code, oom, restarts, logs)
                if send_telegram(message):
                    self.mark_alert("down", name)
                    self.alerted_down[name] = time.time()
                    log.warning("alerted down from status scan: %s", name)

    # -------------------------------------------------------------------- loop

    def announce_start(self):
        now = time.time()
        if now - self.last_startup_message < STARTUP_QUIET:
            return
        self.last_startup_message = now
        try:
            total = len(self.client.containers.list(all=True))
        except Exception:  # noqa: BLE001
            total = "?"
        send_telegram(
            f"{self.header()}\n\n"
            "🟢 <b>Docker monitor started</b>\n\n"
            f"Watching <b>{total}</b> containers. Alerts only for containers that "
            f"stay down ({DEBOUNCE}s), are unhealthy, or restart "
            f"{CRASH_THRESHOLD} times in {CRASH_WINDOW // 60} minutes."
        )

    def read_events(self):
        while True:
            try:
                for event in self.client.events(decode=True):
                    self.events.put(event)
            except Exception as error:  # noqa: BLE001
                log.warning("Event stream dropped: %s", error)
            time.sleep(10)

    def run(self):
        threading.Thread(target=self.read_events, daemon=True).start()
        self.announce_start()
        last_scan = 0.0
        while True:
            try:
                self.on_event(self.events.get(timeout=2))
            except queue.Empty:
                pass
            except Exception:  # noqa: BLE001
                log.exception("Event handling failed, continuing")
            try:
                self.check_pending()
            except Exception:  # noqa: BLE001
                log.exception("Debounce check failed, continuing")
            if time.time() - last_scan >= CHECK_INTERVAL:
                last_scan = time.time()
                try:
                    self.scan()
                except Exception:  # noqa: BLE001
                    log.exception("Status scan failed, continuing")


def main():
    log.info("Connecting to Docker daemon...")
    try:
        client = docker.from_env()
        client.ping()
    except Exception as error:  # noqa: BLE001
        log.error("Failed to connect to Docker: %s", error)
        sys.exit(1)
    log.info("Connected to Docker daemon")

    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    Monitor(client).run()


if __name__ == "__main__":
    main()
