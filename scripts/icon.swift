// Draws the app icon: a planet with its tilted orbit, the used part of the orbit lit in the accent blue, the satellite at its tip.
// Run from the repo: swiftc -o build/icon scripts/icon.swift && build/icon <AppIcon.icns> [docs/logo.png]
import AppKit
import SwiftUI

let accent = Color(red: 0x34 / 255, green: 0x6b / 255, blue: 0xf1 / 255)
let center = CGPoint(x: 512, y: 512)

/// Point on the orbit (an ellipse tilted 20 degrees) at parameter t, in radians.
func orbit(_ t: Double) -> CGPoint {
    let (a, b, tilt) = (260.0, 115.0, -20.0 * .pi / 180)
    let (x, y) = (a * cos(t), b * sin(t))
    return CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt), y: center.y + x * sin(tilt) + y * cos(tilt))
}

func arc(from: Double, to: Double) -> Path {
    Path { p in
        p.move(to: orbit(from))
        for i in 1...200 { p.addLine(to: orbit(from + (to - from) * Double(i) / 200)) }
    }
}

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: an 824 pt rounded square centered in 1024.
            ZStack {
                RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.09), Color(white: 0.02)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 4)
            }
            .frame(width: 824, height: 824)
            Canvas { ctx, _ in
                let line = GraphicsContext.Shading.color(.white.opacity(0.55))
                let stroke = StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
                ctx.stroke(arc(from: 0, to: 2 * .pi), with: line, style: stroke)
                ctx.stroke(Path(ellipseIn: CGRect(x: center.x - 72, y: center.y - 72, width: 144, height: 144)), with: line, style: stroke)
                // The used share of the window, starting at the far left and running clockwise over the top.
                let start = Double.pi, used = 1.3 * Double.pi
                ctx.stroke(arc(from: start, to: start + used), with: .color(accent), style: stroke)
                // The satellite.
                let tip = orbit(start + used)
                ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 30, y: tip.y - 30, width: 60, height: 60)), with: .color(.white))
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func png(_ px: Int) -> Data {
    let r = ImageRenderer(content: Icon())
    r.scale = CGFloat(px) / 1024
    return NSBitmapImageRep(cgImage: r.cgImage!).representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
let set = FileManager.default.temporaryDirectory.appending(path: "OrbitAppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try MainActor.assumeIsolated { png(size) }.write(to: set.appending(path: "icon_\(size)x\(size).png"))
    try MainActor.assumeIsolated { png(size * 2) }.write(to: set.appending(path: "icon_\(size)x\(size)@2x.png"))
}
if args.count > 2 { try MainActor.assumeIsolated { png(256) }.write(to: URL(fileURLWithPath: args[2])) }
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", args[1]]
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { exit(1) }
