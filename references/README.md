# Reference devcontainers

Each subdirectory contains a focused `.devcontainer.json` example for a common
development stack. Language configs use OCI images, standard Dev Container
Features, and VS Code customizations — no privileged access or Docker-in-Docker.

`multiplatform` is the multi-feature sample: `mcr.microsoft.com/devcontainers/base:ubuntu`
plus OCI Features `dotnet:2` and `node:1` (exercises install-time feature
`containerEnv`, e.g. `DOTNET_ROOT`).
