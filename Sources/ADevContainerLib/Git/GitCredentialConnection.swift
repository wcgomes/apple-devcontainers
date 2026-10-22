import Foundation
import Crypto

struct GitCredentialConnection: GitCredentialConnecting {
    typealias Control = @Sendable (GitCredentialControlRequest, Bool, TimeInterval) throws -> Bool
    let runtime: AppleContainerRuntime
    let control: Control
    let hostRunner: any ProcessRunning
    let gitPathOverride: String??
    let token: String?
    let timeout: TimeInterval
    private let installationLock: @Sendable (TimeInterval) throws -> GitCredentialServiceLock?
    static func namespace(_ context: GitCredentialRuntimeContext) -> String {
        let material = [context.id, context.incarnation, context.user, context.platform].joined(separator: "\0")
        return "s-" + Data(SHA256.hash(data: Data(material.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init(runtime: AppleContainerRuntime, control: Control? = nil, hostRunner: any ProcessRunning = CredentialProviderProcessRunner(), gitPathOverride: String?? = nil, token: String? = nil, timeout: TimeInterval = 30) {
        self.timeout = timeout
        self.runtime = runtime; self.hostRunner = hostRunner; self.gitPathOverride = gitPathOverride; self.token = token
        self.control = control ?? { request, activate, deadline in try GitCredentialBrokerService(context: .production()).request(request, activate: activate, deadline: deadline) }
        if control != nil { self.installationLock = { _ in nil } }
        else {
            self.installationLock = { deadline in
                guard runtime.runner is FoundationProcessRunner else { throw GitCredentialFailure.invalidContext }
                return try GitCredentialServiceLock(directory: GitCredentialLaunchContext.production().endpoints, name: "provision.lock", wait: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            }
        }
    }
    @discardableResult func setup(id: String, hostWorkspace: String?, gitURL: String?, refresh: Bool = false) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let sources: [String]
        if let workspace = hostWorkspace, !workspace.isEmpty {
            let git: String?
            if let override = gitPathOverride { git = override } else { git = HostGitClient.whichGit() }
            guard let git else { return false }
            let selected: any ProcessRunning = (hostRunner as? CredentialProviderProcessRunner)?.withDeadline(deadline) ?? hostRunner
            guard let result = try? selected.run(executable: git, arguments: ["-C", workspace, "remote", "-v"], environment: ProcessInfo.processInfo.environment.filter { $0.key != "ADEVCONTAINER_GIT_TOKEN" }, currentDirectory: nil, stdinData: nil), result.succeeded else { return false }
            sources = GitCredentialDiscovery.uniqueFetchURLs(from: result.stdoutString)
        } else if let gitURL, !gitURL.isEmpty { sources = [gitURL] } else { return false }
        let valid = sources.compactMap { source -> (String, GitCredentialDestination)? in
            guard let destination = try? GitCredentialDestination(url: source) else { return nil }
            return (ContainerIdentity.normalizeGitURL(source), destination)
        }
        guard !valid.isEmpty else { return false }
        let owner = try installationLock(deadline); defer { withExtendedLifetime(owner) {} }
        let context = try runtime.credentialContext(id: id, deadline: deadline)
        guard !context.id.isEmpty, context.id.utf8.count <= 63, context.id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { throw GitCredentialFailure.invalidContext }
        let namespace = Self.namespace(context)
        let artifact = try GuestGitCredentialArtifact.select(platform: context.platform)
        let prepared = try runtime.credentialExec(context: context, command: ["sh", "-ceu", Self.prepareScript, "adevcontainer-git-prepare", context.id, namespace], input: artifact.bytes, deadline: deadline)
        if prepared.exitCode == 3 { return false }
        if prepared.exitCode == 4 { throw GitCredentialFailure.unsafePath }
        guard prepared.succeeded else { throw GitCredentialFailure.transport }
        let lines = prepared.stdoutString.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 5, lines.last == "", let uid = UInt32(lines[3]), String(uid) == lines[3] else { throw GitCredentialFailure.invalidContext }
        let home = String(lines[0]), directory = String(lines[1]), temporary = String(lines[2])
        guard home.hasPrefix("/"), directory == "/tmp/.adevcontainer-git-\(uid)/\(namespace)", directory.utf8.count <= 85,
              temporary.hasPrefix(directory + "/.relay."), !temporary.dropFirst(directory.count + 8).isEmpty,
              !temporary.dropFirst(directory.count + 8).contains("/"), [home, directory, temporary].allSatisfy(GitCredentialProtocol.safe),
              !home.split(separator: "/").contains("..") else { throw GitCredentialFailure.unsafePath }
        defer { _ = try? runtime.credentialExec(context: context, command: ["rm", "-f", "--", temporary], deadline: deadline) }
        let readBack = try runtime.credentialExec(context: context, command: ["cat", temporary], deadline: deadline)
        guard readBack.succeeded else { throw GitCredentialFailure.transport }; try artifact.verify(readBack: readBack.stdout)
        let destinations = Set(valid.map(\.1))
        let azureScopes = destinations.filter { $0.hostname == "dev.azure.com" }.map { "\($0.scheme)://\($0.hostField)" }.sorted()
        let global = destinations.contains { $0.hostname != "dev.azure.com" }
        let installed = try runtime.credentialExec(context: context, command: ["sh", "-ceu", Self.installScript, "adevcontainer-git-install", home, directory, temporary, global ? "1" : "0", context.id] + azureScopes, input: Data(Self.wrapper.utf8), deadline: deadline)
        guard installed.succeeded else { throw GitCredentialFailure.transport }
        let registration = GitCredentialRegistration(context: context, destinations: destinations, directory: directory, overrideRequired: token != nil)
        let acquired = try control(.init(operation: refresh ? .refresh : .register, registration: registration, token: token, sources: refresh ? valid.map(\.0) : nil), true, deadline)
        while true {
            if let ready = try? runtime.credentialExec(context: context, command: ["test", "-S", directory + "/credential.sock"], deadline: deadline), ready.succeeded { return acquired }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCredentialFailure.deadline }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    /// Teardown never activates the broker: with no listener this is a
    /// successful no-op, and a later successor revalidates any saved intent.
    func unregister(id: String) throws { _ = try control(.init(operation: .unregister, id: id), false, ProcessInfo.processInfo.systemUptime + 2) }
    static let wrapper = #"""
#!/bin/sh
set -eu
IFS= read -r container < /proc/sys/kernel/hostname
case "$container" in ''|*[!a-z0-9-]*) exit 1 ;; esac
uid=$(id -u)
base="/tmp/.adevcontainer-git-$uid"
[ ! -L "$base" ] && [ "$(stat -c %u "$base")" = "$uid" ] && [ "$(stat -c %a "$base")" = 700 ] || exit 1
session="$base/session-$container"
[ ! -L "$session" ] && [ -f "$session" ] && [ "$(stat -c %u "$session")" = "$uid" ] && [ "$(stat -c %a "$session")" = 600 ] || exit 1
IFS= read -r DIR < "$session"
case "$DIR" in "$base"/s-*) ;; *) exit 1 ;; esac
exec "$DIR/adevcontainer-git-relay" client "$DIR" "$@"

"""#
    /// Tightens a connection-user-owned directory to 0700. Another product path
    /// (`mkdir -p` for the VS Code marker) leaves this directory at 0755; refusing
    /// that blocks credential setup before any guest endpoint exists. Symlinks and
    /// directories owned by someone else are refused and never chmod'd.
    static let privateDirectoryRepair = #"""
ensure_private_dir() {
  dir=$1; uid=$2
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then return 1; fi
  if [ ! -d "$dir" ]; then mkdir "$dir" || return 1; fi
  if [ "$(stat -c %u "$dir")" != "$uid" ]; then return 1; fi
  if [ "$(stat -c %a "$dir")" != 700 ]; then chmod 700 "$dir" || return 1; fi
  [ ! -L "$dir" ] && [ -d "$dir" ] && [ "$(stat -c %u "$dir")" = "$uid" ] && [ "$(stat -c %a "$dir")" = 700 ]
}

"""#
    private static let prepareScript = privateDirectoryRepair + #"""
set -eu
set -f
umask 077
uid=$(id -u)
expected_container=$1; namespace=$2
IFS= read -r actual_container < /proc/sys/kernel/hostname
[ "$actual_container" = "$expected_container" ] || exit 1
command -v git >/dev/null 2>&1 || exit 3
home=
while IFS=: read -r name password entry_uid gid comment entry_home shell; do
  if [ "$entry_uid" = "$uid" ]; then home=$entry_home; break; fi
done < /etc/passwd
[ -n "$home" ] || exit 1
case "$home" in /*) ;; *) exit 1 ;; esac
rest=${home#/}; current=
while [ -n "$rest" ]; do
  part=${rest%%/*}
  if [ "$rest" = "$part" ]; then rest=; else rest=${rest#*/}; fi
  case "$part" in ''|.|..) exit 1 ;; esac
  current="$current/$part"
  [ ! -L "$current" ] && [ -d "$current" ] || exit 1
done
base="/tmp/.adevcontainer-git-$uid"
[ ! -L /tmp ] && [ -d /tmp ] || exit 1
for dir in "$home/.adevcontainer" "$base" "$base/$namespace"; do
  ensure_private_dir "$dir" "$uid" || exit 4
done
dir="$base/$namespace"
temporary=$(mktemp "$dir/.relay.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
trap 'exit 1' HUP INT TERM
cat > "$temporary"
chmod 700 "$temporary"
printf '%s\n%s\n%s\n%s\n' "$home" "$dir" "$temporary" "$uid"
trap - EXIT
"""#
    static let installScript = #"""
set -eu
umask 077
escape_ere() {
  printf '%s' "$1" | sed -e 's/[\\.^$*+?(){}|]/\\&/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g'
}
unset_exact() {
  pattern=$(escape_ere "$1")
  status=0
  git config --global --unset-all "$2" "^${pattern}$" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 5 ]
}
HOME=$1; export HOME
dir=$2; temporary=$3; global=$4; container=$5; shift 5
helper="$HOME/.adevcontainer/git-credential-adev"
helper_command=$helper
case "$helper" in
  *[!a-zA-Z0-9/_.-]*)
    quoted_helper=$(printf '%s' "$helper" | sed "s/'/'\\\\''/g")
    helper_command="!exec '$quoted_helper'" ;;
