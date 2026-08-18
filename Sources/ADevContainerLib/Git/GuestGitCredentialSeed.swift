import Foundation

/// Create-path seeding of the connection user's git credential store in the container.
///
/// Bind mode enumerates the host workspace's unique HTTPS fetch remotes via
/// `git -C <hostWorkspace> remote -v`; volume mode seeds from the single stamped
/// `devcontainer.git_url`. Credentials are acquired on the host through the shared
/// `GitCredentialProviding` contract and transferred into the container via exec stdin —
/// never argv or environment. Silent no-op (no warning, no exec) when host git is missing, the
/// workspace has no remotes, fill returns nil, or the stamped URL is missing/empty.
/// In-container failures throw (callers soft-fail with a warning).
public struct GuestGitCredentialSeed {
    public var credentials: any GitCredentialProviding
    public var runner: any ProcessRunning
    /// Override PATH lookup for tests (`nil` outer → real lookup; `.some(nil)` → missing git).
    public var gitPathOverride: String??

    public init(
        credentials: any GitCredentialProviding = HostGitCredential(),
        runner: any ProcessRunning = FoundationProcessRunner(),
        gitPathOverride: String?? = nil
    ) {
        self.credentials = credentials
        self.runner = runner
        self.gitPathOverride = gitPathOverride
    }

