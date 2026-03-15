import Cocoa

enum StatusBarIcon {
    static func make(autoSend: Bool, running: Bool) -> NSImage {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()

        let color = NSColor.black

        let bodyW: CGFloat = 11
        let bodyH: CGFloat = 12
        let bodyX: CGFloat = (s - bodyW) / 2
        let bodyY: CGFloat = 1.5

        let bodyPath = NSBezierPath(roundedRect: NSRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH),
                                    xRadius: 1.5, yRadius: 1.5)
        bodyPath.lineWidth = 1.2
        color.set()
        bodyPath.stroke()

        let clipW: CGFloat = 5
        let clipH: CGFloat = 3.5
        let clipX: CGFloat = (s - clipW) / 2
        let clipY: CGFloat = bodyY + bodyH - 1

        let clipPath = NSBezierPath(roundedRect: NSRect(x: clipX, y: clipY, width: clipW, height: clipH),
                                    xRadius: 1.2, yRadius: 1.2)
        clipPath.lineWidth = 1.2
        color.set()
        clipPath.stroke()

        let lineMargin: CGFloat = 2.5
        let lineX1 = bodyX + lineMargin
        let lineX2 = bodyX + bodyW - lineMargin
        color.set()
        for yOff: CGFloat in [4.5, 7, 9.5] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: lineX1, y: yOff))
            line.line(to: NSPoint(x: lineX2, y: yOff))
            line.lineWidth = 1.0
            line.stroke()
        }

        if autoSend {
            let bg = NSColor.white
            let bgCircle = NSBezierPath(ovalIn: NSRect(x: 10.5, y: 0, width: 7.5, height: 7.5))
            bg.set()
            bgCircle.fill()

            let cx: CGFloat = 14.25
            let cy: CGFloat = 3.75
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: cx, y: cy + 2.5))
            arrow.line(to: NSPoint(x: cx - 2, y: cy))
            arrow.move(to: NSPoint(x: cx, y: cy + 2.5))
            arrow.line(to: NSPoint(x: cx + 2, y: cy))
            arrow.move(to: NSPoint(x: cx, y: cy + 2.5))
            arrow.line(to: NSPoint(x: cx, y: cy - 1))
            arrow.lineWidth = 1.3
            color.set()
            arrow.stroke()
        }

        if !running {
            color.set()
            for dx: CGFloat in [0, 2.5] {
                let bar = NSBezierPath(rect: NSRect(x: 11 + dx, y: 0.5, width: 1.5, height: 4))
                bar.fill()
            }
        }

        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}
