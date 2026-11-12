// Genera el icono de Bodega (PNG 1024×1024): swift scripts/make-icon.swift salida.png
// Dibujo propio con trazos vectoriales (sin SF Symbols, cuya licencia no permite usarlos en iconos).
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let size = 1024.0
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Fondo: cuadrado redondeado estilo macOS con degradado burdeos.
let inset = size * 0.09
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let background = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
NSGradient(colors: [
    NSColor(red: 0.62, green: 0.13, blue: 0.27, alpha: 1),
    NSColor(red: 0.29, green: 0.04, blue: 0.13, alpha: 1),
])!.draw(in: background, angle: -90)

// Copa: cáliz, tallo y pie (coordenadas con el origen abajo a la izquierda).
let cx = size / 2
let rimY = 770.0, rimHalf = 175.0, bowlBottom = 470.0
let bowl = NSBezierPath()
bowl.move(to: NSPoint(x: cx - rimHalf, y: rimY))
bowl.line(to: NSPoint(x: cx + rimHalf, y: rimY))
bowl.curve(to: NSPoint(x: cx, y: bowlBottom),
           controlPoint1: NSPoint(x: cx + rimHalf + 10, y: rimY - 200),
           controlPoint2: NSPoint(x: cx + 120, y: bowlBottom))
bowl.curve(to: NSPoint(x: cx - rimHalf, y: rimY),
           controlPoint1: NSPoint(x: cx - 120, y: bowlBottom),
           controlPoint2: NSPoint(x: cx - rimHalf - 10, y: rimY - 200))
bowl.close()

let stem = NSBezierPath(roundedRect: NSRect(x: cx - 18, y: 300, width: 36, height: bowlBottom - 300 + 10), xRadius: 18, yRadius: 18)
let foot = NSBezierPath(ovalIn: NSRect(x: cx - 140, y: 270, width: 280, height: 56))

NSColor.white.withAlphaComponent(0.95).setFill()
bowl.fill()
stem.fill()
foot.fill()

// Vino dentro del cáliz: se recorta con la forma de la copa.
NSGraphicsContext.saveGraphicsState()
bowl.addClip()
NSGradient(colors: [
    NSColor(red: 0.55, green: 0.04, blue: 0.16, alpha: 1),
    NSColor(red: 0.35, green: 0.02, blue: 0.10, alpha: 1),
])!.draw(in: NSRect(x: cx - rimHalf - 20, y: bowlBottom - 10, width: (rimHalf + 20) * 2, height: 175), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Brillo en el lado izquierdo del cáliz.
let shine = NSBezierPath()
shine.move(to: NSPoint(x: cx - 120, y: 735))
shine.curve(to: NSPoint(x: cx - 70, y: 560), controlPoint1: NSPoint(x: cx - 125, y: 650), controlPoint2: NSPoint(x: cx - 105, y: 590))
shine.lineWidth = 14
shine.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.55).setStroke()
shine.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: output))
