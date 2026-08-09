import Foundation
import ADevContainerLib

@main
struct AdevcontainerMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            let code = try dispatch(args: args)
            exit(code)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data((error.formatted() + "\n").utf8))
            exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data(("error[internal]: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    static func dispatch(args: [String]) throws -> Int32 {
        if args.isEmpty || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
            printUsage()
            return args.isEmpty ? 1 : 0
        }

        let (subcommand, rest) = (args[0], Array(args.dropFirst()))
        let parsed = try parseGlobalOptions(rest)
        let runtime = AppleContainerRuntime()

        // -w / --workspace is only valid for `up` (bind-mode create).
        if parsed.workspace != nil, subcommand != "up" {
            throw CLIError(
                code: CLIErrorCode.usage,
                property: "-w",
                message: "-w is only valid for up",
                hint: "Lifecycle commands use --name (or picker). Create with: adevcontainer up [-w <path>]"
            )
        }

        let defaultWorkspace = parsed.workspace ?? FileManager.default.currentDirectoryPath

        if parsed.flags.contains("help") {
            printCommandHelp(subcommand)
            return 0
        }

        switch subcommand {
        case "doctor":
            let report = try DoctorCommand.run(runtime: runtime)
            DoctorCommand.printReport(report)
            return 0

        case "up":
            let opts = UpOptions(
                workspacePath: defaultWorkspace,
                jsonOutput: parsed.flags.contains("json"),
                recreate: parsed.flags.contains("recreate"),
                skipPull: parsed.flags.contains("skip-pull"),
                openVSCode: parsed.flags.contains("vscode")
            )
            let result = try UpCommand.run(options: opts, runtime: runtime)
            if opts.jsonOutput {
                print(try result.jsonString())
            } else {
                print("outcome: \(result.outcome)")
                print("containerId: \(result.containerId)")
                print("remoteUser: \(result.remoteUser)")
                print("remoteWorkspaceFolder: \(result.remoteWorkspaceFolder)")
                if let name = result.containerName {
                    print("containerName: \(name)")
                }
            }
            return 0

        case "clone":
            // URL-only: single positional; reject unknown flags already via parseGlobalOptions.
            guard parsed.passthrough.count == 1 else {
                throw CLIError(
                    code: CLIErrorCode.usage,
                    message: parsed.passthrough.isEmpty
                        ? "clone requires a git URL"
                        : "clone accepts only a single git URL argument",
                    hint: "Usage: adevcontainer clone <git-url>"
                )
            }
            let result = try CloneCommand.run(
                options: CloneOptions(
                    gitURL: parsed.passthrough[0],
                    skipPull: parsed.flags.contains("skip-pull"),
                    openVSCode: parsed.flags.contains("vscode")
                ),
                runtime: runtime
            )
            // Always machine-readable JSON on success (spec).
            print(try result.jsonString())
            return 0

        case "list":
            let output = try ListCommand.run(
                options: ListOptions(jsonOutput: parsed.flags.contains("json")),
                runtime: runtime
            )
            print(output)
            return 0

        case "start":
            try StartCommand.run(
                options: StartOptions(
                    name: parsed.name,
                    openVSCode: parsed.flags.contains("vscode")
                ),
                runtime: runtime
            )
            return 0

        case "exec":
            let command = parsed.passthrough
            let interactive =
                command.isEmpty
                || parsed.flags.contains("interactive")
                || parsed.flags.contains("i")
                || parsed.flags.contains("t")
                || parsed.flags.contains("tty")
            let code = try ExecCommand.run(
                options: ExecOptions(
                    command: command,
                    interactive: interactive,
                    name: parsed.name
                ),
                runtime: runtime
            )
            return code

        case "stop":
            try StopCommand.run(
                name: parsed.name,
                runtime: runtime
            )
            return 0

        case "delete", "rm":
            try DeleteCommand.run(
                name: parsed.name,
                runtime: runtime
            )
            return 0

        case "prune":
            return try PruneCommand.run(
                name: parsed.name,
                runtime: runtime
            )

        case "inspect":
            let payload = try InspectCommand.run(name: parsed.name, runtime: runtime)
            print(try payload.jsonString())
            return 0

        case "version", "--version":
            print("adevcontainer \(AppVersion.current)")
            return 0

        default:
            throw CLIError(
                code: CLIErrorCode.usage,
                message: "Unknown subcommand '\(subcommand)'",
                hint: "Try: doctor | up | clone | list | start | exec | stop | delete | prune | inspect"
            )
        }
    }

    struct ParsedArgs {
        var workspace: String?
        var name: String?
        var flags: Set<String>
        var passthrough: [String]
    }

    static func parseGlobalOptions(_ args: [String]) throws -> ParsedArgs {
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
            if a == "--recreate" {
                flags.insert("recreate")
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

    static func printUsage() {
        let text = """
        adevcontainer — Apple container devcontainer CLI

        Usage:
          adevcontainer <command> [options]

        Commands:
          doctor              Check Apple container runtime readiness
          up [-w path]        Create/start/reuse bind-mode workspace (host path)
          clone <git-url>     Clone repo into named volume workspace (managed)
          list [--json]       List managed containers (up + clone)
          start [--name]      Start a stopped managed container (no hooks on volume-mode)
          exec [-it] [--name] [--] [cmd...]  Run a command (or shell) in a managed container
          stop [--name]       Stop a managed container (name or picker)
          delete [--name]     Remove container only (not workspace volume)
          prune [--name]      Remove container, volumes (incl. *-ws), and config image
          inspect [--name]    Show identity, state, labels (from runtime + labels)

        Options:
          -w, --workspace <path>   Workspace root for `up` only (default: cwd)
          --name <container>       Managed container name/id (exec/start/stop/delete/prune/inspect)
          --json                   Machine-readable output (up, list)
          --recreate               Delete and recreate on up if exists / hash mismatch
          --skip-pull              Skip image pull on up/clone
          --vscode                 Best-effort open VS Code; gates postAttach + extensions apply
          -h, --help               Show help

        Identity:
          - `up` is the only command that accepts -w/--workspace (bind-mode create).
          - Lifecycle commands resolve via --name or an interactive picker among
            containers labeled devcontainer.managed=adevcontainer (both bind and volume).
          - Passing -w to a non-up command is a usage error.

        VS Code (--vscode on up/start/clone):
          - Best-effort open of a new window on the resolved remote workspace folder.
          - Requires host VS Code + Remote - Containers + experimental Apple support
            (dev.containers.experimentalAppleContainerSupport) and a discoverable `code` CLI.
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

        Exit codes: 0 success, non-zero failure
        """
        print(text)
    }

    static func printCommandHelp(_ subcommand: String) {
        switch subcommand {
        case "up":
            print("""
            adevcontainer up [-w <path>] [--json] [--recreate] [--skip-pull] [--vscode]

            Create/start/reuse a bind-mode workspace container for a host checkout.
            -w/--workspace defaults to the current directory. Stamps managed labels
            so the container appears in list and lifecycle commands (--name / picker).

            --vscode: best-effort open a new VS Code window on the remote workspace
            (requires VS Code + Remote - Containers + experimental Apple support and
            a `code` CLI). Soft-fails with a stderr warning; open alone does not fail up.
            postAttachCommand runs only after successful open; skipped without flag /
            open soft-fail; postAttach failure fails up but keeps the container.
            customizations.vscode.settings apply on create-path (not gated on open);
            extensions apply after successful open (soft-fail; marker skip when matched).
            Not full Dev Containers parity — manual attach remains valid.
            """)
        case "clone":
            print("""
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
            """)
        case "list":
            print("""
            adevcontainer list [--json]

            List containers with label devcontainer.managed=adevcontainer
            (bind-mode from up and volume-mode from clone).
            """)
        case "start":
            print("""
            adevcontainer start [--name <container>] [--vscode]

            Start a stopped managed container. Volume-mode: runtime start only
            (no lifecycle hooks). Already running is success no-op.

            --vscode: best-effort open VS Code on the labeled remote workspace after
            start (inspect for id/image/folder). Soft-fail open; postAttach and pending
            extensions only after successful open (same gate as up). Settings repair on
            marker drift does not require the flag. Not full extension parity.
            """)
        case "exec":
            print("""
            adevcontainer exec [-it] [--name <container>] [--] [cmd...]

            Run a command, or interactive shell when cmd is omitted.
            Resolves a managed container via --name or picker (no -w).
            User/workdir come from labels stamped at up/clone create.
            """)
        case "stop":
            print("""
            adevcontainer stop [--name <container>]

            Stop a managed container via --name or interactive picker.
            -w is not accepted (use up only for workspace path).
            """)
        case "delete", "rm":
            print("""
            adevcontainer delete [--name <container>]

            Remove the managed container only (not volumes or images).
            """)
        case "prune":
            print("""
            adevcontainer prune [--name <container>]

            Remove managed container, config named volumes (label), volume-mode
            workspace volume (*-ws), and config image. Selection via --name/picker.
            """)
        case "inspect":
            print("""
            adevcontainer inspect [--name <container>]

            Show identity, state, and labels from runtime + managed labels.
            """)
        default:
            printUsage()
        }
    }
}
