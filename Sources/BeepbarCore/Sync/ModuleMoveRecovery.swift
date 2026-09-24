import Foundation

public enum ModuleMoveRecovery {
    public static func recover(_ move: PendingModuleMove, database: SyncDatabase, fileStore: FileStore) async throws -> Bool {
        for file in move.files {
            if file.oldPath == file.newPath { continue }
            let sourceIdentity = try await fileStore.regularFileIdentity(file.oldPath)
            let destinationIdentity = try await fileStore.regularFileIdentity(file.newPath)
            switch file.source {
            case .missing:
                guard sourceIdentity == nil, destinationIdentity == nil else { return false }
            case .present(let expected):
                let identity = DirectoryIdentity(device: expected.device, inode: expected.inode)
                switch (sourceIdentity, destinationIdentity) {
                case (identity, nil):
                    try await fileStore.moveRegularFilePreservingCurrentContents(from: file.oldPath, to: file.newPath, expected: expected)
                    guard try await fileStore.regularFileIdentity(file.oldPath) == nil,
                          try await fileStore.regularFileIdentity(file.newPath) == identity else { return false }
                case (nil, identity):
                    break
                default:
                    return false
                }
            }
        }
        try await database.commitModuleMove(move)
        // The move is committed; tidying up is best effort and never blocks it.
        for file in move.files where file.oldPath != file.newPath {
            try? await fileStore.removeEmptyParentDirectories(of: file.oldPath)
        }
        return true
    }

    /// Gives up on a move that `recover` cannot finish, without touching any file on disk. Each
    /// tracked file keeps the path it is actually found at (identified by the inode recorded when
    /// the move was journaled); a file found at neither end loses its baseline.
    public static func abandon(_ move: PendingModuleMove, database: SyncDatabase, fileStore: FileStore) async throws {
        var actualPaths: [String: RelativePath?] = [:]
        for file in move.files where file.oldPath != file.newPath {
            guard case .present(let expected) = file.source else { continue }
            let identity = DirectoryIdentity(device: expected.device, inode: expected.inode)
            if try await fileStore.regularFileIdentity(file.oldPath) == identity {
                actualPaths[file.remoteID] = .some(file.oldPath)
            } else if try await fileStore.regularFileIdentity(file.newPath) == identity {
                actualPaths[file.remoteID] = .some(file.newPath)
            } else {
                actualPaths[file.remoteID] = .some(nil)
            }
        }
        try await database.abandonModuleMove(move, actualPaths: actualPaths)
    }
}
