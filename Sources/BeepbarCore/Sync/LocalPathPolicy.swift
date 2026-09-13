import CryptoKit
import Foundation

public enum LocalPathPolicyError: Error, Sendable, Equatable {
    case invalidRemotePath
}

public enum LocalPathPolicy {
    public static func defaultCourseFolder(_ courseName: String) -> String {
        let expression = try? NSRegularExpression(pattern: "\\d+ - (.+) \\(.+\\)")
        let range = NSRange(courseName.startIndex..., in: courseName)
        if let match = expression?.firstMatch(in: courseName, range: range), let captured = Range(match.range(at: 1), in: courseName) {
            return component(String(courseName[captured]))
        }
        return component(courseName)
    }

    public static func destination(courseFolder: String, file: RemoteFileCandidate) throws -> RelativePath {
        let course = component(courseFolder)
        let section = component(file.sectionName)
        let module = component(file.moduleName)
        let remotePath = try file.remoteFilePath.split(separator: "/", omittingEmptySubsequences: true)
            .map { try validRemoteComponent(String($0)) }
        if file.moduleType == "resource", file.isSingleFileResource {
            let ext = URL(fileURLWithPath: file.filename).pathExtension
            let resourceName = ext.isEmpty ? module : "\(module).\(component(ext))"
            return try RelativePath([course, resourceName].joined(separator: "/"))
        }
        let prefix = file.sectionName.localizedCaseInsensitiveContains("material") ? [course] : [course, section]
        return try RelativePath((prefix + [module] + remotePath + [component(file.filename)]).joined(separator: "/"))
    }

    public static func component(_ input: String) -> String {
        let normalized = input.precomposedStringWithCanonicalMapping
        let replaced = normalized.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0, 47, 58: return "-"
            case 1...31: return "-"
            default: return Character(String(scalar))
            }
        }
        let collapsed = String(replaced).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "..", with: "-")
        let safe = collapsed.isEmpty || collapsed == "." || collapsed == ".." || collapsed == ".beepbar" ? "_" : collapsed
        return limited(safe)
    }

    private static func validRemoteComponent(_ input: String) throws -> String {
        guard input != ".", input != "..", input != ".beepbar", !input.contains("\0") else {
            throw LocalPathPolicyError.invalidRemotePath
        }
        return component(input)
    }

    private static func limited(_ value: String) -> String {
        guard value.utf8.count > 100 else { return value }
        let digest = SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        var prefix = ""
        for character in value {
            guard (prefix + String(character)).utf8.count <= 87 else { break }
            prefix.append(character)
        }
        return "\(prefix)-\(digest)"
    }
}
