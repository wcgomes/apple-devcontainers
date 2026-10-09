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
///
/// The guest helper matches protocol+host and ignores path, so a later `git fetch`
/// still hits the imported credential when the query includes a path. An expired
/// JWT is a miss and is removed so it is not replayed. `erase` removes the matching
/// protocol+host entries.
/// Non-Azure hosts keep the append-only global helper. `dev.azure.com` gets a
/// URL-scoped helper (empty values removed, product helper exactly once) and
/// `useHttpPath`, so other hosts are unchanged and an inherited GCM cannot abort
/// that host. Host `credential.helper` is never copied into the guest.
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
    /// Returns false on a silent skip (no URL, no fill); throws only on exec failure.
    @discardableResult
    public func seed(
        containerId: String,
        hostWorkspace: String?,
        gitURL: String?,
        connectionUser: String?,
        runtime: AppleContainerRuntime
    ) throws -> Bool {
        let urls: [String]
        let workspace = hostWorkspace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stamped = gitURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !workspace.isEmpty {
            urls = bindFetchURLs(hostWorkspace: workspace)
        } else if !stamped.isEmpty {
            urls = [stamped]
        } else {
            return false
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
        guard !entries.isEmpty else { return false }
        try install(
            containerId: containerId,
            entries: entries,
            connectionUser: connectionUser,
            runtime: runtime
        )
        return true
    }

    /// Bind uses the host workspace; volume uses the stamped git URL.
    /// A `volume://` local folder is not a host path.
    public static func credentialSources(
        from labels: [String: String]
    ) -> (hostWorkspace: String?, gitURL: String?) {
        let mode = labels[ContainerIdentity.labelWorkspaceMode]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gitURL = nonEmpty(labels[ContainerIdentity.labelGitURL])
        if mode == ContainerIdentity.workspaceModeVolume {
            return (nil, gitURL)
        }
        let folder = labels[ContainerIdentity.labelLocalFolder]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if folder.isEmpty || folder.hasPrefix("volume://") {
            return (nil, gitURL)
        }
        return (folder, nil)
    }

    public static func connectionUser(from labels: [String: String]) -> String? {
        nonEmpty(labels[ContainerIdentity.labelRemoteUser])
    }

    /// Re-seed a running container. Does not start, stop, fetch, pull, or push.
    @discardableResult
    public func seedFromLabels(
        containerId: String,
        labels: [String: String],
        connectionUser: String?,
        runtime: AppleContainerRuntime
    ) throws -> Bool {
        let sources = Self.credentialSources(from: labels)
        return try seed(
            containerId: containerId,
            hostWorkspace: sources.hostWorkspace,
            gitURL: sources.gitURL,
            connectionUser: connectionUser,
            runtime: runtime
        )
    }

    /// Soft-fail refresh for a real start and `up` start-stopped.
    /// Never deletes the container, fails the caller, or enters recovery.
    public static func refreshSoft(
        containerId: String,
        labels: [String: String],
        connectionUser: String?,
        runtime: AppleContainerRuntime,
        credentials: any GitCredentialProviding
    ) {
        do {
            try GuestGitCredentialSeed(
                credentials: credentials,
                runner: LifecycleRunner.hostProcessRunnerOverride ?? FoundationProcessRunner()
            ).seedFromLabels(
                containerId: containerId,
                labels: labels,
                connectionUser: connectionUser,
                runtime: runtime
            )
        } catch {
            let detail = (error as? CLIError)?.message ?? error.localizedDescription
            StatusPrinter.warning(
                "Git credential refresh failed; continuing without forwarded credentials: \(detail)"
            )
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Install the guest helper and approve one credential clone already filled on the host.
    /// Does not call `fillHTTPS` again. Non-HTTPS URLs are a silent no-op.
    public func installHTTPSCredential(
        containerId: String,
        url: String,
        credentials: GitHTTPSCredentials,
        connectionUser: String?,
        runtime: AppleContainerRuntime
    ) throws {
        guard GitURLClassifier.kind(of: url) == .https,
              let fields = GitURLClassifier.httpsCredentialFields(for: url)
        else {
            return
        }
        try install(
            containerId: containerId,
            entries: [
                Entry(
                    protocolName: fields.protocolName,
                    host: fields.host,
                    username: credentials.username,
                    password: credentials.password
                )
            ],
            connectionUser: connectionUser,
            runtime: runtime
        )
    }

    /// True only for the Azure DevOps host that keeps the organization in the URL path.
    public static func isAzureDevOpsHost(_ host: String) -> Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "dev.azure.com"
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

    /// POSIX-sh helpers injected ahead of the action `case`. Expired-JWT removal and
    /// erase share one atomic rewrite. Decode failures stay silent and are not a miss.
    static func helperSupportScript() -> String {
        #"""
drop_blocks() {
  mode="$1"
  dproto="$2"
  dhost="$3"
  duser="${4-}"
  [ -f "$STORE" ] || return 0
  mkdir -p "$DIR"
  tmp="$STORE.tmp"
  : > "$tmp"
  chmod 600 "$tmp"
  dp=""
  dh=""
  du=""
  dpw=""
  flush_drop() {
    [ -n "$dp" ] || [ -n "$dh" ] || return 0
    drop=0
    if [ "$dp" = "$dproto" ] && [ "$dh" = "$dhost" ]; then
      if [ "$mode" = "host" ] || [ "$du" = "$duser" ]; then
        drop=1
      fi
    fi
    if [ "$drop" -eq 0 ]; then
      printf 'protocol=%s\nhost=%s\nusername=%s\npassword=%s\n\n' "$dp" "$dh" "$du" "$dpw" >> "$tmp"
    fi
    dp=""
    dh=""
    du=""
    dpw=""
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "")
      flush_drop
      ;;
    *=*)
      key=${line%%=*}
      val=${line#*=}
      case "$key" in
      protocol) dp="$val" ;;
      host) dh="$val" ;;
      username) du="$val" ;;
      password) dpw="$val" ;;
      esac
      ;;
    esac
  done < "$STORE"
  flush_drop
  chmod 600 "$tmp"
  mv "$tmp" "$STORE"
}
jwt_expired() {
  pw=$1
  case "$pw" in
  *.*.*) ;;
  *) return 1 ;;
  esac
  seg1=${pw%%.*}
  rest=${pw#*.}
  seg2=${rest%%.*}
  seg3=${rest#*.}
  [ -n "$seg1" ] && [ -n "$seg2" ] && [ -n "$seg3" ] || return 1
  case "$seg3" in
  *.*) return 1 ;;
  esac
  payload=$(printf '%s' "$seg2" | LC_ALL=C tr '_-' '/+' 2>/dev/null) || return 1
  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
    1) return 1 ;;
  esac
  json=""
  if command -v base64 >/dev/null 2>&1; then
    if probe=$(printf 'YQ==' | base64 -d 2>/dev/null) && [ "$probe" = "a" ]; then
      json=$(printf '%s' "$payload" | base64 -d 2>/dev/null) || json=""
    elif probe=$(printf 'YQ==' | base64 -D 2>/dev/null) && [ "$probe" = "a" ]; then
      json=$(printf '%s' "$payload" | base64 -D 2>/dev/null) || json=""
    fi
  fi
  if [ -z "$json" ] && command -v openssl >/dev/null 2>&1; then
    if probe=$(printf 'YQ==' | openssl base64 -d -A 2>/dev/null) && [ "$probe" = "a" ]; then
      json=$(printf '%s' "$payload" | openssl base64 -d -A 2>/dev/null) || json=""
    fi
  fi
  [ -n "$json" ] || return 1
  rest=$(printf '%s' "$json" | LC_ALL=C tr -d '\n' 2>/dev/null) || return 1
  exp=""
  while :; do
    case "$rest" in
    *'"exp"'*) rest=${rest#*'"exp"'} ;;
    *) break ;;
    esac
    while :; do
      case "$rest" in
      [[:space:]]*) rest=${rest#?} ;;
      *) break ;;
      esac
    done
    case "$rest" in
    ':'*) rest=${rest#:} ;;
    *) continue ;;
    esac
    while :; do
      case "$rest" in
      [[:space:]]*) rest=${rest#?} ;;
      *) break ;;
      esac
    done
    exp=""
    while :; do
      case "$rest" in
      [0-9]*)
        exp="${exp}${rest%"${rest#?}"}"
        rest=${rest#?}
        ;;
      *) break ;;
      esac
    done
    [ -n "$exp" ] && break
  done
  [ -n "$exp" ] || return 1
  now=$(date +%s 2>/dev/null) || return 1
  case "$now" in
  ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$exp" -le "$((now + 60))" ]; then
    return 0
  fi
  return 1
}
"""#
    }

    /// The in-container POSIX-sh credential helper (get/store/erase) that the seed
    /// script writes to `$HOME/.adevcontainer/git-credential-adev` (mode 0700).
    /// `get` matches the persisted store by (protocol, host), ignoring the queried
    /// username and path so `credential.useHttpPath` queries still hit the imported
    /// credential. A JWT whose `exp` is within 60 seconds is a miss and that store
    /// entry is removed; non-JWTs and undecodable tokens are returned as stored.
    /// `store` persists to `$HOME/.adevcontainer/git-credentials` (mode 0600) deduped
    /// by (protocol, host, username). `erase` removes protocol+host entries with an
    /// atomic rewrite (mode 0600). Store format: one protocol/host/username/password
    /// key block per entry, blank-line terminated, so raw values round-trip.
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
            "    if jwt_expired \"$spw\" 2>/dev/null; then",
            "      drop_blocks user \"$sp\" \"$sh\" \"$su\"",
            "      exit 0",
            "    fi",
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
            "  [ -n \"$qproto\" ] && [ -n \"$qhost\" ] || exit 0",
            "  [ -f \"$STORE\" ] || exit 0",
            "  drop_blocks host \"$qproto\" \"$qhost\"",
            "  exit 0",
            "  ;;",
            "esac",
            "exit 0"
        ].joined(separator: "\n")
            .replacingOccurrences(
                of: "done\ncase \"${1:-}\" in",
                with: "done\n\(Self.helperSupportScript())\ncase \"${1:-}\" in"
            )
    }

    /// One in-container script: write the username-agnostic credential helper, then
    /// approve stdin blocks. `appendGlobalHelper` is the non-Azure path
    /// (`git config --global --add`). `configureAzureHost` ensures the product helper
    /// is the only empty-free `dev.azure.com` URL-scoped helper and sets `useHttpPath`.
    /// Never writes an empty URL-scoped helper and never resets the global helper list.
    /// Entries travel via stdin — never argv or env.
    static func seedScript(appendGlobalHelper: Bool = true, configureAzureHost: Bool = false) -> String {
        var lines = [
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
        ]
        if appendGlobalHelper {
            lines.append("git config --global --add credential.helper \"$HELPER\" >/dev/null 2>&1")
        }
        if configureAzureHost {
            // Drop an empty URL-scoped helper (it resets the chain) and keep every
            // other value. The product helper is present exactly once. Do not reset
            // the global credential.helper list.
            lines += [
                "azure_key=\"credential.https://dev.azure.com.helper\"",
                "azure_list=\"$HOME/.adevcontainer/.azure-helper-values\"",
                ": > \"$azure_list\"",
                "chmod 600 \"$azure_list\"",
                "git config --global --get-all \"$azure_key\" > \"$azure_list\" 2>/dev/null || true",
                "git config --global --unset-all \"$azure_key\" >/dev/null 2>&1 || true",
                "azure_seen=0",
                "while IFS= read -r azure_value || [ -n \"$azure_value\" ]; do",
                "  [ -n \"$azure_value\" ] || continue",
                "  if [ \"$azure_value\" = \"$HELPER\" ]; then",
                "    if [ \"$azure_seen\" -eq 0 ]; then",
                "      git config --global --add \"$azure_key\" \"$azure_value\" >/dev/null 2>&1",
                "      azure_seen=1",
                "    fi",
                "    continue",
                "  fi",
                "  git config --global --add \"$azure_key\" \"$azure_value\" >/dev/null 2>&1",
                "done < \"$azure_list\"",
                "rm -f \"$azure_list\"",
                "if [ \"$azure_seen\" -eq 0 ]; then",
                "  git config --global --add \"$azure_key\" \"$HELPER\" >/dev/null 2>&1",
                "fi",
                "git config --global credential.https://dev.azure.com.useHttpPath true >/dev/null 2>&1",
            ]
        }
        lines += [
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
        ]
        return lines.joined(separator: "\n")
    }

    private func install(
        containerId: String,
        entries: [Entry],
        connectionUser: String?,
        runtime: AppleContainerRuntime
    ) throws {
        guard !entries.isEmpty else { return }

        let input = entries.map { entry in
            "protocol=\(entry.protocolName)\nhost=\(entry.host)\nusername=\(entry.username)\npassword=\(entry.password)\n\n"
        }.joined()

        let azure = entries.contains { Self.isAzureDevOpsHost($0.host) }
        let other = entries.contains { !Self.isAzureDevOpsHost($0.host) }
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-c", Self.seedScript(appendGlobalHelper: other, configureAzureHost: azure)],
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
