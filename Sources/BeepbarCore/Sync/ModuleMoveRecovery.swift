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
        return true
    }
}
