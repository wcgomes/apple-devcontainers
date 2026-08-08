# Proposal: Optional `--vscode` open after up / start / clone

## Intent

Today `adevcontainer` brings up a managed container (`up` bind-mode, `clone` volume-mode) and leaves VS Code attach to a **manual** host recipe. That recipe is verified (`code --new-window --folder-uri` with `vscode-remote://apple-container+…`) but not productized — users must copy id, image, and folder by hand. This change adds an optional **`--vscode`** flag on `up`, `start`, and `clone` that best-effort opens a new VS Code window on the resolved remote workspace folder after a successful lifecycle step, without failing the container lifecycle if the editor is missing or launch fails.

With a CLI attach hook in place, configs that declare `postAttachCommand` (and feature-contributed postAttach hooks) are no longer always skipped: when `--vscode` is set and the open **succeeds**, the CLI runs postAttach as the attach approximation. When `--vscode` is absent or open soft-fails, postAttach stays skipped with a clear status line (when any postAttach is present).

## Scope

- Change id: **`vscode-open-flag`**
- Package root: repository root (Swift SPM `adevcontainer`)
- Library under `Sources/ADevContainerLib/`; CLI entry `Sources/adevcontainer/AdevcontainerMain.swift`; tests under `Tests/adevcontainerTests/`
- Realized base contract: `specs/adevcontainer/spec.md`. This delta **adds** optional best-effort VS Code open behavior; **modifies** the existing **VS Code attach acceptance** requirement so manual attach remains valid and optional open is additive; and **modifies** **postAttachCommand policy (CLI-only)** plus the **lifecycle hook matrix** / hook-surface role so postAttach is gated on successful `--vscode` open (not “never execute”).
- Commands that accept `--vscode`: **`up`**, **`start`**, **`clone`** (parity across create and restart paths).
- Open inputs: container id/name, image ref (from create/inspect as appropriate), and **already-resolved** `remoteWorkspaceFolder` / label `devcontainer.workspace_folder` (product default `/workspaces/<basename>` when config omits `workspaceFolder` — never re-parse raw JSON alone for the open path).
- Soft-fail open: missing `code` CLI or launch failure MUST NOT fail the lifecycle command by itself; product MAY warn on stderr. Open soft-fail MUST NOT run postAttach.
- postAttach execution (when gated run applies): config `postAttachCommand` and feature-contributed postAttach commands via existing container-exec lifecycle machinery (same shell-vs-argv and `remoteUser` rules as postCreate/postStart); order after successful open; non-zero postAttach fails the lifecycle command exit but MUST NOT delete/stop the container solely for that failure.
- Host prereqs (document; not enforced as hard fail): VS Code + Remote - Containers + experimental Apple Container support.
- Docs task: README / help text note for `--vscode`, prereqs, and postAttach gating (no full Dev Containers parity claims; no claim of IDE-confirmed remote ready).

## Non-goals

- Full Dev Containers extension parity (up/rebuild driver, extension-owned clone-in-volume, auto-forward side channels)
- Hard-fail lifecycle when VS Code is absent or open fails (open remains soft-fail by itself)
- Waiting for VS Code Server fully ready, or detecting manual UI attach, before postAttach
- Replacing manual attach (Attach to Running Apple Container remains valid without `--vscode`)
- Opening via `open vscode://…` as the primary path (may reuse windows; product open uses `code --folder-uri`)
- Shipping or requiring nameConfig writes as the only open path (folder-uri is required; nameConfig is optional improvement)
- Auto-installing VS Code, the Remote - Containers extension, or enabling experimental settings for the user
- New commands solely for open (flag on existing lifecycle commands only)
- Changing container create/start semantics, labels, or success JSON shape on success beyond open/postAttach as side effects
- Treating postAttach failure like create-path onCreate/postCreate (no delete-on-fail for postAttach)

## Approach

Lite SDD: this proposal + outcome delta `spec.md` + dependency-ordered `tasks.md`, plus a lean `design.md` that encodes the verified host open recipe (URI authority, `code` discovery, optional nameConfig) and the postAttach gate after successful open so the outcome spec stays WHAT/WHY-focused.

1. Parse `--vscode` on `up` / `start` / `clone` in the CLI flag surface.
2. After successful lifecycle (container running; results/labels available), if `--vscode`: resolve open inputs → build folder-uri → invoke host `code` best-effort → warn on failure, never flip lifecycle exit to failure solely due to open.
3. After a **successful** open attempt: run postAttach (config + feature-contributed) via LifecycleRunner-style exec; on non-zero exit fail the command (keep container). If `--vscode` absent or open soft-failed/skipped: do not execute postAttach; when any postAttach is present, emit one skip status line.
4. Unit-test URI construction, soft-fail open paths, and postAttach run/skip/fail-keep-container with a mockable host launcher; keep default suite free of a real VS Code install.
5. Document flag, prereqs, soft-fail open, and postAttach gating in help/README; keep manual attach acceptance.

## Locked product decisions (summary)

| Topic | Decision |
|-------|----------|
| Flag name | `--vscode` |
| Commands | `up`, `start`, `clone` |
| Soft-fail open | Open failure / missing `code` / missing id·image·folder MUST NOT fail lifecycle **by itself** |
| Folder source | Resolved `remoteWorkspaceFolder` / `devcontainer.workspace_folder` (resolver default when omit/empty) |
| Required open path | `code --new-window --folder-uri` with `vscode-remote://apple-container+` hex authority |
| Authority payload | Compact JSON `{"id":"<containerId>","image":"<imageRef>"}` (UTF-8 → hex) |
| Image ref | From create/inspect result as appropriate |
| `code` discovery | `PATH`, then standard macOS app path; MAY try `code-insiders` |
| nameConfig write | MAY/SHOULD if low-risk; not required for open |
| Parity claim | MUST NOT claim full Dev Containers extension parity |
| Without flag | Behavior unchanged for open; manual attach still valid |
| `--json` | Success JSON unchanged on success; open is side effect (progress/warn on stderr). postAttach failure → command fails (no success JSON / existing error path) |
| **postAttach RUNS** | Only when `--vscode` is set **and** best-effort VS Code open outcome is **success** (host `code` launch succeeded). That is the CLI attach hook. |
| **postAttach SKIPPED** | (1) `--vscode` absent → skip status when any postAttach present (e.g. `postAttach skipped (no attach hook)` or clearer equivalent). (2) `--vscode` set but open soft-failed/skipped → MUST NOT run postAttach; SHOULD emit skip status explaining attach open did not succeed. |
| **What runs** | Config `postAttachCommand` + feature-contributed postAttach commands (same merge/order patterns as other feature lifecycle hooks — match LifecycleRunner conventions: config then features). |
| **How** | Existing container exec lifecycle machinery; same shell-vs-argv rules as postCreate/postStart; as `remoteUser` when set. |
| **Order** | After successful open completes → then postAttach. Do not run postAttach before open when `--vscode`. |
| **postAttach failure** | If postAttach **runs** and exits non-zero → `up`/`start`/`clone` MUST fail (non-zero) with a clear error naming postAttach. MUST NOT delete/stop the container solely due to postAttach failure (container already up; VS Code may already be opening). Contrast create-path onCreate/postCreate delete-on-fail. |
| **Without property** | No skip line if postAttach absent (config and features). |
| **Approximation** | CLI-initiated attach approximation only — not IDE-confirmed remote ready. Non-goal: wait for VS Code Server fully ready or detect manual UI attach. |
| **Apply consistently** | Gated policy applies to `up`, `start`, and `clone` the same way. |
