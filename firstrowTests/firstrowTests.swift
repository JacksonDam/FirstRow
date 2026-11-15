//
//  firstrowTests.swift
//  firstRowTests
//
//  Created by Jackson Dam on 19/12/2024.
//

import XCTest
@testable import First_Row

final class firstRowTests: XCTestCase {
    func testVirtualSceneLayoutMatchesReferenceSceneAt1080p() {
        let layout = MenuVirtualSceneLayout(
            containerSize: CGSize(width: 1920, height: 1080),
            virtualSize: MenuVirtualScenePreset.widescreen,
        )

        XCTAssertEqual(layout.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.width, 1920, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.height, 1080, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.width, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.height, 0, accuracy: 0.0001)
    }

    func testVirtualSceneLayoutScalesUpOnHigherLogicalResolution() {
        let layout = MenuVirtualSceneLayout(
            containerSize: CGSize(width: 2560, height: 1440),
            virtualSize: MenuVirtualScenePreset.widescreen,
        )

        XCTAssertEqual(layout.scale, 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.width, 2560, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.height, 1440, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.width, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.height, 0, accuracy: 0.0001)
    }

    func testVirtualSceneLayoutCentersOnNon16By9Display() {
        let layout = MenuVirtualSceneLayout(
            containerSize: CGSize(width: 1680, height: 1050),
            virtualSize: MenuVirtualScenePreset.widescreen,
        )

        XCTAssertEqual(layout.scale, 0.875, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.width, 1680, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.height, 945, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.width, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.height, 52.5, accuracy: 0.0001)
    }

    func testVirtualSceneLayoutMatchesIPadCanvasOnFourByThreeDisplay() {
        let layout = MenuVirtualSceneLayout(
            containerSize: CGSize(width: 1024, height: 768),
            virtualSize: MenuVirtualScenePreset.iPad,
        )

        XCTAssertEqual(layout.scale, 1024.0 / 1440.0, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.width, 1024, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.height, 768, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.width, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.height, 0, accuracy: 0.0001)
    }

    func testScaledSceneOffsetsShrinkForIPadCanvasWidth() {
        let scaledOffset = MenuVirtualScenePreset.scaledX(
            -214,
            for: MenuVirtualScenePreset.iPad,
        )

        XCTAssertEqual(scaledOffset, -160.5, accuracy: 0.0001)
    }

    func testIPadCanvasAddsExtraMenuGap() {
        let gap = MenuVirtualScenePreset.additionalMenuGapX(
            for: MenuVirtualScenePreset.iPad,
        )

        XCTAssertEqual(gap, 56, accuracy: 0.0001)
    }
}

/// Telling a song's lyrics from another song's, among what LRCLIB sends back.
final class LyricsLookupTests: XCTestCase {
    private func record(_ title: String, _ artist: String, _ duration: Double, synced: Bool = true, plain: Bool = true, instrumental: Bool = false) -> LyricsLookupRecord {
        LyricsLookupRecord(
            trackName: title, artistName: artist, albumName: "An Album", duration: duration, instrumental: instrumental,
            plainLyrics: instrumental || !plain ? nil : "One line\nAnother line",
            syncedLyrics: instrumental || !synced ? nil : "[00:01.00] One line\n[00:04.50] Another line",
        )
    }

    private func query(_ title: String, _ artist: String, _ duration: Double) -> LyricsLookupQuery {
        LyricsLookupQuery(title: title, artist: artist, album: "An Album", duration: duration)
    }

    func testTitlesLoseTheirAsides() {
        XCTAssertEqual(LyricsMatching.cleanedTitle("Get Lucky (feat. Pharrell Williams & Nile Rodgers)"), "Get Lucky")
        XCTAssertEqual(LyricsMatching.cleanedTitle("Here Comes the Sun - Remastered 2009"), "Here Comes the Sun")
        XCTAssertEqual(LyricsMatching.cleanedTitle("A Song [Live at the Hall] (2011 Remaster)"), "A Song")
        XCTAssertEqual(LyricsMatching.cleanedTitle("A Song feat. Someone Else"), "A Song")
        XCTAssertEqual(LyricsMatching.cleanedTitle("A Song (Mono Version)"), "A Song")
    }

