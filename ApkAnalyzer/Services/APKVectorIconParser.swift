import Foundation
import UIKit
import CoreGraphics

// MARK: - Android Path Data Tokenizer & Parser

/// Parses Android/SVG `pathData` strings into drawable path commands.
///
/// Supports all standard SVG path commands used by Android VectorDrawable:
/// M/m (moveTo), L/l (lineTo), H/h (hLineTo), V/v (vLineTo),
/// C/c (cubicBezier), S/s (smoothCubic), Q/q (quadBezier), T/t (smoothQuad),
/// A/a (arc), Z/z (close).
struct AndroidPathDataParser {

    enum Command {
        case moveTo(CGPoint, Bool)              // point, isAbsolute
        case lineTo(CGPoint, Bool)
        case horizontalLineTo(CGFloat, Bool)
        case verticalLineTo(CGFloat, Bool)
        case cubicBezier(CGPoint, CGPoint, CGPoint, Bool)  // cp1, cp2, end
        case smoothCubic(CGPoint, CGPoint, Bool)           // cp2, end
        case quadBezier(CGPoint, CGPoint, Bool)            // cp, end
        case smoothQuad(CGPoint, Bool)                     // end
        case arc(CGFloat, CGFloat, CGFloat, Bool, Bool, CGPoint, Bool) // rx,ry,rotation,large,sweep,end
        case close
    }

    /// Parses a pathData string into an array of path commands.
    static func parse(_ pathData: String) -> [Command] {
        let tokens = tokenize(pathData)
        var commands: [Command] = []
        var i = 0

        while i < tokens.count {
            guard case .letter(let cmd) = tokens[i] else { i += 1; continue }
            let abs = cmd.isUppercase
            let c = cmd.uppercased()
            i += 1

            switch c {
            case "M":
                // M can be followed by multiple coordinate pairs; after the first, treat as lineTo
                var first = true
                while i < tokens.count, case .number(_) = tokens[i] {
                    guard let p = readPoint(tokens, &i) else { break }
                    if first {
                        commands.append(.moveTo(p, abs))
                        first = false
                    } else {
                        commands.append(.lineTo(p, abs))
                    }
                }

            case "L":
                while i < tokens.count, case .number(_) = tokens[i] {
                    guard let p = readPoint(tokens, &i) else { break }
                    commands.append(.lineTo(p, abs))
                }

            case "H":
                while i < tokens.count, case .number(_) = tokens[i] {
                    guard let v = readNumber(tokens, &i) else { break }
                    commands.append(.horizontalLineTo(v, abs))
                }

            case "V":
                while i < tokens.count, case .number(_) = tokens[i] {
                    guard let v = readNumber(tokens, &i) else { break }
                    commands.append(.verticalLineTo(v, abs))
                }

            case "C":
                while i < tokens.count, case .number(_) = tokens[i] {
                    guard let cp1 = readPoint(tokens, &i),
                          let cp2 = readPoint(tokens, &i),
                          let end = readPoint(tokens, &i) else { break }
                    commands.append(.cubicBezier(cp1, cp2, end, abs))
                }

            case "S":
                while i < tokens.count, case .number(_) = tokens[i] {
                    guard let cp2 = readPoint(tokens, &i),
                          let end = readPoint(tokens, &i) else { break }
                    commands.append(.smoothCubic(cp2, end, abs))
                }

            case "Q":
                while i < tokens.count, case .number(_) = tokens[i] {
                    guard let cp = readPoint(tokens, &i),
                          let end = readPoint(tokens, &i) else { break }
                    commands.append(.quadBezier(cp, end, abs))
                }

            case "T":
                while i < tokens.count, case .number(_) = tokens[i] {
                    guard let end = readPoint(tokens, &i) else { break }
                    commands.append(.smoothQuad(end, abs))
                }

            case "A":
                while i < tokens.count, case .number(_) = tokens[i] {
                    guard let rx = readNumber(tokens, &i),
                          let ry = readNumber(tokens, &i),
                          let rot = readNumber(tokens, &i),
                          let lf = readNumber(tokens, &i),
                          let sf = readNumber(tokens, &i),
                          let end = readPoint(tokens, &i) else { break }
                    commands.append(.arc(rx, ry, rot, lf != 0, sf != 0, end, abs))
                }

            case "Z":
                commands.append(.close)

            default:
                break
            }
        }

        return commands
    }

