import AppKit

let output = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: output).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = CGRect(x: 64, y: 64, width: 896, height: 896)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 196, yRadius: 196)
        NSColor(calibratedRed: 0.31, green: 0.39, blue: 0.29, alpha: 1).setFill()
        shape.fill()
        let inset = NSBezierPath(roundedRect: rect.insetBy(dx: 38, dy: 38), xRadius: 160, yRadius: 160)
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke(); inset.lineWidth = 2; inset.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let font = NSFont(name: "STSongti-SC-Regular", size: 560) ?? NSFont.systemFont(ofSize: 560)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.87, alpha: 1), .paragraphStyle: paragraph]
        ("墨" as NSString).draw(in: CGRect(x: 140, y: 170, width: 744, height: 680), withAttributes: attributes)
        let line = NSBezierPath(); line.move(to: NSPoint(x: 410, y: 214)); line.line(to: NSPoint(x: 614, y: 214)); line.lineWidth = 9; line.lineCapStyle = .round
        NSColor(calibratedRed: 0.72, green: 0.77, blue: 0.60, alpha: 0.75).setStroke(); line.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
