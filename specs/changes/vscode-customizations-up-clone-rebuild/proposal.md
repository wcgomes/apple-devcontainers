# Proposal: Apply vscode customizations by default on up, clone, and rebuild

## Intent

`customizations.vscode` settings already apply on create-path and on `up` reuse / start-stopped without `--vscode`, but extensions still wait for that flag, and `adevcontainer start` can still repair settings or install pending extensions. Users who bring a container up, clone, or rebuild expect declared settings and extensions to be present for a later manual attach, without opting into editor open. This change makes both apply by default on `up`, `clone`, and `rebuild`. Bare `start` still MUST NOT apply settings or extensions; resume hooks follow the realized official lifecycle (not a runtime-only lock).

## Scope

- Change id: **`vscode-customizations-up-clone-rebuild`**
- Realized base contract: union of `specs/<domain>.md` (no other active `specs/changes/<id>/` folders). Prior related archives: `20260808-vscode-open-flag`, `20260808-vscode-customizations-apply`, `20260810-rebuild`
- **MODIFY** [vscode.md](../../vscode.md) **VS Code attach acceptance**, **Optional `--vscode` flag on up, start, clone, and rebuild**, **Apply vscode settings on create-path (and repair on drift)**, and **Vscode customizations apply idempotency** so `--vscode` no longer gates apply
- **REMOVE** [vscode.md](../../vscode.md) **Apply vscode extensions when --vscode is set (before open)** and **ADD** **Apply vscode extensions on up, clone, and rebuild** (same guest install mechanism; new command gate)
- **MODIFY** [core.md](../../core.md) editor customizations property surface, **No longer pure-ignore** apply references, parseable-apply scenario, and the **Up lifecycle** vscode customizations matrix
- **MODIFY** [managed-lifecycle.md](../../managed-lifecycle.md) **Start managed container** so `adevcontainer start` MUST NOT apply settings or extensions (with or without `--vscode`). Resume hooks stay as in the realized spec (this change does **not** lock `start` as runtime-only / no postStart).
- Unchanged and in force: realized **postAttachCommand policy (CLI-only)** (CLI attach model); realized start hooks (`postStart` on every real start); identity hash still excludes customizations; Apple attach still does not auto-install; apply remains guest-side, soft-fail, marker-idempotent, and not image/Features bake

## Non-goals

- Changing realized **postAttachCommand policy** (CLI attach model stays)
- Changing realized start hooks (`postStart` on every real start stays; this change only excludes vscode customizations apply on `start`)
- Changing `--vscode` open behavior, nameConfig, folder-uri, or soft-fail open
- Baking extensions or settings into the image, Features Dockerfile, or derived-image identity
- Feature-contributed or image `devcontainer.metadata` customizations merge
- Changing Marketplace VSIX / registry / marker / soft-fail install mechanics
- Putting `customizations.vscode` into create identity / config hash
- Treating experimental UI attach as an apply trigger
- Hard-failing lifecycle solely because apply failed
- A product command named `build` (forced rebuild remains `rebuild`)
- Full Dev Containers extension-driven apply parity

## Approach

Lite SDD: this proposal + outcome delta `spec.md` only (no `design.md`, no `tasks.md` in this propose step).

On `up`, `clone`, and `rebuild`, after that command’s own lifecycle succeeds and the managed container is running, apply parseable config-file settings and extensions by default — including `up` reuse and `up` start-stopped — without requiring `--vscode`. On those commands, `--vscode` continues only to request best-effort open; postAttach follows the realized CLI attach model. `adevcontainer start` starts (or no-ops) the selected container, runs realized resume hooks, and, when `--vscode` is set, may still open; it MUST NOT apply settings or extensions. Keep the existing running-guest apply path, marker, and soft-fail policy so identity and image build stay unchanged.
