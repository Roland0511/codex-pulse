import Foundation
import Testing
@testable import PulseCore

@Suite("速度档位元数据") struct SpeedTests {
    @Test func aliasesAndProfilePrecedence() {
        for (raw, tier) in [("default", SpeedTier.standard), ("standard", .standard), ("priority", .fast), ("fast", .fast), ("ultrafast", .ultrafast), ("flex", .unknown)] {
            #expect(CodexSpeedConfiguration.parse("service_tier = '\(raw)' # saved").tier == tier)
        }
        #expect(CodexSpeedConfiguration.parse("service_tier='priority'\nprofile='work'\n[profiles.work]\nservice_tier='ultrafast'").tier == .ultrafast)
        #expect(CodexSpeedConfiguration.parse("service_tier='fast'\nprofile='work'\n[profiles.work]\nmodel='synthetic'").tier == .fast)
        #expect(CodexSpeedConfiguration.parse("profile='work.dev'\n[profiles.\"work.dev\"]\nservice_tier='default'").tier == .standard)
        #expect(CodexSpeedConfiguration.parse("'service_tier'='ultrafast'").tier == .ultrafast)
    }
    @Test func missingAmbiguousAndMultilineValuesNeverBecomeConfirmedTiers() {
        for text in ["", "service_tier=42", "service_tier='fast' trailing", "service_tier='fast'\nservice_tier='ultrafast'", "profile=42\nservice_tier='fast'", "service_tier='fast'\nprofile='work'\n[profiles.work]\nservice_tier=42"] {
            #expect(CodexSpeedConfiguration.parse(text).tier == .unknown)
        }
        let text = """
        developer_instructions = '''
        service_tier='ultrafast'
        [profiles.work]
        '''
        service_tier='default'
        [desktop]
        service_tier='ultrafast'
        """
        #expect(CodexSpeedConfiguration.parse(text).tier == .standard)
    }
    @Test func projectsOnlyKnownSpeedNotificationAndHashesIdentifier() throws {
        let id = "123e4567-e89b-12d3-a456-426614174000"
        let data = Data("""
        {"params":{"threadSettings":{"serviceTier":"ultrafast","cwd":"synthetic/private","summary":"do not retain"},"threadId":"\(id)"},"method":"thread/settings/updated"}
        """.utf8)
        #expect(SpeedMetadataUpdate.read(data)?.session == ActivitySignal.hash(id))
        #expect(SpeedMetadataUpdate.read(data)?.tier == .ultrafast)
        #expect(try SpeedJSONProjection.read(data).count == 3)
        #expect(SpeedMetadataUpdate.read(Data("{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"serviceTier ultrafast\"}}".utf8)) == nil)
        #expect(SpeedMetadataUpdate.read(Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "ultrafast", with: "unsupported").utf8)) == nil)
        #expect(SpeedMetadataUpdate.read(Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"ultrafast\"", with: "null").utf8))?.tier == .standard)
    }
    @Test func handshakeIDKeepsItsValueWhileOpaqueResultOnlyKeepsPresence() throws {
        let result = try SpeedJSONProjection.read(Data(#"{"id":1,"result":{"userAgent":"synthetic"}}"#.utf8))
        #expect(result == ["id": "1", "result": "present"])
    }
    @Test func malformedDuplicateOversizedAndRequestsAreRejected() {
        let id = "123e4567-e89b-12d3-a456-426614174000"
        for json in [
            "{\"method\":\"thread/settings/updated\",\"method\":\"thread/settings/updated\"}",
            "{\"method\":\"thread/settings/updated\",\"params\":{\"threadId\":\"\(id)\",\"threadSettings\":{\"serviceTier\":\"fast\",\"serviceTier\":\"ultrafast\"}}}",
            "{\"id\":3,\"method\":\"thread/settings/updated\",\"params\":{\"threadId\":\"\(id)\",\"threadSettings\":{\"serviceTier\":\"fast\"}}}",
            "{\"method\":\"thread/settings/updated\",\"params\":{\"threadId\":\"wrong-id\",\"threadSettings\":{\"serviceTier\":\"fast\"}}}",
            "{\"method\":\"thread/settings/updated\",\"params\":NaN}", "{"
        ] { #expect(SpeedMetadataUpdate.read(Data(json.utf8)) == nil) }
        #expect(SpeedMetadataUpdate.read(Data(repeating: 32, count: 2_097_153)) == nil)
    }
}
