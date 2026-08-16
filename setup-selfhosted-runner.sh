#!/usr/bin/env bash
# setup-selfhosted-runner.sh - register + start a GitHub Actions self-hosted
# runner for the SteamFlow purepe build (weter11/wine-tkg-git-modd).
#
# WHY: the full Proton redist build peaks at ~20G of disk. GitHub-hosted
# runners expose only ~8-9G usable (14G total minus the runner image), so
# the purepe job must run on a machine with headroom. Your box has 39G free.
#
# Requirements: gh CLI authenticated (gh auth status), systemd, and a
# container engine the runner user can use (docker or podman — you have
# podman). The build script detects either.
#
# Usage:
#   ./setup-selfhosted-runner.sh        # install + start (idempotent)
#   ./setup-selfhosted-runner.sh stop   # stop the service
#   ./setup-selfhosted-runner.sh uninstall
#
# After setup, dispatch "SteamFlow PurePE Runner Build" — the job matches
# the labels [self-hosted, linux, x64, steamflow-purepe].
# NOTE: the registration token is valid 1 hour; re-run the script if it
# expires (the runner binary is reused).

set -euo pipefail

REPO="weter11/wine-tkg-git-modd"
RUNNER_NAME="steamflow-purepe-builder"
RUNNER_DIR="$HOME/actions-runner"
RUNNER_VERSION="2.322.0"

action="${1:-install}"

case "$action" in
  install)
    ;&
  start)
    if [ ! -x "$RUNNER_DIR/run.sh" ]; then
      gh auth status >/dev/null 2>&1 || { echo "gh not authenticated"; exit 1; }
      mkdir -p "$RUNNER_DIR"
      cd "$RUNNER_DIR"
      if [ ! -f "run.sh" ]; then
        echo "== Downloading runner ${RUNNER_VERSION} =="
        curl -fL -o runner.tar.gz \
          "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
        tar -xzf runner.tar.gz
        rm runner.tar.gz
        sudo ./bin/installdependencies.sh
      fi
      echo "== Registering with ${REPO} =="
      TOKEN=$(gh api "repos/${REPO}/actions/runners/registration-token" --jq .token)
      ./config.sh --url "https://github.com/${REPO}" --token "$TOKEN" \
        --name "$RUNNER_NAME" \
        --labels "steamflow-purepe,linux,x64" \
        --work "_work" --replace
    else
      echo "== Runner already configured, reusing =="
    fi
    echo "== Installing + starting systemd service =="
    sudo "$RUNNER_DIR/svc.sh" install
    sudo "$RUNNER_DIR/svc.sh" start
    echo "== Done. Verify: sudo systemctl status actions.runner.weter11-${REPO//\//-}.$RUNNER_NAME.service =="
    ;;
  stop)
    sudo "$RUNNER_DIR/svc.sh" stop || true
    ;;
  uninstall)
    sudo "$RUNNER_DIR/svc.sh" uninstall || true
    cd "$RUNNER_DIR"
    TOKEN=$(gh api "repos/${REPO}/actions/runners/registration-token" --jq .token)
    ./config.sh remove --token "$TOKEN" || true
    rm -rf "$RUNNER_DIR"
    echo "== Removed =="
    ;;
  *)
    echo "usage: $0 [install|stop|uninstall]"
    exit 1
    ;;
esac
