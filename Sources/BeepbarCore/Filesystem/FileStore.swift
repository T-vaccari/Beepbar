import CryptoKit
import Darwin
import Foundation

public enum FileStoreError: Error, Sendable, Equatable { case invalidRoot, symbolicLink, invalidStage, localChanged, sizeMismatch, tooLarge, ioFailure }

private struct FileIdentity: Sendable, Equatable {
    let device: Int64
    let inode: UInt64
}

public struct StageHandle: Sendable, Equatable {
    fileprivate let name: String
    fileprivate let identity: FileIdentity
    public let relativePath: RelativePath
}

public struct StagedArtifact: Sendable, Equatable {
    fileprivate let name: String
    fileprivate let identity: FileIdentity
    public let stagePath: RelativePath
    public let sha256: String
    public let size: Int64
}

public struct RecoveryArtifact: Sendable, Equatable {
    fileprivate let name: String
    fileprivate let identity: FileIdentity
    public let relativePath: RelativePath
    public let sha256: String
}

public enum InstallResult: Sendable, Equatable {
    case installedNew
    case installedReplacing(rollback: RecoveryArtifact)
    case localChanged
}

public enum TopLevelDirectoryState: Sendable, Equatable { case missing, directory, other }

public actor FileStore {
    private let rootFD: Int32

    public init(root: URL) throws {
        let fd = open(root.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0, (try? Self.identity(of: fd)) != nil else { throw FileStoreError.invalidRoot }
        rootFD = fd
    }

    deinit { close(rootFD) }

    public func inspect(_ path: RelativePath) throws -> LocalState {
        let parentAndName: (Int32, String)
        do {
            parentAndName = try parentDirectory(for: path, create: false)
        } catch where errno == ENOENT {
            return .missing
        }
        let (parent, name) = parentAndName
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return .missing }; throw fileStoreError() }
        defer { close(fd) }
        try requireRegularFile(fd)
        return .present(sha256: try Self.sha256(of: fd))
    }

    public func containsRegularFile(_ path: RelativePath) throws -> Bool {
        let parentAndName: (Int32, String)
        do {
            parentAndName = try parentDirectory(for: path, create: false)
        } catch where errno == ENOENT {
            return false
        }
        let (parent, name) = parentAndName
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return false }; throw fileStoreError() }
        defer { close(fd) }
        try requireRegularFile(fd)
        return true
    }

    public func renameTopLevelDirectory(from old: String, to new: String) throws {
        guard isSafeTopLevelName(old), isSafeTopLevelName(new) else { throw FileStoreError.invalidStage }
        let oldFD = openat(rootFD, old, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard oldFD >= 0 else { throw fileStoreError() }
        defer { close(oldFD) }
        guard renameatx_np(rootFD, old, rootFD, new, UInt32(RENAME_EXCL)) == 0 else { throw fileStoreError() }
        guard fsync(rootFD) == 0 else { throw fileStoreError() }
    }

    public func topLevelDirectoryIdentity(_ name: String) throws -> DirectoryIdentity? {
        guard isSafeTopLevelName(name) else { throw FileStoreError.invalidStage }
        let fd = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw fileStoreError() }
        defer { close(fd) }
        let identity = try Self.identity(of: fd)
        return DirectoryIdentity(device: identity.device, inode: identity.inode)
    }

    public func ensureTopLevelDirectory(_ name: String) throws -> (identity: DirectoryIdentity, created: Bool) {
        guard isSafeTopLevelName(name) else { throw FileStoreError.invalidStage }
        if mkdirat(rootFD, name, S_IRWXU) == 0 {
            guard let identity = try topLevelDirectoryIdentity(name) else { throw fileStoreError() }
            return (identity, true)
        }
        guard errno == EEXIST, let identity = try topLevelDirectoryIdentity(name) else { throw fileStoreError() }
        return (identity, false)
    }

    public func topLevelDirectoryState(_ name: String) throws -> TopLevelDirectoryState {
        guard isSafeTopLevelName(name) else { throw FileStoreError.invalidStage }
        let fd = openat(rootFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return .missing }; throw fileStoreError() }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw fileStoreError() }
        return (metadata.st_mode & S_IFMT) == S_IFDIR ? .directory : .other
    }

    public func createStage() throws -> StageHandle {
        let fd = try directoryFD(for: [".beepbar", "staging"], create: true)
        defer { close(fd) }
        let name = UUID().uuidString + ".partial"
        let stage = openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard stage >= 0 else { throw fileStoreError() }
        defer { close(stage) }
        return StageHandle(name: name, identity: try Self.identity(of: stage), relativePath: try RelativePath(internal: ".beepbar/staging/\(name)"))
    }

    public func write(_ data: Data, to stage: StageHandle) throws {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let fd = try openStage(stage, in: staging, flags: O_WRONLY | O_APPEND)
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw fileStoreError() }
                offset += count
            }
        }
    }

    public func importDownloadedFile(at source: URL, expectedSize: Int64, maximumSize: Int64) throws -> StagedArtifact {
        let trace = PerformanceTrace.shared.begin("filesystem.import", category: .filesystem)
        defer { PerformanceTrace.shared.end("filesystem.import", category: .filesystem, state: trace) }
        try Task.checkCancellation()
        guard expectedSize >= 0, expectedSize <= maximumSize else { throw FileStoreError.tooLarge }
        let sourceFD = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceFD >= 0 else { throw fileStoreError() }
        defer { close(sourceFD) }
        try requireRegularFile(sourceFD)
        guard try fileSize(of: sourceFD) == expectedSize else { throw FileStoreError.sizeMismatch }

        let stage = try createStage()
        do {
            let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
            defer { close(staging) }
            let stageFD = try openStage(stage, in: staging, flags: O_WRONLY | O_TRUNC)
            defer { close(stageFD) }
            let duplicate = dup(sourceFD)
            guard duplicate >= 0 else { throw FileStoreError.ioFailure }
            let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
            defer { try? handle.close() }
            var total: Int64 = 0
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                total += Int64(chunk.count)
                guard total <= maximumSize else { throw FileStoreError.tooLarge }
                hasher.update(data: chunk)
                try Self.write(chunk, to: stageFD)
            }
            try Task.checkCancellation()
            guard total == expectedSize else { throw FileStoreError.sizeMismatch }
            guard fsync(stageFD) == 0 else { throw fileStoreError() }
            return StagedArtifact(name: stage.name, identity: stage.identity, stagePath: stage.relativePath, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), size: total)
        } catch {
            try? discard(stage)
            throw error
        }
    }

    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw FileStoreError.ioFailure }
                offset += count
            }
        }
    }

    public func finalize(_ stage: StageHandle) throws -> StagedArtifact {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let fd = try openStage(stage, in: staging, flags: O_RDONLY)
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw fileStoreError() }
        return StagedArtifact(name: stage.name, identity: stage.identity, stagePath: stage.relativePath, sha256: try Self.sha256(of: fd), size: try fileSize(of: fd))
    }

    public func install(_ artifact: StagedArtifact, at path: RelativePath, expectedLocal: LocalState) throws -> InstallResult {
        let trace = PerformanceTrace.shared.begin("filesystem.install", category: .filesystem)
        defer { PerformanceTrace.shared.end("filesystem.install", category: .filesystem, state: trace) }
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let verified = StageHandle(name: artifact.name, identity: artifact.identity, relativePath: try RelativePath(internal: ".beepbar/staging/\(artifact.name)"))
        let stageFD = try openStage(verified, in: staging, flags: O_RDONLY)
        guard fsync(stageFD) == 0 else { close(stageFD); throw fileStoreError() }
        close(stageFD)

        let (destinationParent, destinationName) = try parentDirectory(for: path, create: true)
        defer { close(destinationParent) }
        let result: InstallResult
        switch expectedLocal {
        case .missing:
            guard renameatx_np(staging, artifact.name, destinationParent, destinationName, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { return .localChanged }
                throw fileStoreError()
            }
            result = .installedNew
        case .present(let expectedHash):
            let existing = openat(destinationParent, destinationName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            if existing < 0 { if errno == ENOENT { return .localChanged }; throw fileStoreError() }
            defer { close(existing) }
            try requireRegularFile(existing)
            guard try Self.sha256(of: existing) == expectedHash else { return .localChanged }
            guard renameatx_np(staging, artifact.name, destinationParent, destinationName, UInt32(RENAME_SWAP)) == 0 else {
                if errno == ENOENT { return .localChanged }
                throw fileStoreError()
            }
            let rollbackIfRemoteIsStillInstalled: () throws -> Bool = {
                let current = openat(destinationParent, destinationName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard current >= 0 else { return false }
                defer { close(current) }
                try self.requireRegularFile(current)
                guard try Self.sha256(of: current) == artifact.sha256 else { return false }
                guard renameatx_np(staging, artifact.name, destinationParent, destinationName, UInt32(RENAME_SWAP)) == 0 else { throw self.fileStoreError() }
                guard fsync(staging) == 0, fsync(destinationParent) == 0 else { throw self.fileStoreError() }
                return true
            }
            do {
                let displacedFD = openat(staging, artifact.name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard displacedFD >= 0 else { throw fileStoreError() }
                defer { close(displacedFD) }
                try requireRegularFile(displacedFD)
                let displacedHash = try Self.sha256(of: displacedFD)
                guard displacedHash == expectedHash else {
                    guard try rollbackIfRemoteIsStillInstalled() else { throw FileStoreError.localChanged }
                    return .localChanged
                }
                result = .installedReplacing(rollback: RecoveryArtifact(name: artifact.name, identity: try Self.identity(of: displacedFD), relativePath: try RelativePath(internal: ".beepbar/staging/\(artifact.name)"), sha256: expectedHash))
            } catch {
                if (try? rollbackIfRemoteIsStillInstalled()) == true { return .localChanged }
                throw error
            }
        }
        guard fsync(destinationParent) == 0 else { throw fileStoreError() }
        return result
    }

    public func discard(_ recovery: RecoveryArtifact) throws {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let stage = StageHandle(name: recovery.name, identity: recovery.identity, relativePath: recovery.relativePath)
        let fd = try openStage(stage, in: staging, flags: O_RDONLY)
        let hash = try Self.sha256(of: fd)
        close(fd)
        guard hash == recovery.sha256 else { throw FileStoreError.localChanged }
        guard unlinkat(staging, recovery.name, 0) == 0 else { throw fileStoreError() }
        guard fsync(staging) == 0 else { throw fileStoreError() }
    }

    public func preserveAsConflict(_ artifact: StagedArtifact, conflictID: UUID, at path: RelativePath) throws -> RelativePath {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let stage = StageHandle(name: artifact.name, identity: artifact.identity, relativePath: try RelativePath(internal: ".beepbar/staging/\(artifact.name)"))
        let fd = try openStage(stage, in: staging, flags: O_RDONLY)
        close(fd)
        let incoming = try RelativePath(internal: ".beepbar/conflicts/\(conflictID.uuidString)/\(path.value)")
        let (parent, name) = try parentDirectory(for: incoming, create: true)
        defer { close(parent) }
        guard renameatx_np(staging, artifact.name, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw fileStoreError() }
        guard fsync(staging) == 0, fsync(parent) == 0 else { throw fileStoreError() }
        return incoming
    }

    public func conflictArtifact(at path: RelativePath) throws -> StagedArtifact? {
        let components = path.components
        guard components.count >= 4, components[0] == ".beepbar", components[1] == "conflicts" else { throw FileStoreError.invalidStage }
        let (parent, name): (Int32, String)
        do {
            (parent, name) = try parentDirectory(for: path, create: false)
        } catch where errno == ENOENT {
            return nil
        }
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw fileStoreError() }
        defer { close(fd) }
        try requireRegularFile(fd)
        return StagedArtifact(name: name, identity: try Self.identity(of: fd), stagePath: path, sha256: try Self.sha256(of: fd), size: try fileSize(of: fd))
    }

    public func copyConflictArtifactToStage(at path: RelativePath, expectedSHA256: String) throws -> StagedArtifact {
        guard let artifact = try conflictArtifact(at: path), artifact.sha256 == expectedSHA256 else { throw FileStoreError.invalidStage }
        let sourceParent = try parentDirectory(for: path, create: false)
        defer { close(sourceParent.0) }
        let source = openat(sourceParent.0, sourceParent.1, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard source >= 0 else { throw fileStoreError() }
        defer { close(source) }
        try requireRegularFile(source)
        let stage = try createStage()
        do {
            let duplicate = dup(source)
            guard duplicate >= 0 else { throw FileStoreError.ioFailure }
            let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { try write(chunk, to: stage) }
            let copied = try finalize(stage)
            guard copied.sha256 == expectedSHA256 && copied.size == artifact.size else { throw FileStoreError.invalidStage }
            return copied
        } catch {
            try? discard(stage)
            throw error
        }
    }

    public func discardConflictArtifact(at path: RelativePath, expectedSHA256: String) throws {
        guard let artifact = try conflictArtifact(at: path), artifact.sha256 == expectedSHA256 else { throw FileStoreError.localChanged }
        let (parent, name) = try parentDirectory(for: path, create: false)
        defer { close(parent) }
        guard unlinkat(parent, name, 0) == 0 else { throw fileStoreError() }
        guard fsync(parent) == 0 else { throw fileStoreError() }
    }

    public func discard(_ artifact: StagedArtifact) throws {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let stage = StageHandle(name: artifact.name, identity: artifact.identity, relativePath: try RelativePath(internal: ".beepbar/staging/\(artifact.name)"))
        let fd = try openStage(stage, in: staging, flags: O_RDONLY)
        close(fd)
        guard unlinkat(staging, artifact.name, 0) == 0 else { throw fileStoreError() }
    }

    public func discard(_ stage: StageHandle) throws {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let fd = try openStage(stage, in: staging, flags: O_RDONLY)
        close(fd)
        guard unlinkat(staging, stage.name, 0) == 0 else { throw fileStoreError() }
        guard fsync(staging) == 0 else { throw fileStoreError() }
    }

    public func stagedArtifact(at path: RelativePath) throws -> StagedArtifact? {
        let components = path.components
        guard components.count == 3, components[0] == ".beepbar", components[1] == "staging", components[2].hasSuffix(".partial") else { throw FileStoreError.invalidStage }
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let fd = openat(staging, components[2], O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw fileStoreError() }
        defer { close(fd) }
        try requireRegularFile(fd)
        return StagedArtifact(name: components[2], identity: try Self.identity(of: fd), stagePath: path, sha256: try Self.sha256(of: fd), size: try fileSize(of: fd))
    }

    private func parentDirectory(for path: RelativePath, create: Bool) throws -> (Int32, String) {
        let components = path.components
        return (try directoryFD(for: Array(components.dropLast()), create: create), components.last!)
    }

    private func isSafeTopLevelName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0) && !name.hasPrefix(".beepbar")
    }

    private func directoryFD(for components: [String], create: Bool) throws -> Int32 {
        var fd = dup(rootFD)
        guard fd >= 0 else { throw fileStoreError() }
        do {
            for component in components {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, S_IRWXU) == 0 || errno == EEXIST else { throw fileStoreError() }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else { throw fileStoreError() }
                close(fd)
                fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    private func openStage(_ stage: StageHandle, in staging: Int32, flags: Int32) throws -> Int32 {
        guard stage.name.hasSuffix(".partial") else { throw FileStoreError.invalidStage }
        let fd = openat(staging, stage.name, flags | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw fileStoreError() }
        guard try Self.identity(of: fd) == stage.identity else { close(fd); throw FileStoreError.invalidStage }
        try requireRegularFile(fd)
        return fd
    }

    private func requireRegularFile(_ fd: Int32) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw fileStoreError() }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { throw FileStoreError.ioFailure }
    }

    private func fileSize(of fd: Int32) throws -> Int64 {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw fileStoreError() }
        return Int64(metadata.st_size)
    }

    private func fileStoreError() -> FileStoreError { errno == ELOOP ? .symbolicLink : .ioFailure }

    private static func identity(of fd: Int32) throws -> FileIdentity {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw FileStoreError.ioFailure }
        return FileIdentity(device: Int64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private static func sha256(of fd: Int32) throws -> String {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw FileStoreError.ioFailure }
        let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
