import Foundation
@testable import ADevContainerLib

@MainActor let gitCredentialBrokerPolicyTests: [(String, () throws -> Void)] = [
    ("credentials.policy.destinationsAndUsername", {
        var policy = GitCredentialBrokerPolicy()
        policy.register("a", generation: 7, destinations: [try GitCredentialDestination(url: "https://dev.azure.com/org/original"), try GitCredentialDestination(url: "http://legacy.invalid:8080/org/repo")])
        let sibling = GitCredentialQuery(scheme: "https", host: "DEV.AZURE.COM:443", path: "other/sibling", username: "guest")
        try MiniTest.expectEqual(policy.authorize("a", generation: 7, query: sibling), "https://dev.azure.com/other/sibling")
        try MiniTest.expectEqual(policy.deliver("a", generation: 7, query: sibling, credential: .init(username: "host-account", password: "synthetic"))?.username, "guest")
        for query in [GitCredentialQuery(scheme: "http", host: "dev.azure.com", path: "org/repo"), .init(scheme: "https", host: "dev.azure.com:8443", path: "org/repo"), .init(scheme: "ssh", host: "dev.azure.com"), .init(scheme: "https", host: "unknown.invalid"), .init(scheme: "https", host: "dev.azure.com"), .init(scheme: "https", host: "dev.azure.com", path: "org\ninjected=x")] {
            try MiniTest.expect(policy.authorize("a", generation: 7, query: query) == nil)
        }
        try MiniTest.expectEqual(policy.authorize("a", generation: 7, query: .init(scheme: "http", host: "legacy.invalid:8080", path: "sibling")), "http://legacy.invalid:8080/sibling")
        try MiniTest.expect(policy.authorize("a", generation: 6, query: sibling) == nil)
        for host in ["example.invalid@other.invalid", "example.invalid/path", "example.invalid:0", "example.invalid:65536", "example.invalid\n", "example%0a.invalid", "example.invalid?x"] {
            try MiniTest.expectThrows({ _ = try GitCredentialDestination(scheme: "https", host: host) }, validate: { _ in })
        }
    }),
    ("credentials.policy.rejectionFiniteAndIsolated", {
        var time: TimeInterval = 0
        var policy = GitCredentialBrokerPolicy(clock: { time })
        for session in ["a", "b"] { policy.register(session, generation: 7, destinations: [try GitCredentialDestination(url: "https://example.invalid/repo")]) }
        let query = GitCredentialQuery(scheme: "https", host: "example.invalid", path: "repo", username: "guest")
        let old = GitHTTPSCredentials(username: "host", password: "old-synthetic"), new = GitHTTPSCredentials(username: "host", password: "new-synthetic")
        _ = policy.deliver("a", generation: 7, query: query, credential: old)
        _ = policy.deliver("a", generation: 7, query: query, credential: new)
        var rejection = query; rejection.password = old.password
        policy.erase("a", generation: 7, query: rejection)
        try MiniTest.expect(policy.deliver("a", generation: 7, query: query, credential: old) == nil)
        try MiniTest.expect(policy.deliver("a", generation: 7, query: query, credential: new) != nil)
        try MiniTest.expect(policy.deliver("b", generation: 7, query: query, credential: old) != nil)
        time = 31
        try MiniTest.expect(policy.deliver("a", generation: 7, query: query, credential: old) != nil)
        policy.erase("a", generation: 7, query: rejection); policy.reset("a")
        try MiniTest.expect(policy.deliver("a", generation: 7, query: query, credential: old) != nil)
        rejection.password = "never-delivered"
        policy.erase("a", generation: 7, query: rejection)
        try MiniTest.expect(policy.deliver("a", generation: 7, query: query, credential: .init(username: "host", password: "never-delivered")) != nil)
        try MiniTest.expect(policy.begin("a", generation: 7, request: 1))
        try MiniTest.expect(!policy.begin("a", generation: 7, request: 1))
        policy.register("a", generation: 8, destinations: [try GitCredentialDestination(url: "https://example.invalid")])
        try MiniTest.expect(!policy.current("a", generation: 7))
        try MiniTest.expect(policy.deliver("a", generation: 7, query: query, credential: old) == nil)
        policy.unregister("a"); try MiniTest.expect(!policy.current("a", generation: 8))
    }),
    ("credentials.policy.boundedFairAdmission", {
        var admission = GitCredentialAdmission(activeLimit: 1, queueLimit: 3)
        let a = GitCredentialWork(session: "a", generation: 1, request: 1)
        let a2 = GitCredentialWork(session: "a", generation: 1, request: 2)
        let b = GitCredentialWork(session: "b", generation: 1, request: 1)
        try MiniTest.expect(admission.enqueue(a)); try MiniTest.expectEqual(admission.next(), a)
        try MiniTest.expect(admission.enqueue(a2)); try MiniTest.expect(admission.enqueue(b))
        try MiniTest.expect(admission.next() == nil)
        admission.complete(a); try MiniTest.expectEqual(admission.next(), b)
        admission.complete(b); try MiniTest.expectEqual(admission.next(), a2)
        admission.cancel(session: "a")
        for id in 3...5 { try MiniTest.expect(admission.enqueue(.init(session: "c", generation: 1, request: UInt64(id)))) }
        try MiniTest.expect(!admission.enqueue(.init(session: "c", generation: 1, request: 6)))
    })
]
