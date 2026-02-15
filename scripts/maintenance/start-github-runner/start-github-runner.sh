#!/bin/bash

# GitHub Runner Startup Script 
# Usage: REPO_URL="https://github.com/yourusername/example-repo" GITHUB_TOKEN=token ./start-github-runner.sh
# Creates: github-runner-example-repo container

set -e

echo "🚀 Starting GitHub Actions Runner..."

# Configuration
REPO_URL="${REPO_URL:?Error: REPO_URL environment variable is required}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
RUNNER_NAME="proxmox-runner-$(hostname)-${REPO_URL##*/}-$(date +%s)"
CONTAINER_NAME="github-runner-${REPO_URL##*/}"

# Check if token is provided
if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ Error: GITHUB_TOKEN environment variable is required"
    echo "💡 Usage: GITHUB_TOKEN=your_token ./start-github-runner-template.sh"
    exit 1
fi

# Stop any existing runner for this repository
echo "🛑 Stopping any existing runner for ${REPO_URL##*/}..."
docker stop "$CONTAINER_NAME" 2>/dev/null || echo "No existing runner to stop"
docker rm "$CONTAINER_NAME" 2>/dev/null || echo "No existing runner to remove"

# Start new ephemeral runner
echo "🔄 Starting new ephemeral runner: $RUNNER_NAME"
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -e REPO_URL="$REPO_URL" \
  -e ACCESS_TOKEN="$GITHUB_TOKEN" \
  -e RUNNER_NAME="$RUNNER_NAME" \
  -e RUNNER_WORKDIR="/tmp/runner/work" \
  -e EPHEMERAL="true" \
  -e DISABLE_AUTO_UPDATE="true" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp/runner:/tmp/runner \
  myoung34/github-runner:latest

echo "⏳ Waiting for runner to start..."
sleep 10

# Check if runner is running
if docker ps | grep -q "$CONTAINER_NAME"; then
    echo "✅ GitHub runner started successfully!"
    echo "📋 Runner name: $RUNNER_NAME"
    echo "📋 Container name: $CONTAINER_NAME"
    echo "🔗 Repository: $REPO_URL"
    echo ""
    echo "📊 Check runner status:"
    echo "   docker logs $CONTAINER_NAME"
    echo ""
    echo "🌐 Verify in GitHub:"
    echo "   Go to: $REPO_URL/settings/actions/runners"
else
    echo "❌ Failed to start runner"
    echo "📋 Check logs:"
    docker logs "$CONTAINER_NAME"
    exit 1
fi