    /// Builds a CGPath from parsed commands.
    static func buildPath(from commands: [Command]) -> CGPath {
        let path = CGMutablePath()
        var current = CGPoint.zero
        var lastControl: CGPoint?
        var subpathStart = CGPoint.zero

        for cmd in commands {
            switch cmd {
            case .moveTo(let p, let abs):
                let pt = abs ? p : CGPoint(x: current.x + p.x, y: current.y + p.y)
                path.move(to: pt)
                current = pt
                subpathStart = pt
                lastControl = nil

            case .lineTo(let p, let abs):
                let pt = abs ? p : CGPoint(x: current.x + p.x, y: current.y + p.y)
                path.addLine(to: pt)
                current = pt
                lastControl = nil

            case .horizontalLineTo(let x, let abs):
                let pt = CGPoint(x: abs ? x : current.x + x, y: current.y)
                path.addLine(to: pt)
                current = pt
                lastControl = nil

            case .verticalLineTo(let y, let abs):
                let pt = CGPoint(x: current.x, y: abs ? y : current.y + y)
                path.addLine(to: pt)
                current = pt
                lastControl = nil

            case .cubicBezier(let cp1, let cp2, let end, let abs):
                let c1 = abs ? cp1 : CGPoint(x: current.x + cp1.x, y: current.y + cp1.y)
                let c2 = abs ? cp2 : CGPoint(x: current.x + cp2.x, y: current.y + cp2.y)
                let e  = abs ? end  : CGPoint(x: current.x + end.x, y: current.y + end.y)
                path.addCurve(to: e, control1: c1, control2: c2)
                lastControl = c2
                current = e

            case .smoothCubic(let cp2, let end, let abs):
                // Reflect last control point
                let c1: CGPoint
                if let lc = lastControl {
                    c1 = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                } else {
                    c1 = current
                }
                let c2 = abs ? cp2 : CGPoint(x: current.x + cp2.x, y: current.y + cp2.y)
                let e  = abs ? end  : CGPoint(x: current.x + end.x, y: current.y + end.y)
                path.addCurve(to: e, control1: c1, control2: c2)
                lastControl = c2
                current = e

            case .quadBezier(let cp, let end, let abs):
                let c = abs ? cp  : CGPoint(x: current.x + cp.x, y: current.y + cp.y)
                let e = abs ? end : CGPoint(x: current.x + end.x, y: current.y + end.y)
                path.addQuadCurve(to: e, control: c)
                lastControl = c
                current = e

            case .smoothQuad(let end, let abs):
                let c: CGPoint
                if let lc = lastControl {
                    c = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                } else {
                    c = current
                }
                let e = abs ? end : CGPoint(x: current.x + end.x, y: current.y + end.y)
                path.addQuadCurve(to: e, control: c)
                lastControl = c
                current = e

            case .arc(let rx, let ry, let rotation, let largeArc, let sweep, let end, let abs):
                let e = abs ? end : CGPoint(x: current.x + end.x, y: current.y + end.y)
                addArc(to: path, from: current, to: e, rx: rx, ry: ry,
                       rotation: rotation * .pi / 180, largeArc: largeArc, sweep: sweep)
                current = e
                lastControl = nil

            case .close:
                path.closeSubpath()
                current = subpathStart
                lastControl = nil
            }
        }

        return path
    }

    // MARK: - Tokenizer

    private enum Token {
        case letter(Character)
        case number(CGFloat)
    }

    /// Tokenizes a pathData string into letters and numbers.
    /// Handles adjacent negatives (e.g., "1.5-2.3" → 1.5, -2.3) and
    /// multiple decimal points (e.g., "1.5.3" → 1.5, 0.3).
    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var chars = Array(input)
        var i = 0

        while i < chars.count {
            let ch = chars[i]

            if ch.isLetter {
                tokens.append(.letter(ch))
                i += 1
            } else if ch == "-" || ch == "+" || ch == "." || ch.isNumber {
                var numStr = ""
                var hasDot = false

                if ch == "-" || ch == "+" {
                    numStr.append(ch)
                    i += 1
                }

                while i < chars.count {
                    let c = chars[i]
                    if c == "." {
                        if hasDot {
                            // Second dot starts a new number (e.g., "1.5.3")
                            break
                        }
                        hasDot = true
                        numStr.append(c)
                        i += 1
                    } else if c.isNumber {
                        numStr.append(c)
                        i += 1
                    } else {
                        break
                    }
                }

                if let val = Double(numStr) {
                    tokens.append(.number(CGFloat(val)))
                }
            } else {
                // Skip whitespace, commas
                i += 1
            }
        }

