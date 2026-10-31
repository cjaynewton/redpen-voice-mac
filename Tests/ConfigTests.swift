import XCTest
import VoiceCore

/// config.json is meant to be read and edited by hand. The synthesized decoder failed the whole file when a single
/// key was missing or had the wrong type, Config.load() then returned the defaults (engine, talk key, first run all
/// reset), and the next change in Settings wrote those defaults over the file.
final class ConfigTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rv-config-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func json(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var c = Config()
        c.engine = "whisper"; c.firstRunDone = true; c.talkKey = "rightOption"; c.typingWPM = 70
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testAMissingKeyKeepsEveryOtherSetting() throws {
        let data = try json { $0.removeValue(forKey: "sounds"); $0.removeValue(forKey: "mode") }
        let c = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(c.engine, "whisper")
        XCTAssertTrue(c.firstRunDone)
        XCTAssertEqual(c.talkKey, "rightOption")
        XCTAssertEqual(c.typingWPM, 70)
        XCTAssertEqual(c.sounds, Config().sounds, "a missing key takes its default")
        XCTAssertEqual(c.mode, Config().mode)
    }

    func testAWrongTypeKeepsEveryOtherSetting() throws {
        let data = try json { $0["typingWPM"] = "fast"; $0["pauseMedia"] = "yes" }
        let c = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(c.engine, "whisper")
        XCTAssertTrue(c.firstRunDone)
        XCTAssertNil(c.typingWPM)
        XCTAssertEqual(c.pauseMedia, Config().pauseMedia)
    }

    func testRoundTripKeepsEverything() throws {
        var c = Config()
        c.mode = "noUms"; c.engine = "live"; c.inputDevice = "mic-1"; c.resumeMedia = false; c.appearance = "dark"
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.mode, "noUms"); XCTAssertEqual(back.engine, "live"); XCTAssertEqual(back.inputDevice, "mic-1")
        XCTAssertEqual(back.resumeMedia, false); XCTAssertEqual(back.appearance, "dark")
    }

    func testLoadReadsAFileWithAMissingKey() throws {
        let file = dir.appendingPathComponent("config.json")
        try json { $0.removeValue(forKey: "showLevel") }.write(to: file)
        let c = Config.load(from: file)
        XCTAssertEqual(c.engine, "whisper")
        XCTAssertTrue(c.firstRunDone)
    }

    func testABrokenFileIsMovedAsideNotOverwritten() throws {
        let file = dir.appendingPathComponent("config.json")
        let typed = "{\n  \"engine\" : whisper,\n  \"firstRunDone\" : true\n"  // unquoted value, no closing brace
        try typed.write(to: file, atomically: true, encoding: .utf8)
        let c = Config.load(from: file, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(c.engine, Config().engine)
        c.save(to: file)
        let aside = dir.appendingPathComponent("config.damaged-1800000000.json")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), typed, "what you typed is kept")
    }

    func testTheOldFastEngineOpensAsInstant() throws {
        let file = dir.appendingPathComponent("config.json")
        try json { $0["engine"] = "parakeet" }.write(to: file)
        XCTAssertEqual(Config.load(from: file).engine, "live")
    }
}
