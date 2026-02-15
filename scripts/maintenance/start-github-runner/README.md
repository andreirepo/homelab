# GitHub Runner Setup

Quick setup for an ephemeral GitHub Actions runner using Docker.

## Prerequisites

1. **GitHub Personal Access Token** (Classic)
   - Go to: Settings → Developer settings → Personal access tokens → Tokens (classic)
   - Required scopes: `repo` (full control of private repositories)
   - Optional: `workflow` (recommended)

2. **Docker** installed and running

## Usage

```bash
# Make executable
chmod +x start-github-runner.sh

# Start runner for your repository
GITHUB_TOKEN=your_token_here REPO_URL="https://github.com/username/repo" ./start-github-runner.sh
```

## What it does

- Creates a Docker container named `github-runner-{repo-name}`
- Registers an ephemeral runner that self-cleans after each job
- Automatically stops/starts runners for the same repository