import Foundation

public actor CourseFolderRenamer {
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let gate: RootOperationGate

    public init(database: SyncDatabase, fileStore: FileStore, gate: RootOperationGate) {
        self.database = database; self.fileStore = fileStore; self.gate = gate
    }

    public func rename(rootID: UUID, courseID: Int64, from oldFolder: String, to newFolder: String) async throws {
        guard oldFolder != newFolder, oldFolder.localizedCaseInsensitiveCompare(newFolder) != .orderedSame,
              !ReservedNamespace.isReservedTopLevelName(newFolder) else { throw FileStoreError.invalidStage }
        try await gate.withLease(.renaming(courseID)) { [database, fileStore] in
            guard !(try await database.hasOpenConflicts(rootID: rootID, prefix: oldFolder)),
                  !(try await database.hasPendingOperations(rootID: rootID, prefix: oldFolder)),
                  let scope = try await database.scope(rootID: rootID, courseID: courseID), scope.localFolder == oldFolder else { throw SyncDatabaseError.execution }
            guard let currentIdentity = try await fileStore.topLevelDirectoryIdentity(oldFolder) else {
                try await database.renameScopeMetadata(rootID: rootID, courseID: courseID, from: oldFolder, to: newFolder)
                return
            }
            guard let managedIdentity = scope.managedDirectory, currentIdentity == managedIdentity else { throw SyncDatabaseError.execution }
            let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: courseID, oldFolder: oldFolder, newFolder: newFolder)
            try await database.beginScopeMove(move)
            try await fileStore.renameTopLevelDirectory(from: oldFolder, to: newFolder)
            try await database.commitScopeMove(move)
        }
    }
}
