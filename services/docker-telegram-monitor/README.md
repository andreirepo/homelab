# Docker monitor, Telegram alerts

Watches the Docker daemon on the dev VM and sends a Telegram message when a
container actually needs attention.

## What was wrong with the first version

It alerted on **every** Docker event plus a raw 30 second status scan:

- Every deploy recreated containers on purpose, and each one produced
  *Container Stopped*, *Container Started* and *Container Health Changed*.
- A container stuck in a restart loop produced a *Stopped containers* summary
  **every 30 seconds**, forever. That is the "broken container" message people
  learn to ignore.
- A `404` from a container disappearing between `list()` and `inspect()` killed
  the loop; the container restarted and announced *Docker Monitor Started*.
- On Docker 29 the event-driven half had quietly died. The daemon sends
  `Action` and no longer the legacy `status` field, so every event fell through
  every branch. Only the noisy scan was left.

## Rules now

| Situation | Behaviour |
|---|---|
| `docker compose up --force-recreate`, `docker restart` | die, then start within seconds: **silent** |
| `docker run --rm` | die, then destroy: **silent** |
| Container stopped and still down after `DEBOUNCE_SECONDS` | **one alert**, with exit code, restart count and last logs |
| Same container down again inside `COOLDOWN_SECONDS` | silent |
| Health goes `healthy` | silent (this is not news) |
| Health stays `unhealthy` for `UNHEALTHY_GRACE_SECONDS` | **one alert** |
| Container starts `CRASH_THRESHOLD` times inside `CRASH_WINDOW_SECONDS` | **one "Crash loop" alert** |
| OOM kill | **one alert** |
| Alerted container comes back | **one "recovered"** message |
| Monitor itself starts | one message per `STARTUP_QUIET_SECONDS` |

Every Docker call is guarded: a container that disappears mid-inspection is
logged and skipped instead of killing the loop.

## Environment

Copy `.env.example` to `.env` (never commit it):

| Variable | Default | Meaning |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | required | bot token |
| `TELEGRAM_CHAT_ID` | required | chat or group id |
| `SERVER_NAME` | `dev-server` | label in the message |
| `CHECK_INTERVAL` | `30` | status scan period, seconds |
| `DEBOUNCE_SECONDS` | `30` | how long a container must stay down before it is an alert |
| `COOLDOWN_SECONDS` | `1800` | per-container, per-kind repeat guard |
| `UNHEALTHY_GRACE_SECONDS` | `60` | sustained unhealthy before alerting |
| `CRASH_WINDOW_SECONDS` / `CRASH_THRESHOLD` | `600` / `3` | crash-loop detection |
| `STARTUP_QUIET_SECONDS` | `21600` | suppresses restart announcements |
| `IGNORE_CONTAINERS` | empty | comma separated names to ignore |

## Deploy

```bash
cp .env.example .env      # then fill it in
docker compose build
docker compose up -d
docker logs -f docker-telegram-monitor
```

Expect one startup message every six hours and nothing else while the host is
healthy.

## Test it without waiting for an outage

```bash
docker restart glance                 # expect: "back within 30s ... no alert"
docker run --rm alpine true           # expect: "destroyed ... no alert"
docker run -d --name scratch alpine sleep 300
docker stop scratch                   # expect: exactly one "Container down"
docker rm scratch
```