        return tokens
    }

    private static func readNumber(_ tokens: [Token], _ i: inout Int) -> CGFloat? {
        guard i < tokens.count, case .number(let v) = tokens[i] else { return nil }
        i += 1
        return v
    }

    private static func readPoint(_ tokens: [Token], _ i: inout Int) -> CGPoint? {
        guard let x = readNumber(tokens, &i), let y = readNumber(tokens, &i) else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: - SVG Arc to Core Graphics

    /// Converts SVG arc parameters to Core Graphics curve approximations.
    private static func addArc(to path: CGMutablePath, from p1: CGPoint, to p2: CGPoint,
                               rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        guard rx > 0, ry > 0 else {
            path.addLine(to: p2)
            return
        }

        if p1.x == p2.x && p1.y == p2.y { return }

        var rx = abs(rx), ry = abs(ry)
        let cosAngle = cos(rotation), sinAngle = sin(rotation)

        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1p = cosAngle * dx + sinAngle * dy
        let y1p = -sinAngle * dx + cosAngle * dy

        // Scale radii if too small
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let sqrtLambda = sqrt(lambda)
            rx *= sqrtLambda
            ry *= sqrtLambda
        }

        let rxSq = rx * rx, rySq = ry * ry
        let x1pSq = x1p * x1p, y1pSq = y1p * y1p

        var sq = max(0, (rxSq * rySq - rxSq * y1pSq - rySq * x1pSq) / (rxSq * y1pSq + rySq * x1pSq))
        sq = sqrt(sq) * (largeArc == sweep ? -1 : 1)

        let cxp = sq * rx * y1p / ry
        let cyp = -sq * ry * x1p / rx

        let cx = cosAngle * cxp - sinAngle * cyp + (p1.x + p2.x) / 2
        let cy = sinAngle * cxp + cosAngle * cyp + (p1.y + p2.y) / 2

        let theta1 = angleBetween(ux: 1, uy: 0, vx: (x1p - cxp) / rx, vy: (y1p - cyp) / ry)
        var dTheta = angleBetween(
            ux: (x1p - cxp) / rx, uy: (y1p - cyp) / ry,
            vx: (-x1p - cxp) / rx, vy: (-y1p - cyp) / ry
        )

        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        else if sweep && dTheta < 0 { dTheta += 2 * .pi }

        // Approximate the arc with cubic bezier segments
        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let segAngle = dTheta / CGFloat(segments)

        for s in 0..<segments {
            let t1 = theta1 + CGFloat(s) * segAngle
            let t2 = t1 + segAngle
            addArcSegment(to: path, cx: cx, cy: cy, rx: rx, ry: ry,
                          rotation: rotation, t1: t1, t2: t2)
        }
    }

    private static func addArcSegment(to path: CGMutablePath, cx: CGFloat, cy: CGFloat,
                                      rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                                      t1: CGFloat, t2: CGFloat) {
        let alpha = sin(t2 - t1) * (sqrt(4 + 3 * pow(tan((t2 - t1) / 2), 2)) - 1) / 3
        let cosR = cos(rotation), sinR = sin(rotation)

        func ellipsePoint(_ t: CGFloat) -> CGPoint {
            let x = rx * cos(t), y = ry * sin(t)
            return CGPoint(x: cosR * x - sinR * y + cx, y: sinR * x + cosR * y + cy)
        }
        func ellipseDeriv(_ t: CGFloat) -> CGPoint {
            let x = -rx * sin(t), y = ry * cos(t)
            return CGPoint(x: cosR * x - sinR * y, y: sinR * x + cosR * y)
        }

        let ep1 = ellipsePoint(t1), ep2 = ellipsePoint(t2)
        let d1 = ellipseDeriv(t1), d2 = ellipseDeriv(t2)

        let cp1 = CGPoint(x: ep1.x + alpha * d1.x, y: ep1.y + alpha * d1.y)
        let cp2 = CGPoint(x: ep2.x - alpha * d2.x, y: ep2.y - alpha * d2.y)

        path.addCurve(to: ep2, control1: cp1, control2: cp2)
    }

    private static func angleBetween(ux: CGFloat, uy: CGFloat, vx: CGFloat, vy: CGFloat) -> CGFloat {
        let dot = ux * vx + uy * vy
        let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
        var angle = acos(max(-1, min(1, dot / len)))
        if ux * vy - uy * vx < 0 { angle = -angle }
        return angle
    }
}

// MARK: - Vector Drawable Model

