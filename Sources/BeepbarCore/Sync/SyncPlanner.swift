public enum SyncPlanner {
    public static func decide(baseline: Baseline?, local: LocalState, remote: RemoteState) -> SyncDecision {
        guard let baseline else {
            switch local {
            case .missing: return .installRemote
            case .present(let localHash): return localHash == remote.sha256 ? .adoptRemoteBaseline : .conflict
            }
        }

        switch local {
        case .missing:
            return .installRemote
        case .present(let localHash):
            let localChanged = localHash != baseline.sha256
            let remoteChanged = remote.sha256 != baseline.sha256
            if !localChanged && !remoteChanged {
                return remote.revision == baseline.remoteRevision ? .noOp : .adoptRemoteBaseline
            }
            if !localChanged { return .installRemote }
            if !remoteChanged {
                return .preserveLocal
            }
            return localHash == remote.sha256 ? .adoptRemoteBaseline : .conflict
        }
    }
}
