# Homelab Repository
This repository contains Docker Compose configurations for various self-hosted services in my homelab environment.

## Services
### [Code Server](code-server/)
A self-hosted VS Code in the browser running in Docker.

### [Homer Dashboard](homer-dashboard/)
A static homepage for organizing and accessing all web services in the homelab.

### [Speedtest Tracker](speedtest-tracker/)
A self-hosted internet speed test tracker that runs regular tests and plots the results.

## Getting Started
Each service folder contains its own README and docker-compose.yml file with specific configuration details.

To start any service:

```bash
cd /home/anmu/Development/homelab/[service-folder]
docker-compose up -d
 ```