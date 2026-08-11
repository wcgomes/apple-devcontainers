import Foundation

/// Parsed global options shared by the CLI executable and its tests.
public struct ParsedArgs: Sendable {
    public var workspace: String?
    public var name: String?
    public var flags: Set<String>
    public var passthrough: [String]

    public init(
        workspace: String? = nil,
        name: String? = nil,
        flags: Set<String> = [],
        passthrough: [String] = []
    ) {
        self.workspace = workspace
        self.name = name
        self.flags = flags
        self.passthrough = passthrough
    }
}

/// Command-line surface (flag parsing, the `-w` gate, usage and per-command help).
///
/// Lives in the library so subcommand dispatch behavior is unit-testable; the
/// executable target's `AdevcontainerMain` is a thin caller.
public enum CommandSurface {
    /// Parse global options (everything after the subcommand).
    public static func parseArgs(_ args: [String]) throws -> ParsedArgs {
        var workspace: String?
        var name: String?
        var flags = Set<String>()
        var passthrough: [String] = []
        var i = 0
        var afterDashDash = false

        while i < args.count {
            let a = args[i]
            if afterDashDash {
                passthrough.append(a)
                i += 1
                continue
            }
            if a == "--" {
                afterDashDash = true
                i += 1
                continue
            }
            if a == "--workspace" || a == "-w" {
                guard i + 1 < args.count else {
                    throw CLIError(
                        code: CLIErrorCode.usage,
                        property: a,
                        message: "\(a) requires a path argument"
                    )
                }
                workspace = args[i + 1]
                i += 2
                continue
            }
            if a.hasPrefix("--workspace=") {
                workspace = String(a.dropFirst("--workspace=".count))
                i += 1
                continue
            }
            if a == "--name" {
                guard i + 1 < args.count else {
                    throw CLIError(
                        code: CLIErrorCode.usage,
                        property: a,
                        message: "--name requires a container name or id"
                    )
                }
                name = args[i + 1]
                i += 2
                continue
            }
            if a.hasPrefix("--name=") {
                name = String(a.dropFirst("--name=".count))
                i += 1
                continue
            }
            if a == "--json" {
                flags.insert("json")
                i += 1
                continue
            }
            if a == "--skip-pull" {
                flags.insert("skip-pull")
                i += 1
                continue
            }
            if a == "--vscode" {
                flags.insert("vscode")
                i += 1
                continue
            }
            if a == "-i" || a == "--interactive" {
                flags.insert("i")
                flags.insert("interactive")
                i += 1
                continue
            }
            if a == "-t" || a == "--tty" {
                flags.insert("t")
                flags.insert("tty")
                i += 1
                continue
            }
            if a == "-it" || a == "-ti" {
                flags.insert("i")
                flags.insert("interactive")
                flags.insert("t")
                flags.insert("tty")
                i += 1
                continue
            }
            if a == "-h" || a == "--help" {
                flags.insert("help")
                i += 1
                continue
            }
            // Reject product-non-goal flags explicitly
            if a == "--branch" || a.hasPrefix("--branch=")
                || a == "--depth" || a.hasPrefix("--depth=")
                || a == "--token" || a.hasPrefix("--token=")
                || a == "--pat" || a.hasPrefix("--pat=")
            {
                throw CLIError(
                    code: CLIErrorCode.usage,
                    property: a.split(separator: "=").first.map(String.init) ?? a,
                    message: "Unsupported option '\(a.split(separator: "=").first.map(String.init) ?? a)'",
                    hint: "clone accepts only a git URL; SSH uses ssh-agent, HTTPS uses host git credentials"
                )
            }
            if a.hasPrefix("-") {
                throw CLIError(
                    code: CLIErrorCode.usage,
                    property: a,
                    message: "Unknown option '\(a)'"
                )
            }
            // bare args become passthrough (exec command / clone URL)
            passthrough.append(a)
            i += 1
        }

        return ParsedArgs(workspace: workspace, name: name, flags: flags, passthrough: passthrough)
    }

    /// Subcommand targeted by a `help <command>` invocation, or nil when `args`
    /// is not `help <command>` (including bare `help`, which the caller routes to
    /// main usage). `help <command>` MUST print the same command-specific help as
    /// `<command> --help` (both go through `printCommandHelp` in the CLI entry).
    public static func resolveHelpSubcommand(args: [String]) -> String? {
        guard args.first == "help", args.count >= 2 else { return nil }
        return args[1]
    }

