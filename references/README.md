# Reference devcontainers

Each subdirectory contains a focused `.devcontainer.json` example for a common
development stack. Language configs use OCI images, standard Dev Container
Features, and VS Code customizations — no privileged access or Docker-in-Docker.

`multiplatform` is the multi-feature sample: `mcr.microsoft.com/devcontainers/base:ubuntu`
plus OCI Features `dotnet:2` and `node:1` (exercises install-time feature
`containerEnv`, e.g. `DOTNET_ROOT`).

`nodejs` demonstrates a non-root `remoteUser` with a writable
named volume while the main container drops all capabilities.

`readonly-metadata-remoteuser` is the live check for a read-only rootfs
plus image metadata `remoteUser` (official Microsoft `base:ubuntu`, no
local `remoteUser` or `containerUser`).

`dockerfile` is the nested `build` sample: a root `.devcontainer.json` with
`build.dockerfile` and a sibling `FROM`-only `Dockerfile` (no privileged
access or Docker-in-Docker).
