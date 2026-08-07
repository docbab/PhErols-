// One-off icon generator: gauge glyph on a squircle, 1024x1024 PNG on stdout path.
import AppKit

let side: CGFloat = 1024
let inset: CGFloat = 100                 // Apple's icon grid leaves margin around the shape
let box = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)

let img = NSImage(size: NSSize(width: side, height: side))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Background squircle with a top-lit gradient.
let path = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
ctx.saveGState()
path.addClip()
let grad = NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
                               NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 1)])!
grad.draw(in: box, angle: -90)
ctx.restoreGState()

// Gauge glyph, tinted by remaining-usage green.
// hierarchicalColor tints the glyph itself; a destinationIn composite would punch a hole
// in the gradient instead.
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .medium)
    .applying(NSImage.SymbolConfiguration(hierarchicalColor:
        NSColor(srgbRed: 0.42, green: 0.88, blue: 0.58, alpha: 1)))
guard let sym = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                        accessibilityDescription: "usage gauge")?
    .withSymbolConfiguration(cfg) else { fatalError("symbol unavailable") }
let r = NSRect(x: (side - sym.size.width) / 2,
               y: (side - sym.size.height) / 2,
               width: sym.size.width, height: sym.size.height)
sym.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
img.unlockFocus()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let tiff = img.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try png.write(to: out)
print("wrote \(out.path)")

// Regenerate AppIcon.icns (only needed if the icon changes):
//   swiftc -o /tmp/mkicon mkicon.swift && /tmp/mkicon /tmp/icon1024.png
//   mkdir -p /tmp/AppIcon.iconset
//   for s in 16 32 128 256 512; do
//     sips -z $s $s /tmp/icon1024.png --out /tmp/AppIcon.iconset/icon_${s}x${s}.png
//     sips -z $((s*2)) $((s*2)) /tmp/icon1024.png --out /tmp/AppIcon.iconset/icon_${s}x${s}@2x.png
//   done
//   iconutil -c icns /tmp/AppIcon.iconset -o AppIcon.icns