/// Represents a parsed Android VectorDrawable.
struct VectorDrawable {
    var viewportWidth: CGFloat = 24
    var viewportHeight: CGFloat = 24
    var width: CGFloat = 24
    var height: CGFloat = 24
    var elements: [Element] = []

    enum Element {
        case path(VectorPath)
        case group(VectorGroup)
    }

    struct VectorPath {
        var pathData: String = ""
        var fillColor: UIColor?
        var strokeColor: UIColor?
        var strokeWidth: CGFloat = 0
        var fillAlpha: CGFloat = 1
        var strokeAlpha: CGFloat = 1
        var fillType: CGPathFillRule = .winding
    }

    struct VectorGroup {
        var translateX: CGFloat = 0
        var translateY: CGFloat = 0
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotation: CGFloat = 0
        var pivotX: CGFloat = 0
        var pivotY: CGFloat = 0
        var elements: [Element] = []
    }
}

// MARK: - aapt2 xmltree Output Parser

/// Parses `aapt2 dump xmltree` output into structured models.
struct XmlTreeParser {

    /// Parsed XML element from aapt2 xmltree output.
    struct XmlNode {
        let tag: String
        let depth: Int
        var attributes: [String: String] = [:]
        var children: [XmlNode] = []
    }

    /// Parses aapt2 xmltree output into a tree of nodes.
    static func parse(_ output: String) -> XmlNode? {
        let lines = output.components(separatedBy: "\n")
        var nodes: [(node: XmlNode, depth: Int)] = []

        for line in lines {
            // Match element lines: "    E: tagname (line=N)"
            if let (depth, tag) = parseElementLine(line) {
                let node = XmlNode(tag: tag, depth: depth)
                nodes.append((node, depth))
            }
            // Match attribute lines: "      A: namespace:name=value" or "      A: namespace:name(0xHEX)=value"
            else if let (depth, key, value) = parseAttributeLine(line), !nodes.isEmpty {
                // Find the most recent node at depth - 1 (the parent element of this attribute)
                for idx in stride(from: nodes.count - 1, through: 0, by: -1) {
                    // Attributes are indented deeper than their element
                    if nodes[idx].depth < depth {
                        nodes[idx].node.attributes[key] = value
                        break
                    }
                }
            }
        }

        // Build tree from flat list
        guard !nodes.isEmpty else { return nil }

        var stack: [(node: XmlNode, depth: Int)] = []

        for (node, depth) in nodes {
            // Pop nodes from the stack that are at the same or deeper depth
            while let last = stack.last, last.depth >= depth {
                let child = stack.removeLast()
                if let parentIdx = stack.indices.last {
                    stack[parentIdx].node.children.append(child.node)
                }
            }
            stack.append((node, depth))
        }

        // Unwind remaining stack
        while stack.count > 1 {
            let child = stack.removeLast()
            if let parentIdx = stack.indices.last {
                stack[parentIdx].node.children.append(child.node)
            }
        }

        return stack.first?.node
    }

    private static func parseElementLine(_ line: String) -> (Int, String)? {
        // Match: "  E: tagname (line=N)" with leading whitespace indicating depth
        let pattern = "^(\\s*)E:\\s+(\\S+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 3 else { return nil }

        let indent = (line as NSString).substring(with: match.range(at: 1))
        let tag = (line as NSString).substring(with: match.range(at: 2))
        let depth = indent.count / 2  // aapt2 uses 2-space indentation
        return (depth, tag)
    }

    private static func parseAttributeLine(_ line: String) -> (Int, String, String)? {
        // Match: "      A: android:name(0xHEX)=value" or "      A: android:name=value"
        // Also handles: "      A: http://...android:name(0xHEX)=(type 0x...)value"
        let pattern = "^(\\s*)A:\\s+(?:http://[^:]+:)?(?:android:)?(\\w+)(?:\\([^)]*\\))?=(?:\\(type [^)]*\\))?(.*)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 4 else { return nil }

        let indent = (line as NSString).substring(with: match.range(at: 1))
        let key = (line as NSString).substring(with: match.range(at: 2))
        var value = (line as NSString).substring(with: match.range(at: 3))

        // Clean up value — remove dimension suffixes for dimension values
        value = value.trimmingCharacters(in: .whitespaces)

        let depth = indent.count / 2
        return (depth, key, value)
    }

