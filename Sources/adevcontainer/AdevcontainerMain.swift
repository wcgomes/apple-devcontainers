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
            fputs(error.formatted() + "\n", stderr)
            exit(error.exitCode)
        } catch {
            fputs("error[internal]: \(error.localizedDescription)\n", stderr)
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
        let workspace = parsed.workspace
            ?? FileManager.default.currentDirectoryPath
        let runtime = AppleContainerRuntime()

        switch subcommand {
        case "doctor":
            let report = try DoctorCommand.run(runtime: runtime)
            DoctorCommand.printReport(report)
            return 0

        case "up":
            let opts = UpOptions(
                workspacePath: workspace,
                jsonOutput: parsed.flags.contains("json"),
                recreate: parsed.flags.contains("recreate"),
                skipPull: parsed.flags.contains("skip-pull")
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
                    workspacePath: workspace,
                    command: command,
                    interactive: interactive
                ),
                runtime: runtime
            )
            return code

        case "stop":
            try StopCommand.run(workspacePath: workspace, runtime: runtime)
            return 0

        case "delete", "rm":
            try DeleteCommand.run(workspacePath: workspace, runtime: runtime)
            return 0

        case "prune":
            return try PruneCommand.run(workspacePath: workspace, runtime: runtime)

        case "inspect":
            let payload = try InspectCommand.run(workspacePath: workspace, runtime: runtime)
            print(try payload.jsonString())
            return 0

        case "version", "--version":
            print("adevcontainer 0.1.0")
            return 0

        default:
            throw CLIError(
                code: CLIErrorCode.usage,
                message: "Unknown subcommand '\(subcommand)'",
                hint: "Try: doctor | up | exec | stop | delete | prune | inspect"
            )
        }
    }

    struct ParsedArgs {
        var workspace: String?
        var flags: Set<String>
        var passthrough: [String]
    }

    static func parseGlobalOptions(_ args: [String]) throws -> ParsedArgs {
        var workspace: String?
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
            if a.hasPrefix("-") {
                throw CLIError(
                    code: CLIErrorCode.usage,
                    property: a,
                    message: "Unknown option '\(a)'"
                )
            }
            // bare args become passthrough (exec command without --)
            passthrough.append(a)
            i += 1
        }

        return ParsedArgs(workspace: workspace, flags: flags, passthrough: passthrough)
    }

    static func printUsage() {
        let text = """
        adevcontainer — Apple container devcontainer CLI

        Usage:
          adevcontainer <command> [options]

        Commands:
          doctor              Check Apple container runtime readiness
          up                  Create/start/reuse workspace container
          exec [-it] [--] [cmd...]  Run a command (or interactive shell) in the container
          stop                Stop the workspace container
          delete              Remove the workspace container
          prune               Remove container, named volumes, and config image
          inspect             Show identity, state, labels, portsAttributes

        Options:
          -w, --workspace <path>   Workspace root (default: cwd)
          --json                   Machine-readable output (up)
          --recreate               Delete and recreate on up if exists / hash mismatch
          --skip-pull              Skip image pull on up
          -h, --help               Show help

        Exit codes: 0 success, non-zero failure
        """
        print(text)
    }
}
