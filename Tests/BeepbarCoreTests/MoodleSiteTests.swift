import Foundation
import Testing
@testable import BeepbarCore

@Suite struct MoodleSiteTests {
    @Test func legacySelectionFallsBackToPolimi() {
        #expect(MoodleSite.site(id: nil) == .polimi)
        #expect(MoodleSite.site(id: "unknown") == .polimi)
    }

    @Test func unipdStemBuildsIsolatedEndpoints() {
        let site = MoodleSite.site(id: "unipd-stem")
        #expect(site.university == .unipd)
        #expect(site.loginURL.absoluteString == "https://stem.elearning.unipd.it/auth/shibboleth/index.php")
        #expect(site.serverPolicy.endpoint.absoluteString == "https://stem.elearning.unipd.it/webservice/rest/server.php")
        #expect(site.serverPolicy.siteURL == site.baseURL)
        #expect(site.serverPolicy.acceptsPluginURL(URL(string: "https://stem.elearning.unipd.it/pluginfile.php/1/file.pdf")!))
        #expect(!site.serverPolicy.acceptsPluginURL(URL(string: "https://webeep.polimi.it/pluginfile.php/1/file.pdf")!))
    }

    @Test func officialUnipdAreasHaveUniqueIdentifiersAndHosts() {
        #expect(MoodleSite.unipd.count == 7)
        #expect(Set(MoodleSite.unipd.map(\.id)).count == MoodleSite.unipd.count)
        #expect(Set(MoodleSite.unipd.compactMap(\.baseURL.host)).count == MoodleSite.unipd.count)
    }
}