esac
[ ! -L "$helper" ] || exit 1
[ ! -L "$dir/adevcontainer-git-relay" ] || exit 1
mv -f -- "$temporary" "$dir/adevcontainer-git-relay"
wrapper=$(mktemp "$HOME/.adevcontainer/.helper.XXXXXX")
trap 'rm -f -- "$wrapper"' EXIT
cat > "$wrapper"
chmod 700 "$wrapper"
mv -f -- "$wrapper" "$helper"
base=${dir%/*}
session="$base/session-$container"
[ ! -L "$session" ] || exit 1
metadata=$(mktemp "$base/.session.XXXXXX")
trap 'rm -f -- "$wrapper" "$metadata"' EXIT
printf '%s\n' "$dir" > "$metadata"
chmod 600 "$metadata"
mv -f -- "$metadata" "$session"
store="$HOME/.adevcontainer/git-credentials"
# Only the old product-owned path, never the unmarked ~/.git-credentials clone store.
if [ ! -L "$store" ] && [ -f "$store" ] && [ "$(stat -c %u "$store")" = "$(id -u)" ] && [ "$(stat -c %a "$store")" = 600 ]; then
  rm -f -- "$store"
fi
if [ "$global" = 1 ]; then
  if ! git config --global --get-all credential.helper 2>/dev/null | grep -Fx -- "$helper_command" >/dev/null; then
    git config --global --add credential.helper "$helper_command" >/dev/null 2>&1
  fi
fi
for scope in "$@"; do
  key="credential.$scope.helper"
  # Drop only empty resets and prior product entries. User helpers stay put,
  # so a failed --add cannot erase them the way unset-all-then-restore did.
  status=0
  git config --global --unset-all "$key" '^$' >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 5 ] || exit 1
  unset_exact "$helper" "$key" || exit 1
  if [ "$helper_command" != "$helper" ]; then
    unset_exact "$helper_command" "$key" || exit 1
  fi
  git config --global --add "$key" "$helper_command" >/dev/null 2>&1
  git config --global "credential.$scope.useHttpPath" true >/dev/null 2>&1
done
"""#
}