    /// `-w` / `--workspace` is only valid for `up` (bind-mode create).
    public static func enforceWorkspaceGate(subcommand: String, parsed: ParsedArgs) throws {
        if parsed.workspace != nil, subcommand != "up" {
            throw CLIError(
                code: CLIErrorCode.usage,
                property: "-w",
                message: "-w is only valid for up",
                hint: "Lifecycle commands use --name (or picker). Create with: adevcontainer up [-w <path>]"
            )
        }
    }

    // MARK: - Usage / help

    public static func usageText() -> String {
        """
        adevcontainer — Apple container devcontainer CLI

        Usage:
          adevcontainer <command> [options]

        Commands:
          doctor              Check Apple container runtime readiness
          up [-w path]        Create/start/reuse bind-mode workspace container (host path)
          clone <git-url>     Clone repo into named volume workspace (managed)
          list [--json]       List managed containers (up + clone)
          start [--name]      Start a stopped managed container (no hooks on volume-mode)
          exec [-it] [--name] [--] [cmd...]  Run a command (or shell) in a managed container
          stop [--name]       Stop a managed container (name or picker)
          delete [--name]     Remove container only (not workspace volume)
          prune [--name]      Remove container, volumes (incl. *-ws), and config image
          rebuild [--name]    Force-recreate a managed container from its current config
                              (same name/workspace; volumes preserved)
          inspect [--name]    Show identity, state, labels (from runtime + labels)

        Options:
          -w, --workspace <path>   Workspace root for `up` only (default: cwd)
          --name <container>       Managed container name/id (exec/start/stop/delete/prune/rebuild/inspect)
          --json                   Machine-readable output (up, list, rebuild)
          --skip-pull              Skip image pull on up/clone/rebuild
          --vscode                 Best-effort open VS Code; gates postAttach + extensions apply
          -h, --help               Show help

        Identity:
          - `up` is the only command that accepts -w/--workspace (bind-mode create).
          - Lifecycle commands resolve via --name or an interactive picker among
            containers labeled devcontainer.managed=adevcontainer (both bind and volume).
          - Passing -w to a non-up command is a usage error.

        VS Code (--vscode on up/start/clone/rebuild):
          - Best-effort open of a new window on the resolved remote workspace folder.
          - Requires host VS Code with Remote - Containers and a discoverable `code` CLI.
          - Missing `code` or launch failure warns on stderr; open alone does not fail lifecycle.
          - postAttachCommand runs only after successful open; skipped without flag or on open
            soft-fail (status when present). postAttach non-zero fails command but keeps container.
          - customizations.vscode.settings: merged on create-path (not gated on --vscode).
          - customizations.vscode.extensions: installed after successful --vscode open only
            (soft-fail; marker idempotency; Server extensions.json + transitive
            extensionDependencies). Manual attach without flag does not install.
            May need Developer: Reload Window once so the UI refreshes the registry.
          - CLI attach approximation only — not IDE remote-ready. Not full extension parity.

        Clone notes:
          - Requires host git on PATH (config fetch + HTTPS credential fill)
          - Full clone runs inside the container (named volume workspace)
          - SSH: needs ssh-agent (SSH_AUTH_SOCK); create --ssh for later push
          - HTTPS: host git credential fill one-shot; guest credential.helper store
          - Auto-adds Features git:1 when config lacks git/common-utils
          - No --branch / PAT CLI / GCM-in-guest

        Rebuild notes:
          - Force-recreates a managed container from its CURRENT devcontainer.json,
            keeping the same container name and --name selection (bind) or same
            workspace volume (volume mode) — data is preserved, not re-cloned.
          - Config is read strictly before anything is deleted: unreadable/missing
            config fails with config_not_found and the old container is untouched.
          - Container-only delete of the old container; workspace and config named
            volumes are reused via ensureVolume (never deleted/recreated).
          - Config hash mismatch on up → config_hash_mismatch → rebuild (sole force-recreate).
          - Hard post-delete failure recovery (create/start/onCreate…postStart):
            bind = host stamped config; clone-origin volume = Alpine helper + temp.
            TTY: error then "Open the recovery editor now? [Y/n]" (default Y);
            non-TTY/--json: retain + retry commands; named rebuild skips the prompt.

        Exit codes: 0 success, non-zero failure
        """
    }

