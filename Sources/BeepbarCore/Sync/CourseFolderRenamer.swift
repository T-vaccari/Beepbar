import Foundation

public enum CourseRenameError: Error, Sendable, Equatable, LocalizedError {
    /// Something already occupies the requested folder name inside the sync root.
    case folderAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .folderAlreadyExists: "Esiste già una cartella con questo nome."
        }
    }
}

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
            guard try await database.hasPendingModuleMoves(rootID: rootID) == false else { throw SyncDatabaseError.execution }
            guard !(try await database.hasOpenConflicts(rootID: rootID, prefix: oldFolder)),
                  !(try await database.hasPendingOperations(rootID: rootID, prefix: oldFolder)),
                  let scope = try await database.scope(rootID: rootID, courseID: courseID), scope.localFolder == oldFolder else { throw SyncDatabaseError.execution }
            guard let currentIdentity = try await fileStore.topLevelDirectoryIdentity(oldFolder) else {
                try await database.renameScopeMetadata(rootID: rootID, courseID: courseID, from: oldFolder, to: newFolder)
                return
            }
            guard let managedIdentity = scope.managedDirectory, currentIdentity == managedIdentity else { throw SyncDatabaseError.execution }
            // `renameTopLevelDirectory` uses RENAME_EXCL, so an occupied target fails. Catch it here,
            // before the pending row exists, and report it as its own error the UI can explain.
            guard try await fileStore.topLevelDirectoryState(newFolder) == .missing else { throw CourseRenameError.folderAlreadyExists }
            let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: courseID, oldFolder: oldFolder, newFolder: newFolder)
            try await database.beginScopeMove(move)
            do {
                try await fileStore.renameTopLevelDirectory(from: oldFolder, to: newFolder)
            } catch {
                // Nothing moved, so the prepared row describes a move that will never happen. Leaving
                // it behind would trip the table's unique constraints on every later rename of this
                // course and would come back as an unresolvable move at the next launch.
                try? await database.abortScopeMove(id: move.id)
                throw error
            }
            try await database.commitScopeMove(move)
        }
    }
}
