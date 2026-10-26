import Foundation
import Testing
@testable import SolaraLive

struct UnknownKeysTests {
  static let saved = """
    {"folders":{},"folderOrder":[],"items":{},"known":{},"unread":{},"hidden":{},"completed":{},"expandedStacks":{},"accounts":{},
    "config":{"githubClientId":"abc","bitbucketUser":"","confluenceSite":"","confluenceEmail":"","googleClientId":"","linearClientId":"lin_1","nested":{"a":[1,true,null,"x"]}},
    "calendar":{"alertLead":"5","alertCondition":"always","showPreview":true,"showTimeToNext":false,"hiddenCalendarIds":["c1"],"prompted":true,"snoozeMinutes":10},
    "meetingGroups":{},"dismissedAlerts":[],"futureSection":{"version":3}}
    """

  static func object(_ text: String) throws -> NSDictionary {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
  }

  @Test func unknownConfigCalendarAndTopLevelKeysRoundTripUnchanged() throws {
    let state = LiveState.load(Self.saved)
    #expect(state.config.githubClientId == "abc")
    #expect(state.calendar.alertLead == "5")
    let out = try Self.object(try state.persistedJSON())
    let config = try #require(out["config"] as? NSDictionary)
    #expect(config["linearClientId"] as? String == "lin_1")
    #expect((config["nested"] as? NSDictionary) == ["a": [1, true, NSNull(), "x"]] as NSDictionary)
    let calendar = try #require(out["calendar"] as? NSDictionary)
    #expect(calendar["snoozeMinutes"] as? Int == 10)
    #expect((out["futureSection"] as? NSDictionary) == ["version": 3] as NSDictionary)
  }

  @Test func editsKeepTheKeysTheyDontTouch() throws {
    var state = LiveState.load(Self.saved)
    state.updateConfig(ConfigPatch(githubClientId: "def"))
    state.updateCalendarSettings(CalendarSettingsPatch(alertLead: "never"))
    let out = try Self.object(try state.persistedJSON())
    let config = try #require(out["config"] as? NSDictionary)
    #expect(config["githubClientId"] as? String == "def")
    #expect(config["linearClientId"] as? String == "lin_1")
    let calendar = try #require(out["calendar"] as? NSDictionary)
    #expect(calendar["alertLead"] as? String == "never")
    #expect(calendar["snoozeMinutes"] as? Int == 10)
  }

  @Test func aFileWithoutUnknownKeysEncodesAsBefore() throws {
    let state = LiveState.load(#"{"config":{"githubClientId":"x"}}"#)
    #expect(state.extra.isEmpty)
    #expect(state.config.extra.isEmpty)
    let config = try #require(try Self.object(try state.persistedJSON())["config"] as? NSDictionary)
    #expect(Set(config.allKeys.compactMap { $0 as? String }) == ["githubClientId", "bitbucketUser", "confluenceSite", "confluenceEmail", "googleClientId"])
  }
}