    /// Per-command help text; nil when unknown (caller falls back to usage).
    public static func commandHelpText(_ subcommand: String) -> String? {
        switch subcommand {
        case "up":
            return """
            adevcontainer up [-w <path>] [--json] [--skip-pull] [--vscode]

            Create/start/reuse a bind-mode workspace container for a host checkout.
            -w/--workspace defaults to the current directory. Stamps managed labels
            so the container appears in list and lifecycle commands (--name / picker).

            --vscode: best-effort open a new VS Code window on the remote workspace
            (requires VS Code with Remote - Containers and a `code` CLI). Soft-fails with
            a stderr warning; open alone does not fail up.
            postAttachCommand runs only after successful open; skipped without flag /
            open soft-fail; postAttach failure fails up but keeps the container.
            customizations.vscode.settings apply on create-path (not gated on open);
            extensions apply after successful open (soft-fail; marker skip when matched).
            Not full Dev Containers parity — manual attach remains valid.
            """
        case "clone":
            return """
            adevcontainer clone <git-url> [--skip-pull] [--vscode]

            Create a managed container whose workspace is a named volume.
            Host git fetches config only; full clone runs inside the container.

            SSH URLs require ssh-agent (SSH_AUTH_SOCK); create injects --ssh.
            HTTPS uses host git credential fill once, then guest credential store.
            Optional: ADEVCONTAINER_GIT_TOKEN. No PAT flags / GCM-in-guest.
            If the config has no git/common-utils feature, clone injects
            ghcr.io/devcontainers/features/git:1 for in-container git.

            --vscode: best-effort open VS Code on the resolved remote folder after
            success (same prereqs/soft-fail/postAttach + extensions gate as up --vscode).
            Settings from customizations.vscode still apply on create-path without the flag.
            Not full extension parity.
            """
        case "list":
            return """
            adevcontainer list [--json]

            List containers with label devcontainer.managed=adevcontainer
            (bind-mode from up and volume-mode from clone).
            """
        case "start":
            return """
            adevcontainer start [--name <container>] [--vscode]

            Start a stopped managed container. Volume-mode: runtime start only
            (no lifecycle hooks). Already running is success no-op.

            --vscode: best-effort open VS Code on the labeled remote workspace after
            start (inspect for id/image/folder). Soft-fail open; postAttach and pending
            extensions only after successful open (same gate as up). Settings repair on
            marker drift does not require the flag. Not full extension parity.
            """
        case "exec":
            return """
            adevcontainer exec [-it] [--name <container>] [--] [cmd...]

            Run a command, or interactive shell when cmd is omitted.
            Resolves a managed container via --name or picker (no -w).
            User/workdir come from labels stamped at up/clone create.
            """
        case "stop":
            return """
            adevcontainer stop [--name <container>]

            Stop a managed container via --name or interactive picker.
            -w is not accepted (use up only for workspace path).
            """
        case "delete", "rm":
            return """
            adevcontainer delete [--name <container>]

            Remove the managed container only (not volumes or images).
            """
        case "prune":
            return """
            adevcontainer prune [--name <container>]

            Remove managed container, config named volumes (label), volume-mode
            workspace volume (*-ws), and config image. Selection via --name/picker.
            """
        case "inspect":
            return """
            adevcontainer inspect [--name <container>]

            Show identity, state, and labels from runtime + managed labels.
            """
        case "rebuild":
            return """
            adevcontainer rebuild [--name <container>] [--skip-pull] [--vscode] [--json]

            Force-recreate a managed container (bind from up, volume from clone): a forced
            recreate from the container's CURRENT devcontainer.json. Selection via
            --name / auto-single / interactive picker (same as start/delete). -w is
            usage error (up only). Sole force-recreate path (up never force-recreates).

            The old container is deleted only after the config read, host requirements
            preflight, and Features work all succeed; any failure before that leaves the
            old container untouched. The new container keeps the same name (bind) or the
            same workspace volume (volume mode) — volume data is preserved, never
            re-cloned or re-created. Container-only delete: workspace *-ws and config
            named volumes are reused via ensureVolume.

            Recovery (hard post-delete failures only: create/start/onCreate…postStart;
            not pre-delete, not settings/open/postAttach soft-fail):
              - Bind: edit host stamped devcontainer.json (no helper/Alpine/volume write).
              - Clone-origin volume: Alpine helper + secure temp + atomic write to *-ws.
              - TTY (no --json): print error → "Open the recovery editor now? [Y/n]"
                (default Y). Decline retains state + rebuild --name retry.
              - Non-TTY/--json: no prompt/editor; structured retain + edit/retry/cleanup.
              - Named rebuild --name retry skips the Y/n prompt.

            --vscode: best-effort open VS Code on the resolved remote folder after
            success (same soft-fail/postAttach + extensions gate as up --vscode).
            customizations.vscode.settings apply on create-path without the flag.
            --json: machine-readable success output (up-shape; volume mode may add
            gitUrl/workspaceVolume). Failures exit non-zero with a structured error.
            v1 limitation: volume-mode rebuild fetches OCI features only — the host
            fetcher (DefaultFeatureFetcher) and local-path feature refs inside the
            workspace volume are unsupported and fail cleanly before the old container
            is deleted.
            Not full extension parity.
            """
        default:
            return nil
        }
    }
}