    func testTitlesKeepWhatIsTheirs() {
        XCTAssertEqual(LyricsMatching.cleanedTitle("Live and Let Die"), "Live and Let Die")
        XCTAssertEqual(LyricsMatching.cleanedTitle("A Song (Acoustic)"), "A Song (Acoustic)")
        XCTAssertEqual(LyricsMatching.cleanedTitle("A Song (Somebody's Remix)"), "A Song (Somebody's Remix)")
        XCTAssertEqual(LyricsMatching.cleanedTitle("Up - And Down"), "Up - And Down")
        XCTAssertEqual(LyricsMatching.cleanedTitle("(Live)"), "(Live)")
        XCTAssertEqual(LyricsMatching.cleanedTitle("Liverpool Lullaby"), "Liverpool Lullaby")
    }

    func testFoldingIgnoresCaseAccentsAndPunctuation() {
        XCTAssertEqual(LyricsMatching.folded("Señorita!"), "senorita")
        XCTAssertEqual(LyricsMatching.folded("Don't  Stop -- Believin’"), "dont stop believin")
        XCTAssertEqual(LyricsMatching.folded("Rock & Roll"), "rock and roll")
    }

    func testArtistsWrittenDifferentlyAreTheSame() {
        func same(_ first: String, _ second: String) -> Bool {
            !LyricsMatching.artistForms(first).isDisjoint(with: LyricsMatching.artistForms(second))
        }
        XCTAssertTrue(same("Simon & Garfunkel", "Simon and Garfunkel"))
        XCTAssertTrue(same("Shawn Mendes & Camila Cabello", "Shawn Mendes, Camila Cabello"))
        XCTAssertTrue(same("Beyoncé", "BEYONCE"))
        XCTAssertTrue(same("Daft Punk feat. Pharrell Williams", "Daft Punk"))
        XCTAssertTrue(same("Mars, Bruno", "Bruno Mars"))
        XCTAssertFalse(same("The Beatles", "The Rolling Stones"))
        XCTAssertFalse(same("Queen", "Queens of the Stone Age"))
    }

    func testSameSongNeedsTitleArtistAndLength() {
        let asked = query("A Song (Remastered)", "Beyoncé", 200)
        XCTAssertTrue(LyricsMatching.isSameSong(record("A Song", "Beyonce", 202), as: asked))
        XCTAssertTrue(LyricsMatching.isSameSong(record("a song - Live", "BEYONCÉ feat. Someone", 197), as: asked))
        XCTAssertFalse(LyricsMatching.isSameSong(record("A Song", "Beyonce", 204), as: asked))
        XCTAssertFalse(LyricsMatching.isSameSong(record("A Song", "Somebody Else", 200), as: asked))
        XCTAssertFalse(LyricsMatching.isSameSong(record("A Song Again", "Beyonce", 200), as: asked))
        // A song whose length isn't known can't be told from another recording of it.
        XCTAssertFalse(LyricsMatching.isSameSong(record("A Song", "Beyonce", 200), as: query("A Song", "Beyoncé", 0)))
    }

    func testTimedLyricsComeBeforePlainThenTheNearestLength() {
        let asked = query("A Song", "A Band", 200)
        let best = LyricsMatching.best(of: [
            record("A Song", "Another Band", 200),
            record("A Song", "A Band", 200, synced: false),
            record("A Song", "A Band", 203),
            record("A Song", "A Band", 201),
            record("A Song", "A Band", 200, instrumental: true),
        ], for: asked)
        XCTAssertEqual(best?.record.duration, 201)
        XCTAssertEqual(best?.lyrics.isSynced, true)
        let plain = LyricsMatching.best(of: [record("A Song", "A Band", 202, synced: false), record("A Song", "A Band", 199, synced: false)], for: asked)
        XCTAssertEqual(plain?.record.duration, 199)
        XCTAssertEqual(plain?.lyrics.isSynced, false)
        XCTAssertNil(LyricsMatching.best(of: [record("A Song", "Another Band", 200), record("A Song", "A Band", 200, instrumental: true)], for: asked))
    }

