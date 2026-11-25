import Foundation
import Testing
@testable import PrecisionButton

@Test func versionComparison() {
    #expect(Updater.isNewer("1.0.5", than: "1.0.4"))
    #expect(Updater.isNewer("v1.1", than: "1.0.9"))
    #expect(Updater.isNewer("1.0.10", than: "1.0.9"))
    #expect(!Updater.isNewer("1.0.4", than: "1.0.4"))
    #expect(!Updater.isNewer("1.0", than: "1.0.0"))
    #expect(!Updater.isNewer("1.0.3", than: "1.0.4"))
}

@Test func releaseParsingPicksTheDiskImage() throws {
    let json = #"{"tag_name":"v1.0.5","draft":false,"prerelease":false,"html_url":"https://github.com/x/y/releases/tag/v1.0.5","assets":[{"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},{"name":"Elgotune-1.0.5.dmg","browser_download_url":"https://github.com/x/y/releases/download/v1.0.5/Elgotune-1.0.5.dmg"}]}"#
    let release = try #require(Updater.parseRelease(Data(json.utf8)))
    #expect(release.version == "1.0.5")
    #expect(release.downloadURL.lastPathComponent == "Elgotune-1.0.5.dmg")
}

@Test func releaseParsingRejectsPrereleasesAndPlainHTTP() {
    let prerelease = #"{"tag_name":"v2.0","prerelease":true,"assets":[{"name":"a.dmg","browser_download_url":"https://e.com/a.dmg"}]}"#
    let http = #"{"tag_name":"v2.0","assets":[{"name":"a.dmg","browser_download_url":"http://e.com/a.dmg"}]}"#
    #expect(Updater.parseRelease(Data(prerelease.utf8)) == nil)
    #expect(Updater.parseRelease(Data(http.utf8)) == nil)
}