    /// Parses a VectorDrawable from an aapt2 xmltree root node.
    static func parseVectorDrawable(from root: XmlNode) -> VectorDrawable? {
        guard root.tag == "vector" else { return nil }

        var vd = VectorDrawable()
        vd.viewportWidth = parseDimension(root.attributes["viewportWidth"]) ?? 24
        vd.viewportHeight = parseDimension(root.attributes["viewportHeight"]) ?? 24
        vd.width = parseDimension(root.attributes["width"]) ?? vd.viewportWidth
        vd.height = parseDimension(root.attributes["height"]) ?? vd.viewportHeight
        vd.elements = parseElements(root.children)

        return vd
    }

    private static func parseElements(_ nodes: [XmlNode]) -> [VectorDrawable.Element] {
        var elements: [VectorDrawable.Element] = []

        for node in nodes {
            switch node.tag {
            case "path":
                var vp = VectorDrawable.VectorPath()
                vp.pathData = node.attributes["pathData"] ?? ""
                vp.fillColor = parseColor(node.attributes["fillColor"])
                vp.strokeColor = parseColor(node.attributes["strokeColor"])
                vp.strokeWidth = parseDimension(node.attributes["strokeWidth"]) ?? 0
                vp.fillAlpha = parseDimension(node.attributes["fillAlpha"]) ?? 1
                vp.strokeAlpha = parseDimension(node.attributes["strokeAlpha"]) ?? 1
                if node.attributes["fillType"] == "evenOdd" {
                    vp.fillType = .evenOdd
                }
                elements.append(.path(vp))

            case "group":
                var vg = VectorDrawable.VectorGroup()
                vg.translateX = parseDimension(node.attributes["translateX"]) ?? 0
                vg.translateY = parseDimension(node.attributes["translateY"]) ?? 0
                vg.scaleX = parseDimension(node.attributes["scaleX"]) ?? 1
                vg.scaleY = parseDimension(node.attributes["scaleY"]) ?? 1
                vg.rotation = parseDimension(node.attributes["rotation"]) ?? 0
                vg.pivotX = parseDimension(node.attributes["pivotX"]) ?? 0
                vg.pivotY = parseDimension(node.attributes["pivotY"]) ?? 0
                vg.elements = parseElements(node.children)
                elements.append(.group(vg))

            case "clip-path":
                // Treat clip-path data as a path with no fill (clip masks)
                // For simplicity in POC, skip clip paths
                break

            default:
                break
            }
        }

        return elements
    }

    /// Parses a dimension string like "24.0dp", "24.0dip", "108.0", etc.
    static func parseDimension(_ value: String?) -> CGFloat? {
        guard var str = value?.trimmingCharacters(in: .whitespaces), !str.isEmpty else { return nil }
        // Remove dp/dip/sp/px suffixes
        for suffix in ["dip", "dp", "sp", "px"] {
            if str.hasSuffix(suffix) {
                str = String(str.dropLast(suffix.count))
                break
            }
        }
        return Double(str).map { CGFloat($0) }
    }

    /// Parses Android color values: "#AARRGGBB", "#RRGGBB", "#ARGB", "#RGB", or resource references.
    static func parseColor(_ value: String?) -> UIColor? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), value.hasPrefix("#") else { return nil }
        let hex = String(value.dropFirst())

        var rgba: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&rgba) else { return nil }

        let r, g, b, a: CGFloat
        switch hex.count {
        case 8: // AARRGGBB
            a = CGFloat((rgba >> 24) & 0xFF) / 255
            r = CGFloat((rgba >> 16) & 0xFF) / 255
            g = CGFloat((rgba >> 8) & 0xFF) / 255
            b = CGFloat(rgba & 0xFF) / 255
        case 6: // RRGGBB
            a = 1
            r = CGFloat((rgba >> 16) & 0xFF) / 255
            g = CGFloat((rgba >> 8) & 0xFF) / 255
            b = CGFloat(rgba & 0xFF) / 255
        case 4: // ARGB
            a = CGFloat((rgba >> 12) & 0xF) / 15
            r = CGFloat((rgba >> 8) & 0xF) / 15
            g = CGFloat((rgba >> 4) & 0xF) / 15
            b = CGFloat(rgba & 0xF) / 15
        case 3: // RGB
            a = 1
            r = CGFloat((rgba >> 8) & 0xF) / 15
            g = CGFloat((rgba >> 4) & 0xF) / 15
            b = CGFloat(rgba & 0xF) / 15
        default:
            return nil
        }

        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Vector Drawable Renderer

/// Renders a `VectorDrawable` to a `UIImage` using Core Graphics.
struct VectorDrawableRenderer {