    /// Seed the store in `containerId` as `connectionUser`. `hostWorkspace` and `gitURL`
    /// select bind vs volume discovery (exactly one is provided by callers).
    public func seed(
        containerId: String,
        hostWorkspace: String?,
        gitURL: String?,
        connectionUser: String?,
        runtime: AppleContainerRuntime
    ) throws {
        let urls: [String]
        let workspace = hostWorkspace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stamped = gitURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !workspace.isEmpty {
            urls = bindFetchURLs(hostWorkspace: workspace)
        } else if !stamped.isEmpty {
            urls = [stamped]
        } else {
            return
        }

        var entries: [Entry] = []
        for url in urls {
            guard GitURLClassifier.kind(of: url) == .https,
                  let fields = GitURLClassifier.httpsCredentialFields(for: url)
            else {
                continue
            }
            let creds: GitHTTPSCredentials?
            do {
                creds = try credentials.fillHTTPS(url: url)
            } catch {
                continue
            }
            guard let creds else {
                continue
            }
            let entry = Entry(
                protocolName: fields.protocolName,
                host: fields.host,
                username: creds.username,
                password: creds.password
            )
            if !entries.contains(where: {
                $0.protocolName == entry.protocolName
                    && $0.host == entry.host
                    && $0.username == entry.username
            }) {
                entries.append(entry)
            }
        }
        guard !entries.isEmpty else { return }

        let input = entries.map { entry in
            "protocol=\(entry.protocolName)\nhost=\(entry.host)\nusername=\(entry.username)\npassword=\(entry.password)\n\n"
        }.joined()

        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-c", Self.seedScript()],
            user: connectionUser,
            env: [:],
            stdinData: Data(input.utf8)
        )
        guard result.succeeded else {
            let safeHosts = entries.map(\.host).filter {
                $0.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
            }
            let detail = safeHosts.isEmpty ? "" : ": host=\(safeHosts.joined(separator: ","))"
            throw CLIError(
                code: CLIErrorCode.lifecycleFailed,
                message: "Failed to seed git credentials in the container (exit \(result.exitCode))\(detail)",
                hint: "Ensure in-container git is installed; the container still works without forwarded credentials"
            )
        }
    }

    /// Unique fetch URLs from `git remote -v` output (`<name>\t<url> (fetch)` lines).
    static func uniqueFetchURLs(from output: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.hasSuffix("(fetch)") else { continue }
            let trimmed = String(text.dropLast("(fetch)".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == "\t" || $0 == " " }
            )
            guard parts.count >= 2 else { continue }
            let url = String(parts[1])
            guard !url.isEmpty, !seen.contains(url) else { continue }
            seen.insert(url)
            result.append(url)
        }
        return result
    }

    /// The in-container POSIX-sh credential helper (get/store/erase) that the seed
    /// script writes to `$HOME/.adevcontainer/git-credential-adev` (mode 0700) and
    /// appends via `git config --global --add credential.helper`. `get` matches the
    /// persisted store by (protocol, host) ignoring the queried username; `store`
    /// persists to `$HOME/.adevcontainer/git-credentials` (mode 0600) deduped by
    /// (protocol, host, username); `erase` is a no-op. Store format: one
    /// protocol/host/username/password key block per entry, blank-line terminated
    /// (git's own credential protocol shape), so raw values round-trip losslessly.
    static func helperScript() -> String {
        [
            "#!/bin/sh",
            "set -e",
            "DIR=\"$HOME/.adevcontainer\"",
            "STORE=\"$DIR/git-credentials\"",
            "qproto=\"\"",
            "qhost=\"\"",
            "quser=\"\"",
            "qpass=\"\"",
            "while IFS= read -r line || [ -n \"$line\" ]; do",
            "  case \"$line\" in",
            "  *=*)",
            "    key=${line%%=*}",
            "    val=${line#*=}",
            "    case \"$key\" in",
            "    protocol) qproto=\"$val\" ;;",
            "    host) qhost=\"$val\" ;;",
            "    username) quser=\"$val\" ;;",
            "    password) qpass=\"$val\" ;;",
            "    esac",
            "    ;;",
            "  esac",
            "done",
            "case \"${1:-}\" in",
            "get)",
            "  [ -n \"$qproto\" ] && [ -n \"$qhost\" ] || exit 0",
            "  [ -f \"$STORE\" ] || exit 0",
            "  sp=\"\"",
            "  sh=\"\"",
            "  su=\"\"",
            "  spw=\"\"",
            "  emit() {",
            "    if [ -n \"$quser\" ]; then",
            "      outuser=\"$quser\"",
            "    else",
            "      outuser=\"$su\"",
            "    fi",
            "    printf 'protocol=%s\\nhost=%s\\nusername=%s\\npassword=%s\\n\\n' \"$sp\" \"$sh\" \"$outuser\" \"$spw\"",
            "    exit 0",
            "  }",
            "  while IFS= read -r line || [ -n \"$line\" ]; do",
            "    case \"$line\" in",
            "    \"\")",
            "      if [ \"$sp\" = \"$qproto\" ] && [ \"$sh\" = \"$qhost\" ]; then",
            "        emit",
            "      fi",
            "      sp=\"\"",
            "      sh=\"\"",
            "      su=\"\"",
            "      spw=\"\"",
            "      ;;",
            "    *=*)",
            "      key=${line%%=*}",
            "      val=${line#*=}",
            "      case \"$key\" in",
            "      protocol) sp=\"$val\" ;;",
            "      host) sh=\"$val\" ;;",
            "      username) su=\"$val\" ;;",
            "      password) spw=\"$val\" ;;",
            "      esac",
            "      ;;",
            "    esac",
            "  done < \"$STORE\"",
            "  if [ \"$sp\" = \"$qproto\" ] && [ \"$sh\" = \"$qhost\" ]; then",
            "    emit",
            "  fi",
            "  exit 0",
            "  ;;",
            "store)",
            "  [ -n \"$qproto\" ] && [ -n \"$qhost\" ] || exit 0",
            "  mkdir -p \"$DIR\"",
            "  tmp=\"$STORE.tmp\"",
            "  : > \"$tmp\"",
            "  chmod 600 \"$tmp\"",
            "  if [ -f \"$STORE\" ]; then",
            "    sp=\"\"",
            "    sh=\"\"",
            "    su=\"\"",
            "    spw=\"\"",
            "    keep() {",
            "      printf 'protocol=%s\\nhost=%s\\nusername=%s\\npassword=%s\\n\\n' \"$sp\" \"$sh\" \"$su\" \"$spw\" >> \"$tmp\"",
            "    }",
            "    while IFS= read -r line || [ -n \"$line\" ]; do",
            "      case \"$line\" in",
            "      \"\")",
            "        if [ \"$sp\" = \"$qproto\" ] && [ \"$sh\" = \"$qhost\" ] && [ \"$su\" = \"$quser\" ]; then",
            "          :",
            "        else",
            "          keep",
            "        fi",
            "        sp=\"\"",
            "        sh=\"\"",
            "        su=\"\"",
            "        spw=\"\"",
            "        ;;",
            "      *=*)",
            "        key=${line%%=*}",
            "        val=${line#*=}",
            "        case \"$key\" in",
            "        protocol) sp=\"$val\" ;;",
            "        host) sh=\"$val\" ;;",
            "        username) su=\"$val\" ;;",
            "        password) spw=\"$val\" ;;",
            "        esac",
            "        ;;",
            "      esac",
            "    done < \"$STORE\"",
            "    if [ -n \"$sp\" ] || [ -n \"$sh\" ]; then",
            "      if [ \"$sp\" = \"$qproto\" ] && [ \"$sh\" = \"$qhost\" ] && [ \"$su\" = \"$quser\" ]; then",
            "        :",
            "      else",
            "        keep",
            "      fi",
            "    fi",
            "  fi",
            "  printf 'protocol=%s\\nhost=%s\\nusername=%s\\npassword=%s\\n\\n' \"$qproto\" \"$qhost\" \"$quser\" \"$qpass\" >> \"$tmp\"",
            "  chmod 600 \"$tmp\"",
            "  mv \"$tmp\" \"$STORE\"",
            "  exit 0",
            "  ;;",
            "erase)",
            "  exit 0",
            "  ;;",
            "esac",
            "exit 0"
        ].joined(separator: "\n")
    }

    /// One in-container script: write the username-agnostic credential helper to the
    /// connection user's home, append it via `git config --global --add`, then approve
    /// one entry per stdin credential block. Entries travel via stdin — never argv or env.
    static func seedScript() -> String {
        [
            "set -e",
            "uid=\"$(id -u 2>/dev/null)\"",
            "resolved_home=\"\"",
            "if command -v getent >/dev/null 2>&1; then",
            "  if passwd_entry=$(getent passwd \"$uid\" 2>/dev/null); then",
            "    old_ifs=$IFS",
            "    IFS=:",
            "    read -r _ _ _ _ _ resolved_home _ <<EOF",
            "$passwd_entry",
            "EOF",
            "    IFS=$old_ifs",
            "  fi",
            "fi",
            "if [ -z \"$resolved_home\" ] && [ -r /etc/passwd ]; then",
            "  while IFS=: read -r passwd_name passwd_password passwd_uid passwd_gid passwd_gecos passwd_home passwd_shell; do",
            "    if [ \"$passwd_uid\" = \"$uid\" ]; then",
            "      resolved_home=\"$passwd_home\"",
            "      break",
            "    fi",
            "  done < /etc/passwd 2>/dev/null",
            "fi",
            "[ -n \"$resolved_home\" ] || exit 1",
            "if [ ! -d \"$resolved_home\" ]; then",
            "  mkdir -p \"$resolved_home\" 2>/dev/null || exit 1",
            "fi",
            "[ -d \"$resolved_home\" ] || exit 1",
            "HOME=\"$resolved_home\"",
            "export HOME",
            "HELPER=\"$HOME/.adevcontainer/git-credential-adev\"",
            "mkdir -p \"$HOME/.adevcontainer\" 2>/dev/null",
            "cat > \"$HELPER\" 2>/dev/null <<'ADEV_HELPER_EOF'",
            Self.helperScript(),
            "ADEV_HELPER_EOF",
            "chmod 700 \"$HELPER\" 2>/dev/null",
            "git config --global --add credential.helper \"$HELPER\" >/dev/null 2>&1",
            "protocol=\"\"",
            "host=\"\"",
            "username=\"\"",
            "password=\"\"",
            "approve() {",
            "  [ -n \"$protocol\" ] && [ -n \"$host\" ] || return 0",
            "  printf 'protocol=%s\\nhost=%s\\nusername=%s\\npassword=%s\\n\\n' \"$protocol\" \"$host\" \"$username\" \"$password\" | git credential approve >/dev/null 2>&1",
            "}",
            "while IFS= read -r line; do",
            "  case \"$line\" in",
            "  \"\")",
            "    approve",
            "    protocol=\"\"",
            "    host=\"\"",
            "    username=\"\"",
            "    password=\"\"",
            "    ;;",
            "  *=*)",
            "    key=${line%%=*}",
            "    value=${line#*=}",
            "    case \"$key\" in",
            "    protocol) protocol=\"$value\" ;;",
            "    host) host=\"$value\" ;;",
            "    username) username=\"$value\" ;;",
            "    password) password=\"$value\" ;;",
            "    esac",
            "    ;;",
            "  esac",
            "done",
            "approve"
        ].joined(separator: "\n")
    }

    private func bindFetchURLs(hostWorkspace: String) -> [String] {
        guard let git = resolveGitPath() else {
            return []
        }
        let result: ProcessResult
        do {
            result = try runner.run(
                executable: git,
                arguments: ["-C", hostWorkspace, "remote", "-v"],
                environment: nil,
                currentDirectory: nil
            )
        } catch {
            return []
        }
        guard result.succeeded else {
            return []
        }
        return Self.uniqueFetchURLs(from: result.stdoutString)
    }

    private func resolveGitPath() -> String? {
        if let override = gitPathOverride {
            return override
        }
        return HostGitClient.whichGit()
    }

    private struct Entry {
        let protocolName: String
        let host: String
        let username: String
        let password: String
    }
}
