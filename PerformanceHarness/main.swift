import BeepbarCore
import Foundation

@main
struct BeepbarPerformanceHarness {
    struct Manifest: Codable {
        let courses: Int
        let smallFiles: Int
        let mediumFiles: Int
        let largeFiles: Int
        let totalBytes: Int
    }

    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.temporaryDirectory.appendingPathComponent("beepbar-performance-fixture").path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let databaseDirectory = output.appendingPathComponent(".beepbar", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)

        let rootID = UUID()
        let database = try SyncDatabase(url: databaseDirectory.appendingPathComponent("fixture.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: output.path)

        var totalBytes = 0
        for course in 1...10 {
            let folder = output.appendingPathComponent("Course \(course)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await database.upsertScope(SyncScope(rootID: rootID, courseID: Int64(course), displayName: "Course \(course)", localFolder: "Course \(course)", enabled: true))
            for file in 1...100 {
                let destination = folder.appendingPathComponent(String(format: "small-%03d.txt", file))
                let payload = Data("x\n".utf8)
                try payload.write(to: destination, options: .atomic)
                totalBytes += payload.count
                try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "small-\(course)-\(file)", relativePath: try RelativePath("Course \(course)/\(destination.lastPathComponent)"), sha256: String(repeating: "0", count: 64), remoteRevision: "1"))
            }
        }

        for file in 1...10 {
            let destination = output.appendingPathComponent("medium-\(file).bin")
            let payload = Data(repeating: UInt8(file), count: 1_048_576)
            try payload.write(to: destination, options: .atomic)
            totalBytes += payload.count
        }
        for file in 1...2 {
            let destination = output.appendingPathComponent("large-\(file).bin")
            let payload = Data(repeating: UInt8(file), count: 8_388_608)
            try payload.write(to: destination, options: .atomic)
            totalBytes += payload.count
        }

        let manifest = Manifest(courses: 10, smallFiles: 1_000, mediumFiles: 10, largeFiles: 2, totalBytes: totalBytes)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        print(String(data: data, encoding: .utf8)!)
    }
}
