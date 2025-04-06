# Speedtest Tracker

A self-hosted internet speed test tracker that runs speedtest checks regularly and plots the results.

## Quick Reference
- **Image:** LinuxServer.io speedtest-tracker
- **Ports:** 8083 (HTTP), 8444 (HTTPS)
- **Access URL:** http://localhost:8083 or https://localhost:8444
- **Test Schedule:** Every 30 minutes (*/30 * * * *)
- **Database:** MariaDB 11

## Usage
```bash
cd /home/anmu/Development/homelab/speedtest-tracker
docker-compose up -d
```

## Official Documentation
- [Speedtest Tracker GitHub](https://github.com/alexjustesen/speedtest-tracker)
- [LinuxServer.io speedtest-tracker docs](https://docs.linuxserver.io/images/docker-speedtest-tracker/)