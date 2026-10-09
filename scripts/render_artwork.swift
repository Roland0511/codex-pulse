// 可编辑的矢量图稿；色板来自冻结的 tokens，输出完整 ICNS 和 Retina 安装背景。
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 5 else { fatalError("需要色板、布局、输出目录及 candidate / release") }
let palette = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[1]))) as! [String: Any]
let layout = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[2]))) as! [String: Any]
let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let colors = palette["colors"] as! [String: [String: String]]

func color(_ role: String, _ theme: String) -> NSColor {
    let value = UInt32(colors[role]![theme]!.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}
let dark = color("surface", "dark")
let ink = color("ink", "light")
let mint = color("signal", "dark")
let teal = color("signal", "light")
let muted = color("muted", "light")
let white = color("surface", "light")

func bitmap(width: Int, height: Int, scale: CGFloat, draw: () -> Void) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return image
}
func rounded(_ rect: NSRect, _ radius: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func save(_ image: NSBitmapImageRep, _ name: String) throws {
    try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
let icon = layout["icon"] as! [String: Int]
let canvas = CGFloat(icon["canvas"]!)
let inset = CGFloat(icon["inset"]!)
let tile = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pointSize in [16, 32, 128, 256, 512] {
    for density in [1, 2] {
        let pixels = pointSize * density
        let image = bitmap(width: pixels, height: pixels, scale: CGFloat(pixels) / canvas) {
            let plate = NSBezierPath(roundedRect: tile, xRadius: CGFloat(icon["radius"]!), yRadius: CGFloat(icon["radius"]!))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = dark.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 20
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            dark.setFill(); plate.fill()
            NSGraphicsContext.restoreGraphicsState()
            let top = dark.blended(withFraction: 0.075, of: white)!
            NSGradient(starting: dark, ending: top)!.draw(in: plate, angle: 90)
            white.withAlphaComponent(0.12).setStroke()
            plate.lineWidth = 2; plate.stroke()
            let capsule = NSBezierPath(roundedRect: NSRect(x: 222, y: 402, width: 580, height: 220), xRadius: 110, yRadius: 110)
            dark.withAlphaComponent(0.38).setFill(); capsule.fill()
            color("ink", "dark").withAlphaComponent(0.78).setStroke()
            capsule.lineWidth = max(11, canvas / CGFloat(pointSize) * 0.60)
            capsule.stroke()
            let lineHeight = max(24, canvas / CGFloat(pointSize) * 0.6)
            let track = NSRect(x: 290, y: 512 - lineHeight / 2, width: 444, height: lineHeight)
            rounded(track, lineHeight / 2, mint.withAlphaComponent(0.20))
            let fill = NSRect(x: track.minX, y: track.minY, width: track.width * 0.66, height: lineHeight)
            rounded(fill, lineHeight / 2, mint)
            let point = max(15, lineHeight * 0.65)
            rounded(NSRect(x: fill.maxX - point * 1.6, y: 512 - point / 2, width: point, height: point), point / 2, white)
        }
        let suffix = density == 2 ? "@2x" : ""
        try image.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png"))
        if pixels == 1024 { try save(image, "AppIcon.png") }
    }
}

let window = layout["window"] as! [String: Int]
let width = CGFloat(window["width"]!)
let height = CGFloat(window["height"]!)
let appPosition = layout["appPosition"] as! [CGFloat]
func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, centered: Bool = false) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let string = value as NSString
    let measured = string.size(withAttributes: attributes)
    string.draw(at: NSPoint(x: centered ? x - measured.width / 2 : x, y: height - top - measured.height), withAttributes: attributes)
}
let background = bitmap(width: Int(width * 2), height: Int(height * 2), scale: 2) {
    white.blended(withFraction: 0.025, of: teal)!.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    text("Codex Pulse", x: width / 2, top: 38, size: 28, weight: .semibold, color: ink, centered: true)
    text("将左侧应用拖入右侧「应用程序」", x: width / 2, top: 84, size: 15, weight: .regular, color: muted, centered: true)
    // 箭头与原生图标中心同轴；品牌细线只表达安装方向。
    let center = height - appPosition[1]
    let middle = width / 2
    let path = NSBezierPath()
    path.move(to: NSPoint(x: middle - 32, y: center)); path.line(to: NSPoint(x: middle + 31, y: center))
    path.move(to: NSPoint(x: middle + 21, y: center + 9)); path.line(to: NSPoint(x: middle + 31, y: center)); path.line(to: NSPoint(x: middle + 21, y: center - 9))
    path.lineWidth = 2.2; path.lineCapStyle = .round; path.lineJoinStyle = .round
    teal.withAlphaComponent(0.85).setStroke(); path.stroke()
    color("edge", "light").setFill()
    NSRect(x: 40, y: height - 326, width: width - 80, height: 1).fill()
    let note = arguments[4] == "candidate" ? "预览安装包 · 尚未公证" : "macOS 14 及以上"
    text(note, x: 40, top: 346, size: 12, weight: .regular, color: muted)
    let ending = "安装后请弹出磁盘映像" as NSString
    let endingWidth = ending.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
    text(ending as String, x: width - 40 - endingWidth, top: 346, size: 12, weight: .regular, color: muted)
}
try save(background, "installer-background@2x.png")
background.size = NSSize(width: width, height: height)
// TIFF 记录逻辑尺寸，Finder 在 Retina 和普通屏幕上均保持相同布局。
try background.tiffRepresentation!.write(to: output.appendingPathComponent("installer-background.tiff"))
print("图稿已生成")
