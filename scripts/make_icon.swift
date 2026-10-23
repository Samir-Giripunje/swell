import AppKit

let outputPath = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.96, alpha: 1),
])!.draw(in: path, angle: -60)

let symbolConfig = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfig) {
    let origin = NSPoint(x: tile.midX - symbol.size.width / 2, y: tile.midY - symbol.size.height / 2)
    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
}
image.unlockFocus()

let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
