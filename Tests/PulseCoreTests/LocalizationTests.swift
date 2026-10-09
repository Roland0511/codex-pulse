import Foundation
import Testing
@testable import PulseCore

@Suite("Chinese and English formatting") struct LocalizationTests {
    let english = PulseText(language: .english)
    let chinese = PulseText(language: .simplifiedChinese)

    @Test func systemLanguageAndUnsupportedFallback() {
        #expect(PulseLanguage.system.resolved(preferredLanguages: ["zh-CN"]) == .simplifiedChinese)
        #expect(PulseLanguage.system.resolved(preferredLanguages: ["en-GB"]) == .english)
        #expect(PulseLanguage.system.resolved(preferredLanguages: ["fr-FR"]) == .english)
        #expect(PulseLanguage.system.resolved(preferredLanguages: []) == .english)
        #expect(PulseLanguage.english.resolved(preferredLanguages: ["zh-CN"]) == .english)
    }
    @Test func missingQuotaRemainsUnknownAndZeroRemainsZero() {
        #expect(QuotaText.percentage(nil, using: english) == "Unknown")
        #expect(QuotaText.percentage(nil, using: chinese) == "未知")
        #expect(QuotaText.percentage(0, using: english) == "0%")
        #expect(QuotaText.percentage(0.2, using: english) == "<1%")
        #expect(QuotaText.duration(60, using: english) == "1 hour")
        #expect(QuotaText.duration(300, using: english) == "5 hours")
        #expect(english.string("reminders") == "Low quota alerts (20% / 10%)")
    }
    @Test func realWindowLengthsAndServiceNamesArePreserved() {
        let window = QuotaWindow(bucketID: "fixture", bucketName: "Service label", slot: "primary",
                                 usedPercent: 31, durationMinutes: 10080, resetsAt: nil)
        #expect(window.localizedName(using: english) == "Service label · 7-day quota")
        #expect(window.localizedName(using: chinese) == "Service label · 7天额度")
        let unknown = QuotaWindow(bucketID: "fixture", slot: "secondary", usedPercent: nil,
                                  durationMinutes: nil, resetsAt: nil)
        #expect(unknown.localizedName(using: english) == "fixture · Unknown window")
    }
    @Test func countdownPluralAndCompactCopy() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(QuotaText.countdown(nil, now: now, using: english) == "Reset time unknown")
        #expect(QuotaText.countdown(now, now: now, using: english) == "Reset time reached")
        #expect(QuotaText.countdown(now.addingTimeInterval(1), now: now, using: english) == "Resets in 1 minute")
        #expect(QuotaText.countdown(now.addingTimeInterval(61), now: now, using: english) == "Resets in 2 minutes")
        #expect(QuotaText.countdown(now.addingTimeInterval(86400), now: now, using: english, compact: true) == "Resets in 1d")
        #expect(QuotaText.countdown(now.addingTimeInterval(86400), now: now, using: chinese, compact: true) == "1天后重置")
    }
    @Test func catalogParityErrorsAndDateLocale() {
        #expect(Set(LocalizationCatalog.strings["en"]!.keys) == Set(LocalizationCatalog.strings["zh-Hans"]!.keys))
        #expect(QuotaError.unauthenticated.message(using: english).hasPrefix("Signed out"))
        #expect(QuotaError.unauthenticated.message(using: chinese).hasPrefix("未登录"))
        #expect(english.locale.language.languageCode?.identifier == "en")
        #expect(chinese.locale.language.languageCode?.identifier == "zh")
        let date = Date(timeIntervalSince1970: 1800000000)
        #expect(english.date(date) != chinese.date(date))
        #expect(english.string("activity.trust", 3, 12) == "Awaiting trust (3/12)")
    }
}
