import Foundation

public enum MoodleUniversity: String, CaseIterable, Sendable, Identifiable {
    case polimi
    case unipd

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .polimi: "Politecnico di Milano"
        case .unipd: "Università di Padova"
        }
    }
}

public struct MoodleSite: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let university: MoodleUniversity
    public let areaName: String?
    public let baseURL: URL

    public var displayName: String { areaName ?? university.displayName }
    public var loginURL: URL { baseURL.appending(path: "auth/shibboleth/index.php") }
    public var mobileLaunchURL: URL {
        var components = URLComponents(url: baseURL.appending(path: "admin/tool/mobile/launch.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "service", value: "moodle_mobile_app"),
            URLQueryItem(name: "passport", value: UUID().uuidString),
        ]
        return components.url!
    }
    public func isAuthenticatedLandingURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.host?.lowercased() == baseURL.host?.lowercased()
        else { return false }
        switch university {
        case .polimi:
            return url.path == "/my" || url.path == "/my/"
        case .unipd:
            return url.path == "/" || url.path == "/my" || url.path == "/my/"
        }
    }
    public var serverPolicy: WeBeepServerPolicy {
        WeBeepServerPolicy(
            endpoint: baseURL.appending(path: "webservice/rest/server.php"),
            siteURL: baseURL,
            scheme: "https",
            host: baseURL.host!,
            port: 443
        )
    }

    public static let polimi = MoodleSite(
        id: "polimi",
        university: .polimi,
        areaName: nil,
        baseURL: URL(string: "https://webeep.polimi.it")!
    )

    public static let unipd: [MoodleSite] = [
        MoodleSite(id: "unipd-stem", university: .unipd, areaName: "Macroarea STEM", baseURL: URL(string: "https://stem.elearning.unipd.it")!),
        MoodleSite(id: "unipd-medicine", university: .unipd, areaName: "Medicina e Chirurgia", baseURL: URL(string: "https://medicina.elearning.unipd.it")!),
        MoodleSite(id: "unipd-psychology", university: .unipd, areaName: "Psicologia", baseURL: URL(string: "https://psico.elearning.unipd.it")!),
        MoodleSite(id: "unipd-law", university: .unipd, areaName: "Giurisprudenza", baseURL: URL(string: "https://giuri.elearning.unipd.it")!),
        MoodleSite(id: "unipd-economics", university: .unipd, areaName: "Economia e Scienze Politiche", baseURL: URL(string: "https://sesp.elearning.unipd.it")!),
        MoodleSite(id: "unipd-humanities", university: .unipd, areaName: "Scienze Umane", baseURL: URL(string: "https://ssu.elearning.unipd.it")!),
        MoodleSite(id: "unipd-agriculture", university: .unipd, areaName: "Agraria e Medicina Veterinaria", baseURL: URL(string: "https://samv.elearning.unipd.it")!),
    ]

    public static let all = [polimi] + unipd

    public static func site(id: String?) -> MoodleSite {
        all.first(where: { $0.id == id }) ?? .polimi
    }
}
