import AppKit
import Combine
import PulseCore
import SwiftUI

@MainActor final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()
    @Published private(set) var codex: CodexAppearance?
    @Published private(set) var followsCodex = true
    private(set) var selection = "codex"
    private let url: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var stamp: Date?
    private var cachedPalette = Palette(codex: nil)

    init(url: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.url = url ?? home.appendingPathComponent("config.toml")
    }
    func start(_ selection: String) {
        setSelection(selection); reload(force: true)
        // 监听父目录，兼容 Codex 原子替换配置文件；不会轮询或改写 Codex 配置。
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.changed() }
        }
        source.setCancelHandler { close(fd) }
        watcher = source; source.resume()
    }
    private func changed() {
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.reload(); self?.pending = nil
        }
    }
    func reload(force: Bool = false) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = attributes?[.modificationDate] as? Date
        guard force || date != stamp else { return }
        stamp = date
        guard let size = attributes?[.size] as? NSNumber, size.intValue <= 1_048_576,
              let text = try? String(contentsOf: url, encoding: .utf8) else { cachedPalette = Palette(codex: nil); codex = nil; applyMode(); return }
        let next = CodexAppearance.parse(text)
        if next != codex { cachedPalette = Palette(codex: followsCodex ? next : nil); codex = next; applyMode() }
    }
    func setSelection(_ selection: String) {
        cachedPalette = Palette(codex: selection == "codex" ? codex : nil)
        self.selection = selection; followsCodex = selection == "codex"; applyMode()
    }
    private func applyMode() {
        let mode = followsCodex ? codex?.mode ?? "system" : selection
        NSApp?.appearance = mode == "dark" ? NSAppearance(named: .darkAqua) : mode == "light" ? NSAppearance(named: .aqua) : nil
    }
    var palette: Palette { cachedPalette }
    func stop() { watcher?.cancel(); watcher = nil; pending?.cancel() }
}

struct Palette {
    let codex: CodexAppearance?
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
    private static func mix(_ a: UInt32, _ b: UInt32, amount: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { value, shift in
            let channel = Double((a >> shift) & 255) * amount + Double((b >> shift) & 255) * (1 - amount)
            return value | (UInt32(channel.rounded()) << shift)
        }
    }
    let surface: Color
    let ink: Color
    let signal: Color
    let muted: Color
    let edge: Color
    let track: Color
    let warning = Color(nsColor: .systemOrange)
    let danger = Color(nsColor: .systemRed)
    init(codex: CodexAppearance?) {
        self.codex = codex
        surface = Self.color(codex?.light?.surface ?? DesignTokens.surfaceLight, codex?.dark?.surface ?? DesignTokens.surfaceDark)
        ink = Self.color(codex?.light?.ink ?? DesignTokens.inkLight, codex?.dark?.ink ?? DesignTokens.inkDark)
        signal = Self.color(codex?.light?.accent ?? DesignTokens.signalLight, codex?.dark?.accent ?? DesignTokens.signalDark)
        func derived(_ light: UInt32, _ dark: UInt32, amount: Double, accent: Bool = false) -> Color {
            func value(_ colors: ChromeColors?, _ fallback: UInt32) -> UInt32 {
                guard let colors else { return fallback }
                return Self.mix(accent ? colors.accent : colors.ink, colors.surface, amount: amount)
            }
            return Self.color(value(codex?.light, light), value(codex?.dark, dark))
        }
        muted = derived(DesignTokens.mutedLight, DesignTokens.mutedDark, amount: 0.65)
        edge = derived(DesignTokens.edgeLight, DesignTokens.edgeDark, amount: 0.16)
        track = derived(DesignTokens.trackLight, DesignTokens.trackDark, amount: 0.2, accent: true)
    }
}
