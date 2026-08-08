# Proposal: Optional `--vscode` open after up / start / clone

## Intent

Today `adevcontainer` brings up a managed container (`up` bind-mode, `clone` volume-mode) and leaves VS Code attach to a **manual** host recipe. That recipe is verified (`code --new-window --folder-uri` with `vscode-remote://apple-container+…`) but not productized — users must copy id, image, and folder by hand. This change adds an optional **`--vscode`** flag on `up`, `start`, and `clone` that best-effort opens a new VS Code window on the resolved remote workspace folder after a successful lifecycle step, without failing the container lifecycle if the editor is missing or launch fails.

## Scope

- Change id: **`vscode-open-flag`**
- Package root: repository root (Swift SPM `adevcontainer`)
- Library under `Sources/ADevContainerLib/`; CLI entry `Sources/adevcontainer/AdevcontainerMain.swift`; tests under `Tests/adevcontainerTests/`
- Realized base contract: `specs/adevcontainer/spec.md`. This delta **adds** optional best-effort VS Code open behavior and **modifies** the existing **VS Code attach acceptance** requirement so manual attach remains valid and optional open is additive.
- Commands that accept `--vscode`: **`up`**, **`start`**, **`clone`** (parity across create and restart paths).
- Open inputs: container id/name, image ref (from create/inspect as appropriate), and **already-resolved** `remoteWorkspaceFolder` / label `devcontainer.workspace_folder` (product default `/workspaces/<basename>` when config omits `workspaceFolder` — never re-parse raw JSON alone for the open path).
- Soft-fail: missing `code` CLI or launch failure MUST NOT fail the lifecycle command; product MAY warn on stderr.
- Host prereqs (document; not enforced as hard fail): VS Code + Remote - Containers + experimental Apple Container support.
- Docs task: README / help text note for `--vscode` and prereqs (no full Dev Containers parity claims).

## Non-goals

- Full Dev Containers extension parity (up/rebuild driver, extension-owned clone-in-volume, auto-forward side channels)
- Hard-fail lifecycle when VS Code is absent or open fails
- Replacing manual attach (Attach to Running Apple Container remains valid without `--vscode`)
- Opening via `open vscode://…` as the primary path (may reuse windows; product open uses `code --folder-uri`)
- Shipping or requiring nameConfig writes as the only open path (folder-uri is required; nameConfig is optional improvement)
- Auto-installing VS Code, the Remote - Containers extension, or enabling experimental settings for the user
- New commands solely for open (flag on existing lifecycle commands only)
- Changing container create/start semantics, labels, or success JSON shape beyond open as a side effect

## Approach

Lite SDD: this proposal + outcome delta `spec.md` + dependency-ordered `tasks.md`, plus a lean `design.md` that encodes the verified host open recipe (URI authority, `code` discovery, optional nameConfig) so the outcome spec stays WHAT/WHY-focused.

1. Parse `--vscode` on `up` / `start` / `clone` in the CLI flag surface.
2. After successful lifecycle (container running; results/labels available), if `--vscode`: resolve open inputs → build folder-uri → invoke host `code` best-effort → warn on failure, never flip lifecycle exit to failure solely due to open.
3. Unit-test URI construction and soft-fail paths with a mockable host launcher; keep default suite free of a real VS Code install.
4. Document flag, prereqs, and soft-fail in help/README; keep manual attach acceptance.

## Locked product decisions (summary)

| Topic | Decision |
|-------|----------|
| Flag name | `--vscode` |
| Commands | `up`, `start`, `clone` |
| Soft-fail | Open failure / missing `code` MUST NOT fail lifecycle |
| Folder source | Resolved `remoteWorkspaceFolder` / `devcontainer.workspace_folder` (resolver default when omit/empty) |
| Required open path | `code --new-window --folder-uri` with `vscode-remote://apple-container+` hex authority |
| Authority payload | Compact JSON `{"id":"<containerId>","image":"<imageRef>"}` (UTF-8 → hex) |
| Image ref | From create/inspect result as appropriate |
| `code` discovery | `PATH`, then standard macOS app path; MAY try `code-insiders` |
| nameConfig write | MAY/SHOULD if low-risk; not required for open |
| Parity claim | MUST NOT claim full Dev Containers extension parity |
| Without flag | Behavior unchanged; manual attach still valid |
| `--json` | Lifecycle JSON unchanged; open is side effect (progress/warn on stderr) |
