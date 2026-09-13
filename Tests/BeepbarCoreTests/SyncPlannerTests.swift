import Testing
@testable import BeepbarCore

struct SyncPlannerTests {
    private let path = try! RelativePath("Course/notes.pdf")
    private let baseline = Baseline(remoteID: "remote", relativePath: try! RelativePath("Course/notes.pdf"), sha256: "base", remoteRevision: "1")

    @Test func decisionMatrix() {
        let cases: [(Baseline?, LocalState, RemoteState, SyncDecision)] = [
            (nil, .missing, RemoteState(sha256: "remote", revision: "1"), .installRemote),
            (nil, .present(sha256: "remote"), RemoteState(sha256: "remote", revision: "1"), .adoptRemoteBaseline),
            (nil, .present(sha256: "local"), RemoteState(sha256: "remote", revision: "1"), .conflict),
            (baseline, .present(sha256: "base"), RemoteState(sha256: "base", revision: "1"), .noOp),
            (baseline, .present(sha256: "base"), RemoteState(sha256: "base", revision: "2"), .adoptRemoteBaseline),
            (baseline, .present(sha256: "base"), RemoteState(sha256: "remote", revision: "2"), .installRemote),
            (baseline, .present(sha256: "local"), RemoteState(sha256: "base", revision: "1"), .preserveLocal),
            (baseline, .present(sha256: "local"), RemoteState(sha256: "base", revision: "2"), .preserveLocal),
            (baseline, .present(sha256: "same"), RemoteState(sha256: "same", revision: "2"), .adoptRemoteBaseline),
            (baseline, .present(sha256: "local"), RemoteState(sha256: "remote", revision: "2"), .conflict),
            (baseline, .missing, RemoteState(sha256: "base", revision: "1"), .installRemote),
            (baseline, .missing, RemoteState(sha256: "remote", revision: "2"), .installRemote),
        ]

        for (baseline, local, remote, expected) in cases {
            #expect(SyncPlanner.decide(baseline: baseline, local: local, remote: remote) == expected)
        }
    }

    @Test func baselinePathIsUsable() {
        #expect(path.value == "Course/notes.pdf")
    }

    @Test func handlesOneThousandUnchangedEntriesWithoutConflict() {
        let baselines = (0..<1_000).map {
            Baseline(remoteID: "remote-\($0)", relativePath: try! RelativePath("Course/\($0).txt"), sha256: "hash-\($0)", remoteRevision: "1")
        }
        let decisions = baselines.map {
            SyncPlanner.decide(baseline: $0, local: .present(sha256: $0.sha256), remote: RemoteState(sha256: $0.sha256, revision: $0.remoteRevision))
        }
        #expect(decisions.allSatisfy { $0 == .noOp })
    }
}
