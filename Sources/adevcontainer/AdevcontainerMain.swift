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
        let parsed = try CommandSurface.parseArgs(rest)
        let runtime = AppleContainerRuntime()

        // -w / --workspace is only valid for `up` (bind-mode create).
        try CommandSurface.enforceWorkspaceGate(subcommand: subcommand, parsed: parsed)

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

        case "rebuild":
            let opts = parsed.rebuildOptions()
            let result = try RebuildCommand.run(options: opts, runtime: runtime)
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

        case "version", "--version":
            print("adevcontainer \(AppVersion.current)")
            return 0

        default:
            throw CLIError(
                code: CLIErrorCode.usage,
                message: "Unknown subcommand '\(subcommand)'",
                hint: "Try: doctor | up | clone | rebuild | list | start | exec | stop | delete | prune | inspect"
            )
        }
    }

    static func printUsage() {
        print(CommandSurface.usageText())
    }

    static func printCommandHelp(_ subcommand: String) {
        if let text = CommandSurface.commandHelpText(subcommand) {
            print(text)
        } else {
            printUsage()
        }
    }
}
