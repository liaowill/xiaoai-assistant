import AppKit
import Foundation

// 生成 1024×1024 的应用主视觉，后续由 iconutil 转成 .icns
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S: CGFloat = 1024

let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: S, height: S).fill()

// Big Sur 风格：内缩圆角方形 + 蓝色渐变
let inset: CGFloat = 88
let box = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let shape = NSBezierPath(roundedRect: box, xRadius: 192, yRadius: 192)
let top = NSColor(calibratedRed: 0.24, green: 0.55, blue: 1.0, alpha: 1)
let bottom = NSColor(calibratedRed: 0.07, green: 0.29, blue: 0.80, alpha: 1)
let gradient = NSGradient(starting: top, ending: bottom)!
NSGraphicsContext.current?.saveGraphicsState()
shape.addClip()
gradient.draw(in: box, angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

// 白色扬声器：外环 + 中心
NSColor.white.setStroke()
NSColor.white.setFill()
let ring = NSBezierPath(ovalIn: NSRect(x: 322, y: 336, width: 380, height: 380))
ring.lineWidth = 44
ring.stroke()
NSBezierPath(ovalIn: NSRect(x: 452, y: 466, width: 120, height: 120)).fill()

// 两道声波弧线，强调「语音」
for radius in [268.0, 330.0] {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: 512, y: 526),
                  radius: radius,
                  startAngle: -38, endAngle: 38,
                  clockwise: false)
    arc.lineWidth = 30
    arc.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.92).setStroke()
    arc.stroke()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("无法生成 PNG")
}
let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_1024.png")
try png.write(to: url)
print("已生成 \(url.path)")