    func testLyricsOfARecord() {
        XCTAssertEqual(LyricsMatching.lyrics(from: record("A Song", "A Band", 200))?.lines.map(\.time), [1, 4.5])
        XCTAssertEqual(LyricsMatching.lyrics(from: record("A Song", "A Band", 200, synced: false))?.lines.map(\.text), ["One line", "Another line"])
        XCTAssertNil(LyricsMatching.lyrics(from: record("A Song", "A Band", 200, instrumental: true)))
        XCTAssertNil(LyricsMatching.lyrics(from: record("A Song", "A Band", 200, synced: false, plain: false)))
    }

    func testASongIsKeptUnderOneNameHoweverItIsWritten() {
        XCTAssertEqual(LyricsMatching.key(for: query("A Song (Remastered)", "Beyoncé", 200.4)), LyricsMatching.key(for: query("a song", "BEYONCE", 200)))
        XCTAssertNotEqual(LyricsMatching.key(for: query("A Song", "Beyoncé", 200)), LyricsMatching.key(for: query("A Song", "Beyoncé", 230)))
    }
}

final class AppLanguageTests: XCTestCase {
    func testTagsNameTheLanguagesFirstRowHas() {
        XCTAssertEqual(AppLanguage(tag: "de-AT"), .german)
        XCTAssertEqual(AppLanguage(tag: "fr_CA.UTF-8"), .french)
        XCTAssertEqual(AppLanguage(tag: "es-419"), .spanish)
        XCTAssertEqual(AppLanguage(tag: "ja"), .japanese)
        XCTAssertEqual(AppLanguage(tag: "ko_KR.UTF-8"), .korean)
        XCTAssertEqual(AppLanguage(tag: "en-GB"), .english)
        XCTAssertNil(AppLanguage(tag: "pt-BR"))
        XCTAssertNil(AppLanguage(tag: "C"))
        XCTAssertNil(AppLanguage(tag: ""))
    }

    func testChineseGoesByItsWritingThenByItsPlace() {
        XCTAssertEqual(AppLanguage(tag: "zh-Hans"), .chineseSimplified)
        XCTAssertEqual(AppLanguage(tag: "zh-Hant"), .chineseTraditional)
        XCTAssertEqual(AppLanguage(tag: "zh-Hant-CN"), .chineseTraditional)
        XCTAssertEqual(AppLanguage(tag: "zh-Hans-TW"), .chineseSimplified)
        XCTAssertEqual(AppLanguage(tag: "zh_CN.UTF-8"), .chineseSimplified)
        XCTAssertEqual(AppLanguage(tag: "zh_TW.UTF-8"), .chineseTraditional)
        XCTAssertEqual(AppLanguage(tag: "zh-HK"), .chineseTraditional)
        XCTAssertEqual(AppLanguage(tag: "zh-SG"), .chineseSimplified)
        XCTAssertEqual(AppLanguage(tag: "zh"), .chineseSimplified)
    }

    func testEveryTableHasTheSameWords() {
        let german = Set(German.words.keys)
        for language in [AppLanguage.french, .spanish, .japanese, .korean, .chineseSimplified, .chineseTraditional] {
            XCTAssertEqual(Set(language.words?.keys.map { $0 } ?? []), german, "\(language)")
        }
    }

    func testEveryTableKeepsWhatIsFilledIn() {
        func places(_ words: String) -> Int {
            words.components(separatedBy: "%@").count - 1 + (1 ... 9).reduce(0) { $0 + words.components(separatedBy: "%\($1)$@").count - 1 }
        }
        for language in [AppLanguage.german, .french, .spanish, .japanese, .korean, .chineseSimplified, .chineseTraditional] {
            for (english, theirs) in language.words ?? [:] {
                XCTAssertEqual(places(theirs), places(english), "\(language): \(english)")
            }
        }
    }
}
