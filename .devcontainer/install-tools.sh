#!/usr/bin/env bash
set -euo pipefail

# postCreateCommand runs from workspace root (cwd = workspaceFolder).

require_npm() {
  if command -v npm >/dev/null 2>&1; then
    return 0
  fi
  echo "ERROR: npm is required to install codegraph but was not found in PATH." >&2
  echo "Ensure Node.js is available (e.g. ghcr.io/devcontainers/features/node:1 in features)." >&2
  exit 1
}

install_codegraph() {
  require_npm

  if command -v codegraph >/dev/null 2>&1; then
    echo "codegraph already installed."
  else
    echo "Installing codegraph CLI..."
    npm i -g @colbymchenry/codegraph
  fi

  if ! command -v codegraph >/dev/null 2>&1; then
    echo "ERROR: codegraph not on PATH after npm install -g." >&2
    echo "Check npm global bin is on PATH (npm prefix -g / npm bin -g)." >&2
    exit 1
  fi

  # Wire agents (MCP + instructions). Non-interactive for postCreate/CI.
  # Project-local so shared monorepo configs land in the workspace, not only $HOME.
  # Re-running is safe: install may re-apply agent config.
  echo "Installing codegraph agent wiring (project-local, auto-detect)..."
  codegraph install --yes

  # init uses cwd; skip if already initialized (idempotent).
  if [ -d .codegraph ]; then
    echo "codegraph already initialized."
    return 0
  fi

  echo "Initializing codegraph..."
  codegraph init
}

install_codegraph
