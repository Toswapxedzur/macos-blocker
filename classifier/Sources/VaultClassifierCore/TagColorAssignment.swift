import Foundation

/// Gives every tag in one tree an equal interval on a shared hue wheel.
/// Sibling creation order defines an in-order traversal: the first half of
/// each parent's children precede the parent, and the rest follow it. Canvas
/// coordinates never affect color. Lightness and chroma are fixed for each
/// theme, so hue is the only tag-dependent color property.
public enum TagColorAssignment {
    public static let currentAlgorithmVersion = 6
    public static let minimumTextContrast = 7.0

    private static let lightLightness = 0.84
    private static let darkLightness = 0.38
    private static let startingHue = 240.0 * Double.pi / 180.0
    private static let fullCircle = 2.0 * Double.pi

    // A single gamut-safe chroma per theme avoids giving some hues more
    // saturation than others. Leave a margin for angles between samples and
    // for the 8-bit RGB colors persisted in the workspace.
    private static let lightChroma = sharedChroma(lightness: lightLightness, ceiling: 0.09)
    private static let darkChroma = sharedChroma(lightness: darkLightness, ceiling: 0.12)

    public static func normalizedHex(_ value: String?) -> String? {
        guard let value, value.count == 7, value.first == "#" else { return nil }
        let digits = value.dropFirst()
        guard digits.unicodeScalars.allSatisfy({ scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) ||
            (scalar.value >= 0x41 && scalar.value <= 0x46) ||
            (scalar.value >= 0x61 && scalar.value <= 0x66)
        }) else {
            return nil
        }
        return "#\(digits.uppercased())"
    }

    public static func isValidHex(_ value: String?) -> Bool {
        normalizedHex(value) != nil
    }

    /// Accept readable persisted colors at the bridge boundary. The catalog
    /// independently replaces old or stale colors with this algorithm's pair.
    public static func isValidThemePair(lightHex: String?, darkHex: String?) -> Bool {
        guard let light = RGB(hex: lightHex), let dark = RGB(hex: darkHex) else {
            return false
        }
        return light.contrastAgainstBlack >= minimumTextContrast
            && dark.contrastAgainstWhite >= minimumTextContrast
    }

    public static func reconcileColors(in tree: inout TagTreeAsset) {
        let orderedIDs = horizontalOrder(in: tree)
        guard !orderedIDs.isEmpty else {
            tree.colorAlgorithmVersion = currentAlgorithmVersion
            return
        }
        let count = Double(orderedIDs.count)
        var pairsByID: [String: (light: RGB, dark: RGB)] = [:]
        for (ordinal, id) in orderedIDs.enumerated() {
            let hue = (startingHue + fullCircle * Double(ordinal) / count)
                .truncatingRemainder(dividingBy: fullCircle)
            pairsByID[id] = colorPair(hue: hue)
        }
        for index in tree.nodes.indices {
            guard let pair = pairsByID[tree.nodes[index].id] else { continue }
            tree.nodes[index].lightColorHex = pair.light.hex
            tree.nodes[index].darkColorHex = pair.dark.hex
        }
        tree.colorAlgorithmVersion = currentAlgorithmVersion
    }

    /// An in-order walk of the authored tree, independent of free canvas
    /// placement. Malformed legacy cycles and orphaned nodes remain safe.
    static func horizontalOrder(in tree: TagTreeAsset) -> [String] {
        let nodes = tree.nodes
        let knownIDs = Set(nodes.map(\.id))
        var childrenByParentID: [String: [Int]] = [:]
        for index in nodes.indices {
            if let parentID = nodes[index].parentID {
                childrenByParentID[parentID, default: []].append(index)
            }
        }

        enum Step { case visit(Int), emit(Int) }
        var visited = Set<Int>()
        var ordered: [String] = []
        let roots = nodes.indices.filter {
            guard let parentID = nodes[$0].parentID else { return true }
            return !knownIDs.contains(parentID)
        }
        for start in roots + Array(nodes.indices) where !visited.contains(start) {
            var pending: [Step] = [.visit(start)]
            while let step = pending.popLast() {
                switch step {
                case .emit(let index):
                    ordered.append(nodes[index].id)
                case .visit(let index):
                    guard visited.insert(index).inserted else { continue }
                    let children = childrenByParentID[nodes[index].id] ?? []
                    let midpoint = children.count / 2
                    for child in children[midpoint...].reversed() {
                        pending.append(.visit(child))
                    }
                    pending.append(.emit(index))
                    for child in children[..<midpoint].reversed() {
                        pending.append(.visit(child))
                    }
                }
            }
        }
        return ordered
    }

    private static func colorPair(hue: Double) -> (light: RGB, dark: RGB) {
        func color(lightness: Double, chroma: Double) -> RGB {
            let lab = OKLab(
                lightness: lightness,
                a: cos(hue) * chroma,
                b: sin(hue) * chroma
            )
            // The globally selected chroma is safely inside the RGB gamut.
            // A neutral fallback keeps a damaged legacy workspace loadable.
            return RGB(oklab: lab) ?? RGB(oklab: OKLab(lightness: lightness, a: 0, b: 0))!
        }
        return (
            light: color(lightness: lightLightness, chroma: lightChroma),
            dark: color(lightness: darkLightness, chroma: darkChroma)
        )
    }

    private static func sharedChroma(lightness: Double, ceiling: Double) -> Double {
        var lower = 0.0
        var upper = ceiling
        for _ in 0..<18 {
            let candidate = (lower + upper) / 2
            let validForEveryHue = (0..<360).allSatisfy { degree in
                let hue = Double(degree) * Double.pi / 180.0
                let lab = OKLab(
                    lightness: lightness,
                    a: cos(hue) * candidate,
                    b: sin(hue) * candidate
                )
                guard let color = RGB(oklab: lab),
                      let persisted = RGB(hex: color.hex) else { return false }
                return lightness == lightLightness
                    ? persisted.contrastAgainstBlack >= minimumTextContrast
                    : persisted.contrastAgainstWhite >= minimumTextContrast
            }
            if validForEveryHue { lower = candidate } else { upper = candidate }
        }
        return lower * 0.9
    }
}