    /// Renders a VectorDrawable at the specified output size.
    static func render(_ drawable: VectorDrawable, size: CGSize? = nil) -> UIImage? {
        let outputSize = size ?? CGSize(width: drawable.width, height: drawable.height)
        guard outputSize.width > 0, outputSize.height > 0 else { return nil }

        // Use a reasonable minimum render size for quality
        let renderSize = CGSize(
            width: max(outputSize.width, 192),
            height: max(outputSize.height, 192)
        )

        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext

            // Scale from viewport coordinates to output coordinates
            let scaleX = renderSize.width / drawable.viewportWidth
            let scaleY = renderSize.height / drawable.viewportHeight
            cgCtx.scaleBy(x: scaleX, y: scaleY)

            renderElements(drawable.elements, in: cgCtx)
        }

        return image
    }

    private static func renderElements(_ elements: [VectorDrawable.Element], in ctx: CGContext) {
        for element in elements {
            switch element {
            case .path(let vPath):
                renderPath(vPath, in: ctx)
            case .group(let vGroup):
                renderGroup(vGroup, in: ctx)
            }
        }
    }

    private static func renderPath(_ vPath: VectorDrawable.VectorPath, in ctx: CGContext) {
        guard !vPath.pathData.isEmpty else { return }

        let commands = AndroidPathDataParser.parse(vPath.pathData)
        let cgPath = AndroidPathDataParser.buildPath(from: commands)

        ctx.saveGState()

        // Fill
        if let fillColor = vPath.fillColor {
            ctx.setFillColor(fillColor.withAlphaComponent(vPath.fillAlpha).cgColor)
            ctx.addPath(cgPath)
            ctx.fillPath(using: vPath.fillType)
        }

        // Stroke
        if let strokeColor = vPath.strokeColor, vPath.strokeWidth > 0 {
            ctx.setStrokeColor(strokeColor.withAlphaComponent(vPath.strokeAlpha).cgColor)
            ctx.setLineWidth(vPath.strokeWidth)
            ctx.addPath(cgPath)
            ctx.strokePath()
        }

        // If no fill and no stroke, fill with black (Android default)
        if vPath.fillColor == nil && (vPath.strokeColor == nil || vPath.strokeWidth <= 0) {
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.addPath(cgPath)
            ctx.fillPath(using: vPath.fillType)
        }

        ctx.restoreGState()
    }

    private static func renderGroup(_ vGroup: VectorDrawable.VectorGroup, in ctx: CGContext) {
        ctx.saveGState()

        // Apply group transforms (order: translate to pivot → rotate → scale → translate back + offset)
        ctx.translateBy(x: vGroup.pivotX + vGroup.translateX, y: vGroup.pivotY + vGroup.translateY)
        ctx.rotate(by: vGroup.rotation * .pi / 180)
        ctx.scaleBy(x: vGroup.scaleX, y: vGroup.scaleY)
        ctx.translateBy(x: -vGroup.pivotX, y: -vGroup.pivotY)

        renderElements(vGroup.elements, in: ctx)

        ctx.restoreGState()
    }
}

// MARK: - APK Vector Icon Parser (Main Class)

/// High-level parser that handles Android vector drawables and adaptive icons within APK files.
///
/// Uses `aapt2 dump xmltree` to read binary XML, then renders vector paths using Core Graphics.
/// For adaptive icons, resolves foreground/background layers and composites them.
final class APKVectorIconParser {

    private let aapt2Path: String
    /// Cache for resource dump to avoid calling aapt2 dump resources multiple times.
    private var resourceDumpCache: [String: String?] = [:]

    init(aapt2Path: String) {
        self.aapt2Path = aapt2Path
    }

    // MARK: - Public API

    /// Attempts to parse and render an XML icon from the APK.
    ///
    /// Handles both:
    /// - `<adaptive-icon>` XML (resolves foreground/background layers)
    /// - `<vector>` XML (renders directly via Core Graphics)
    ///
    /// - Parameters:
    ///   - apkPath: Path to the APK file.
    ///   - iconXmlPath: Relative path to the icon XML inside the APK (e.g., "res/mipmap-anydpi-v26/ic_launcher.xml").
    ///   - outputSize: Desired output image size (default 192x192).
    /// - Returns: Rendered UIImage or nil.
    func renderIcon(from apkPath: URL, iconXmlPath: String, outputSize: CGSize = CGSize(width: 192, height: 192)) -> UIImage? {
        // Dump the XML tree
        guard let xmlOutput = dumpXmlTree(apkPath: apkPath, filePath: iconXmlPath),
              let root = XmlTreeParser.parse(xmlOutput) else {
            return nil
        }

        switch root.tag {
        case "adaptive-icon":
            return renderAdaptiveIcon(root, apkPath: apkPath, outputSize: outputSize)
        case "vector":
            return renderVector(root, outputSize: outputSize)
        default:
            return nil
        }
    }

