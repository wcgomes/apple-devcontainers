# Apple Dev Container CLI (adevcontainer)

[![CI](https://github.com/wcgomes/apple-devcontainers/actions/workflows/ci.yml/badge.svg)](https://github.com/wcgomes/apple-devcontainers/actions/workflows/ci.yml)
[![tests](https://img.shields.io/badge/tests-528%2B-brightgreen)](https://github.com/wcgomes/apple-devcontainers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Native Swift CLI that reads `devcontainer.json` and runs development environments on Apple [`container`](https://github.com/apple/container).

Use `up` with an existing checkout, or use `clone` to keep the repository in a named volume for faster I/O. Work from your terminal, an AI agent, or optionally VS Code.

For implementation details and behavior beyond this quick reference, see the [technical documentation](wiki/index.md).

## Requirements

- macOS 26+ on Apple Silicon
- Apple [`container`](https://github.com/apple/container), installed separately

## Install

### Homebrew (recommended)

```bash
brew install wcgomes/tap/adevcontainer
```

### Release binary

Download `adevcontainer-macos-arm64.tar.gz` and `adevcontainer-macos-arm64.tar.gz.sha256` from [GitHub Releases](https://github.com/wcgomes/apple-devcontainers/releases), then run:

```bash
shasum -a 256 -c adevcontainer-macos-arm64.tar.gz.sha256
tar xzf adevcontainer-macos-arm64.tar.gz
sudo mv adevcontainer /usr/local/bin/ # or move it to another directory on PATH
```

Verify the installation and Apple `container` setup:

```bash
adevcontainer doctor
```

To build from source, follow [CONTRIBUTING.md](CONTRIBUTING.md).

## Quick start

Your project must contain `.devcontainer/devcontainer.json` or `.devcontainer.json`.

### Use a local checkout

From the project directory:

```bash
adevcontainer up
adevcontainer exec -it
```

To use another local directory, run `adevcontainer up -w <path>`.

### Clone into a named volume

You do not need a local checkout. Use an HTTPS or SSH Git URL:

```bash
adevcontainer clone https://github.com/org/repo.git
adevcontainer list
adevcontainer exec --name <name> -it
```

The cloned source remains in a named volume. You can work, commit, and push from inside the container.

## Essential commands

| Command | Purpose |
| --- | --- |
| `adevcontainer doctor` | Check Apple `container` readiness |
| `adevcontainer up [-w <path>] [--vscode]` | Create or start a dev container from a local folder |
| `adevcontainer clone <git-url> [--vscode]` | Clone a repository into a named volume and start its dev container |
| `adevcontainer exec [-it] [--name <name>] [--] [cmd…]` | Open a shell or run a command in a running managed container |
| `adevcontainer list [--json]` | List managed dev containers |
| `adevcontainer start [--vscode] \| stop \| delete \| prune \| inspect [--name <name>]` | Manage a container by name or with the interactive picker |
| `adevcontainer rebuild [--name <name>] [--vscode]` | Rebuild a managed container from its current configuration |

Use `delete` to remove only the container. Use `prune` to remove the container and its managed volumes. See the [technical documentation](wiki/index.md) before cleanup or for configuration, lifecycle, Features, recovery, and compatibility behavior.

## Optional: VS Code

Install VS Code, the [Remote - Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers), and make sure the `code` CLI is available. Then add `--vscode` to `up`, `clone`, `start`, or `rebuild`:

```bash
adevcontainer up --vscode
```

The CLI opens the remote workspace and applies supported VS Code settings and extensions from `devcontainer.json`.

Apple Remote Containers attach uses the container’s default user (it does not pass exec `-u`). On create, `adevcontainer` therefore applies a non-root connection user as create `-u` when `containerUser` is unset (for example metadata `remoteUser: vscode`), so the integrated terminal matches the intended remote user. Explicit `containerUser` still wins create `-u` when set; `remoteUser` remains the connection/exec/nameConfig user.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for prerequisites, source builds, tests, fixtures, and the repository development workflow.

Technical design and project decisions are documented in the [wiki](wiki/index.md).

## License

This project is available under the [MIT License](LICENSE).
