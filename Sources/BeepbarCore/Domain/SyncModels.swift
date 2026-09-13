import Foundation

public struct RelativePath: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws {
        try self.init(value, allowsReservedNamespace: false)
    }

    init(internal value: String) throws {
        try self.init(value, allowsReservedNamespace: true)
    }

    private init(_ value: String, allowsReservedNamespace: Bool) throws {
        guard !value.isEmpty, !value.utf8.contains(0) else { throw RelativePathError.invalid }
        let normalized = value.precomposedStringWithCanonicalMapping
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              allowsReservedNamespace || components.first != ".beepbar" else {
            throw RelativePathError.invalid
        }
        self.value = components.joined(separator: "/")
    }

    public var description: String { value }
    public var components: [String] { value.split(separator: "/").map(String.init) }
}

public enum RelativePathError: Error, Sendable, Equatable {
    case invalid
}

public struct Baseline: Sendable, Equatable {
    public let remoteID: String
    public let relativePath: RelativePath
    public let sha256: String
    public let remoteRevision: String

    public init(remoteID: String, relativePath: RelativePath, sha256: String, remoteRevision: String) {
        self.remoteID = remoteID
        self.relativePath = relativePath
        self.sha256 = sha256
        self.remoteRevision = remoteRevision
    }
}

public struct SyncScope: Sendable, Equatable, Identifiable {
    public let rootID: UUID
    public let courseID: Int64
    public let displayName: String
    public let localFolder: String
    public let enabled: Bool
    public let managedDirectory: DirectoryIdentity?

    public var id: String { "\(rootID.uuidString):\(courseID)" }

    public init(rootID: UUID, courseID: Int64, displayName: String, localFolder: String, enabled: Bool, managedDirectory: DirectoryIdentity? = nil) {
        self.rootID = rootID
        self.courseID = courseID
        self.displayName = displayName
        self.localFolder = localFolder
        self.enabled = enabled
        self.managedDirectory = managedDirectory
    }
}

public struct DirectoryIdentity: Sendable, Equatable {
    public let device: Int64
    public let inode: UInt64

    public init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public enum LocalState: Sendable, Equatable {
    case missing
    case present(sha256: String)
}

public struct RemoteState: Sendable, Equatable {
    public let sha256: String
    public let revision: String

    public init(sha256: String, revision: String) {
        self.sha256 = sha256
        self.revision = revision
    }
}

public enum SyncDecision: Sendable, Equatable {
    case installRemote
    case preserveLocal
    case adoptRemoteBaseline
    case conflict
    case noOp
}

public struct ConflictRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rootID: UUID
    public let remoteID: String
    public let relativePath: RelativePath
    public let incomingPath: RelativePath
    public let baseSHA256: String?
    public let localSHA256: String?
    public let remoteSHA256: String
    public let remoteRevision: String
    public let detectedAt: Date
    public let status: ConflictStatus
}

public enum ConflictStatus: String, Sendable, Equatable {
    case open
    case resolved
}

public enum ConflictResolution: String, Sendable, Equatable {
    case keepLocal
    case useRemote
}

public struct PendingScopeMove: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rootID: UUID
    public let courseID: Int64
    public let oldFolder: String
    public let newFolder: String
}

public struct PendingOperation: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rootID: UUID
    public let remoteID: String
    public let destination: RelativePath
    public let stagePath: RelativePath
    public let expectedLocal: LocalState
    public let remoteSHA256: String
    public let remoteRevision: String
    public let phase: PendingOperationPhase

    public init(id: UUID = UUID(), rootID: UUID, remoteID: String, destination: RelativePath, stagePath: RelativePath, expectedLocal: LocalState, remoteSHA256: String, remoteRevision: String, phase: PendingOperationPhase = .prepared) {
        self.id = id
        self.rootID = rootID
        self.remoteID = remoteID
        self.destination = destination
        self.stagePath = stagePath
        self.expectedLocal = expectedLocal
        self.remoteSHA256 = remoteSHA256
        self.remoteRevision = remoteRevision
        self.phase = phase
    }
}

public enum PendingOperationPhase: String, Sendable, Equatable {
    case prepared
    case committed
}