    /// Resolves all icon resources from an APK, including adaptive and vector types.
    /// Returns a list of (path, image) pairs for all renderable icons found in the resource table.
    func resolveAllIcons(from apkPath: URL) -> [(path: String, image: UIImage)] {
        guard let resourceDump = dumpResources(apkPath: apkPath) else { return [] }

        var icons: [(path: String, image: UIImage)] = []
        let pattern = "resource\\s+0x[0-9a-f]+\\s+(?:mipmap|drawable)/(ic_launcher[^\\s]*)\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return icons }

        let nsOutput = resourceDump as NSString
        let matches = regex.matches(in: resourceDump, range: NSRange(location: 0, length: nsOutput.length))

        var seen = Set<String>()
        // Also look for actual file paths in the resource dump
        let filePattern = "\\(.*?\\)\\s+(res/[^\\s]+\\.xml)"
        guard let fileRegex = try? NSRegularExpression(pattern: filePattern) else { return icons }

        let fileMatches = fileRegex.matches(in: resourceDump, range: NSRange(location: 0, length: nsOutput.length))
        for match in fileMatches {
            let filePath = nsOutput.substring(with: match.range(at: 1))
            guard filePath.contains("ic_launcher"), !seen.contains(filePath) else { continue }
            seen.insert(filePath)

            if let image = renderIcon(from: apkPath, iconXmlPath: filePath) {
                icons.append((filePath, image))
            }
        }

        return icons
    }

    // MARK: - Adaptive Icon Rendering

    private func renderAdaptiveIcon(_ root: XmlTreeParser.XmlNode, apkPath: URL, outputSize: CGSize) -> UIImage? {
        var backgroundImage: UIImage?
        var foregroundImage: UIImage?

        for child in root.children {
            switch child.tag {
            case "background":
                backgroundImage = resolveLayer(child, apkPath: apkPath, outputSize: outputSize)
            case "foreground":
                foregroundImage = resolveLayer(child, apkPath: apkPath, outputSize: outputSize)
            default:
                break
            }
        }

        return compositeAdaptiveIcon(background: backgroundImage, foreground: foregroundImage, size: outputSize)
    }

    /// Resolves a single adaptive icon layer (background or foreground).
    private func resolveLayer(_ node: XmlTreeParser.XmlNode, apkPath: URL, outputSize: CGSize) -> UIImage? {
        // Check for inline color
        if let colorStr = node.attributes["drawable"], colorStr.hasPrefix("#") {
            if let color = XmlTreeParser.parseColor(colorStr) {
                return solidColorImage(color: color, size: outputSize)
            }
        }

        // Check for resource reference (e.g., "@0x7f060001" or a file path)
        if let drawableRef = node.attributes["drawable"] {
            if let image = resolveDrawableReference(drawableRef, apkPath: apkPath, outputSize: outputSize) {
                return image
            }
        }

        // Check for nested vector or other elements
        for child in node.children {
            if child.tag == "vector" {
                return renderVector(child, outputSize: outputSize)
            } else if child.tag == "color" || child.tag == "drawable" {
                if let colorStr = child.attributes["color"] ?? child.attributes["drawable"],
                   let color = XmlTreeParser.parseColor(colorStr) {
                    return solidColorImage(color: color, size: outputSize)
                }
            }
        }

        return nil
    }

    /// Resolves a resource ID (like "@0x7f060001") by looking up the resource table.
    private func resolveResourceId(_ ref: String, apkPath: URL, outputSize: CGSize) -> UIImage? {
        let cleanRef = ref.replacingOccurrences(of: "@", with: "")
        guard let resourceDump = dumpResources(apkPath: apkPath) else { return nil }

        // Find the resource entry and its file path
        // Look for the resource ID, then find associated file paths
        let lines = resourceDump.components(separatedBy: "\n")
        var foundResource = false
        var candidatePaths: [String] = []

        for line in lines {
            if line.contains(cleanRef) {
                foundResource = true
                continue
            }
            if foundResource {
                // Resource entries list configurations and file paths
                if line.contains("resource ") { break }  // Next resource
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Extract file path from lines like "(v26) res/drawable-v24/ic_launcher_foreground.xml"
                let parts = trimmed.components(separatedBy: " ")
                if let path = parts.last, path.hasPrefix("res/") {
                    candidatePaths.append(path)
                }
            }
        }

        // Try XML vector drawables first, then raster images
        for path in candidatePaths {
            if path.hasSuffix(".xml") {
                if let image = renderIcon(from: apkPath, iconXmlPath: path) {
                    return image
                }
            }
        }

        // Try raster images via unzip
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApkAnalyzer_res_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        for path in candidatePaths where !path.hasSuffix(".xml") {
            _ = try? ShellExecutor.shared.run(
                "/usr/bin/unzip", arguments: ["-o", apkPath.path, path, "-d", tempDir.path]
            )
            let file = tempDir.appendingPathComponent(path)
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                return image
            }
        }

