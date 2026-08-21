import Foundation

/// Parsed global options shared by the CLI executable and its tests.
public struct ParsedArgs: Sendable {
    public var workspace: String?
    public var name: String?
    public var resume: String?
    public var flags: Set<String>
    public var passthrough: [String]

    public init(
        workspace: String? = nil,
        name: String? = nil,
        resume: String? = nil,
        flags: Set<String> = [],
        passthrough: [String] = []
    ) {
        self.workspace = workspace
        self.name = name
        self.resume = resume
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
        var resume: String?
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
            if a == "--resume" {
                guard i + 1 < args.count else {
                    throw CLIError(
                        code: CLIErrorCode.usage,
                        property: a,
                        message: "--resume requires a config directory argument"
                    )
                }
                let value = args[i + 1]
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(
                        code: CLIErrorCode.usage,
                        property: a,
                        message: "--resume requires a config directory argument"
                    )
                }
                resume = value
                i += 2
                continue
            }
            if a.hasPrefix("--resume=") {
                let value = String(a.dropFirst("--resume=".count))
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(
                        code: CLIErrorCode.usage,
                        property: "--resume",
                        message: "--resume requires a config directory argument"
                    )
                }
                resume = value
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

        return ParsedArgs(workspace: workspace, name: name, resume: resume, flags: flags, passthrough: passthrough)
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
        if parsed.resume != nil, subcommand != "clone" {
            throw CLIError(
                code: CLIErrorCode.usage,
                property: "--resume",
                message: "--resume is only valid for clone",
                hint: "Resume a retained checkout with: adevcontainer clone <git-url> --resume <config-dir>"
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
          up [-w path]        Create/start/reuse bind-mode dev container (host path)
          clone <git-url>     Clone repo into volume-mode dev container (managed)
          list [--json]       List managed dev containers (up + clone)
          start [--name]      Start a stopped managed container (initialize + postStart on real start; --json suppresses recovery prompt)
          exec [-it] [--name] [--] [cmd...]  Run a command (or shell) in a managed dev container
          stop [--name]       Stop a managed dev container (name or picker)
          delete [--name]     Remove container only (not workspace volume)
          purge [--name]      Remove container, volumes (incl. *-ws), and config image
          rebuild [--name]    Force-rebuild a managed dev container from its current config
                               (same name; volumes preserved)
          inspect [--name]    Show identity, state, labels (from runtime + labels)

        Options:
          -w, --workspace <path>   Workspace root for `up` only (default: cwd)
          --name <container>       Managed container name/id (exec/start/stop/delete/purge/rebuild/inspect)
          --resume <config-dir>    Resume clone from a retained config checkout (clone only)
          --json                   Machine-readable output (up, clone, list, rebuild); on start,
                                   suppresses the interactive recovery prompt
          --skip-pull              Skip image pull on up/clone/rebuild
          --vscode                 Best-effort open VS Code (not apply). postAttach is CLI attach except already-running start
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
          - customizations.vscode.settings and extensions apply by default on up / clone /
            rebuild (fresh create-path, up reuse, and up start-stopped). Soft-fail; marker
            idempotency; Server extensions.json + transitive extensionDependencies ∪
            extensionPack. Not gated on --vscode or open success.
          - adevcontainer start does not apply settings or extensions (with or without
            --vscode). Real start runs initialize (when a host workspace exists), then
            config postStart and remelted feature postStart. Already-running is a no-op
            for those hooks.
          - Order with --vscode on up / clone / rebuild / real start: apply (if pending;
            not on start) → open → postAttach. postAttach is CLI attach on those paths
            (open soft-fail does not skip it). On already-running start, postAttach
            requires a successful --vscode open.
          - postAttachCommand runs as CLI attach at the end of up / clone / rebuild and
            after a real start. Already-running start requires a successful --vscode
            open (skip status when present and open did not succeed). postAttach non-zero
            fails command but keeps container.
          - Manual attach without a CLI apply command does not install. CLI attach
            approximation only — not IDE remote-ready. Not full extension parity.

        Clone notes:
          - Requires host git on PATH (config fetch + HTTPS credential fill)
          - Full clone runs inside the container (volume-mode workspace volume)
          - SSH: needs ssh-agent (SSH_AUTH_SOCK); create --ssh for later push
          - HTTPS: host git credential fill one-shot; guest credential.helper store
          - Auto-adds Features git:1 when config lacks git/common-utils
          - No --branch / PAT CLI / GCM-in-guest
          - Bring-up recovery: on an eligible failure (resolve/create/start/ownership/
            populate/hooks), clone retains the fetched config checkout and, in a TTY,
            prompts to edit the retained devcontainer.json and retry. Non-TTY/--json
            retains the checkout and prints an exact
            `adevcontainer clone <git-url> --resume <config-dir>` command.

        Rebuild notes:
          - Force-rebuilds a managed container from its CURRENT devcontainer.json,
            keeping the same container name and --name selection (bind) or same
            workspace volume (volume mode) — data is preserved, not re-cloned.
          - Config is read strictly before anything is deleted: unreadable/missing
            config fails with config_not_found and the old container is untouched.
          - Container-only delete of the old container; workspace and config named
            volumes are reused via ensureVolume (never deleted or replaced).
          - Config hash mismatch on up → config_hash_mismatch → rebuild (sole force-rebuild).
          - Hard post-delete failure recovery (create/start/onCreate…postStart):
            bind = host stamped config; clone-origin volume = Alpine helper + temp.
            TTY: error then "Open the recovery editor now? [Y/n]" (default Y);
            non-TTY/--json: retain + retry commands; named rebuild skips the prompt.

        Config notes:
          - Optional Apple-incompatibles (docker-* features, privileged/device runArgs,
            privileged/securityOpt metadata) are warn-skipped — up continues with a warning.
          - Docker Compose keys, unknown runArgs, and first-class smuggling still hard-error.

        Exit codes: 0 success, non-zero failure
        """
    }

    /// Per-command help text; nil when unknown (caller falls back to usage).
    public static func commandHelpText(_ subcommand: String) -> String? {
        switch subcommand {
        case "up":
            return """
            adevcontainer up [-w <path>] [--json] [--skip-pull] [--vscode]

            Create/start/reuse a bind-mode dev container for a host checkout.
            -w/--workspace defaults to the current directory (host project root). Stamps
            managed labels so the container appears in list and lifecycle commands
            (--name / picker).

            --vscode: best-effort open a new VS Code window on the remote workspace folder
            (requires VS Code with Remote - Containers and a `code` CLI). Soft-fails with
            a stderr warning; open alone does not fail up. --vscode gates open only, not
            apply. postAttach is CLI attach after waitFor (not --vscode-gated).
            Settings and extensions from customizations.vscode apply by default after
            create-path hooks (and on reuse / start-stopped when the marker is pending).
            Order with --vscode: apply → open → postAttach. Open soft-fail does not skip
            postAttach. postAttach failure fails up but keeps the container.
            Apply is soft-fail with marker skip when matched.
            Not full Dev Containers parity — manual attach remains valid.

            Bring-up recovery: when an existing config fails to resolve or create/start/
            ownership/create-path hooks fail, a TTY prompts to open the host config and retries
            from scratch. Decline/EOF fails with the original error. Non-TTY and --json never
            edit and include the host config edit/retry hint.
            """
        case "clone":
            return """
            adevcontainer clone <git-url> [--json] [--skip-pull] [--vscode] [--resume <config-dir>]

            Create a volume-mode managed dev container (workspace on a named volume).
            Host git fetches config only; full clone runs inside the container.

            SSH URLs require ssh-agent (SSH_AUTH_SOCK); create injects --ssh.
            HTTPS uses host git credential fill once, then guest credential store.
            Optional: ADEVCONTAINER_GIT_TOKEN. No PAT flags / GCM-in-guest.
            If the config has no git/common-utils feature, clone injects
            ghcr.io/devcontainers/features/git:1 for in-container git.

            --json: machine-readable success JSON (outcome, containerId, remoteUser,
            remoteWorkspaceFolder, gitUrl, workspaceVolume; optional containerName).
            Default human mode prints an indented key/value digest after Ready.

            --resume <config-dir>: skip the host git config fetch and re-resolve from a
            retained config checkout (the path printed by a prior non-TTY failure).
            Used to retry a failed clone after editing the retained devcontainer.json.

            --vscode: best-effort open VS Code on the resolved remote folder after
            success (same prereqs/soft-fail as up). postAttach is CLI attach after
            waitFor (not --vscode-gated). Settings and
            extensions from customizations.vscode apply by default after create-path
            hooks (not gated on the flag).
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
            adevcontainer start [--name <container>] [--vscode] [--json]

            Start a stopped managed container. Real start runs host initializeCommand
            (when a host workspace exists), then config postStartCommand and remelted
            feature postStart. Already running is success no-op for those hooks.

            --vscode: best-effort open VS Code on the labeled remote workspace folder after
            start (inspect for id/image/folder). Soft-fail open. postAttach runs after a
            real start even without --vscode; on already-running start it requires a
            successful --vscode open. start does not apply settings or extensions (with or
            without --vscode). If runtime start fails, a TTY prompts
            (default Y) and delegates to `rebuild --name <name>`; decline/EOF, non-TTY,
            and --json fail with that exact rebuild hint. Start never opens an editor or
            retries start. Not full extension parity.
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
        case "purge":
            return """
            adevcontainer purge [--name <container>]

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

            Force-rebuild a managed container (bind from up, volume from clone): a forced
            rebuild from the container's CURRENT devcontainer.json. Selection via
            --name / auto-single / interactive picker (same as start/delete). -w is
            usage error (up only). The rebuild command runs the forced create path.

            The old container is deleted only after the config read, host requirements
            preflight, and Features work all succeed; any failure before that leaves the
            old container untouched. The new container keeps the same name (bind) or the
            same workspace volume (volume mode) — volume data is preserved, never
            re-cloned or replaced. Container-only delete: workspace *-ws and config
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
            success (open only; same soft-fail as up). postAttach is CLI attach on the
            new container (not --vscode-gated; open soft-fail does not skip it).
            customizations.vscode settings and extensions apply by default on the new
            container after create-path hooks (not gated on the flag).
            --json: machine-readable success output (up-shape; volume mode may add
            gitUrl/workspaceVolume). Failures exit non-zero with a structured error.
            Local-path Features (`./…`) load on bind rebuild from the stamped host
            workspace, and on volume rebuild by staging the guest `.devcontainer/`
            tree (`exec tar`, not `container cp`) before Features/delete. Missing
            local packages fail structured before the old container is deleted.
            Not full extension parity.
            """
        default:
            return nil
        }
    }
}