private struct RGB {
    var red: Double
    var green: Double
    var blue: Double

    init?(hex: String?) {
        guard let normalized = TagColorAssignment.normalizedHex(hex),
              let value = Int(normalized.dropFirst(), radix: 16) else {
            return nil
        }
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
    }

    init?(oklab: OKLab) {
        let lRoot = oklab.lightness + (0.3963377774 * oklab.a) + (0.2158037573 * oklab.b)
        let mRoot = oklab.lightness - (0.1055613458 * oklab.a) - (0.0638541728 * oklab.b)
        let sRoot = oklab.lightness - (0.0894841775 * oklab.a) - (1.2914855480 * oklab.b)
        let l = lRoot * lRoot * lRoot
        let m = mRoot * mRoot * mRoot
        let s = sRoot * sRoot * sRoot
        let linearRed = (4.0767416621 * l) - (3.3077115913 * m) + (0.2309699292 * s)
        let linearGreen = (-1.2684380046 * l) + (2.6097574011 * m) - (0.3413193965 * s)
        let linearBlue = (-0.0041960863 * l) - (0.7034186147 * m) + (1.7076147010 * s)

        func encoded(_ component: Double) -> Double {
            component <= 0.0031308
                ? 12.92 * component
                : (1.055 * pow(component, 1 / 2.4)) - 0.055
        }
        let red = encoded(linearRed)
        let green = encoded(linearGreen)
        let blue = encoded(linearBlue)
        let tolerance = 0.000_001
        guard red.isFinite, green.isFinite, blue.isFinite,
              (-tolerance...1 + tolerance).contains(red),
              (-tolerance...1 + tolerance).contains(green),
              (-tolerance...1 + tolerance).contains(blue) else {
            return nil
        }
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    var hex: String {
        let components = [red, green, blue].map { component in
            Int((min(1, max(0, component)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", components[0], components[1], components[2])
    }

    var contrastAgainstWhite: Double {
        1.05 / (relativeLuminance + 0.05)
    }

    var contrastAgainstBlack: Double {
        (relativeLuminance + 0.05) / 0.05
    }

    private var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return (0.2126 * linear(red)) + (0.7152 * linear(green)) + (0.0722 * linear(blue))
    }
}

private struct OKLab {
    var lightness: Double
    var a: Double
    var b: Double

    init(lightness: Double, a: Double, b: Double) {
        self.lightness = lightness
        self.a = a
        self.b = b
    }
}