        return nil
    }

    /// Resolves a drawable reference that might be a file path or resource ID.
    private func resolveDrawableReference(_ ref: String, apkPath: URL, outputSize: CGSize) -> UIImage? {
        // If it's a resource ID reference
        if ref.hasPrefix("@") {
            return resolveResourceId(ref, apkPath: apkPath, outputSize: outputSize)
        }

        // If it's a direct file path
        if ref.hasPrefix("res/") {
            if ref.hasSuffix(".xml") {
                return renderIcon(from: apkPath, iconXmlPath: ref)
            }
            // Try as raster image
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ApkAnalyzer_res_\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            _ = try? ShellExecutor.shared.run(
                "/usr/bin/unzip", arguments: ["-o", apkPath.path, ref, "-d", tempDir.path]
            )
            let file = tempDir.appendingPathComponent(ref)
            if let data = try? Data(contentsOf: file) {
                return UIImage(data: data)
            }
        }

        return nil
    }

    // MARK: - Vector Rendering

    private func renderVector(_ root: XmlTreeParser.XmlNode, outputSize: CGSize) -> UIImage? {
        guard let drawable = XmlTreeParser.parseVectorDrawable(from: root) else { return nil }
        return VectorDrawableRenderer.render(drawable, size: outputSize)
    }

    // MARK: - Compositing

    /// Composites adaptive icon layers with Android's standard squircle mask.
    private func compositeAdaptiveIcon(background: UIImage?, foreground: UIImage?, size: CGSize) -> UIImage? {
        guard background != nil || foreground != nil else { return nil }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let cgCtx = ctx.cgContext

            // Clip to squircle (Android adaptive icon shape)
            let mask = adaptiveIconMask(in: rect)
            cgCtx.addPath(mask)
            cgCtx.clip()

            // Draw background
            if let bg = background {
                bg.draw(in: rect)
            }

            // Draw foreground
            if let fg = foreground {
                fg.draw(in: rect)
            }
        }
    }

    /// Creates the standard Android adaptive icon squircle mask path.
    /// Android uses a "squircle" (superellipse) shape for adaptive icons.
    private func adaptiveIconMask(in rect: CGRect) -> CGPath {
        let w = rect.width, h = rect.height
        let cx = rect.midX, cy = rect.midY

        // Approximate Android's squircle using a continuous curvature shape
        // Android uses |x|^n + |y|^n = r^n with n ≈ 4 (superellipse)
        let path = CGMutablePath()
        let r = min(w, h) / 2
        let n: CGFloat = 4.0  // Superellipse exponent
        let steps = 360

        for i in 0...steps {
            let angle = CGFloat(i) * (2 * .pi / CGFloat(steps))
            let cosA = cos(angle), sinA = sin(angle)

            // Superellipse: x = r * sign(cos) * |cos|^(2/n), y = r * sign(sin) * |sin|^(2/n)
            let exp = 2.0 / n
            let x = cx + r * copysign(pow(abs(cosA), exp), cosA)
            let y = cy + r * copysign(pow(abs(sinA), exp), sinA)

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        path.closeSubpath()
        return path
    }

    // MARK: - Helpers

    private func solidColorImage(color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func dumpXmlTree(apkPath: URL, filePath: String) -> String? {
        let result = try? ShellExecutor.shared.run(
            aapt2Path, arguments: ["dump", "xmltree", apkPath.path, "--file", filePath]
        )
        guard let output = result?.output, !output.isEmpty else { return nil }
        return output
    }

    private func dumpResources(apkPath: URL) -> String? {
        let key = apkPath.path
        if let cached = resourceDumpCache[key] {
            return cached
        }
        let result = try? ShellExecutor.shared.run(
            aapt2Path, arguments: ["dump", "resources", apkPath.path],
            timeout: 3
        )
        let output = result?.output.isEmpty == false ? result?.output : nil
        resourceDumpCache[key] = output
        return output
    }
}
