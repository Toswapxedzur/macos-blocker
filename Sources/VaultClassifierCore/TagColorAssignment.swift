import Foundation

/// Assigns persistent, presentation-only colors from tag-tree structure.
///
/// There is no hash or preset palette. Root colors come from continuous
/// low-discrepancy HSL candidates. Every descendant is selected inside a
/// bounded OKLab neighborhood around its parent, and that neighborhood
/// contracts geometrically at each generation. Siblings are spread as far
/// apart as their shared neighborhood allows, while hierarchy similarity is
/// always the stronger constraint.
public enum TagColorAssignment {
    public static let currentAlgorithmVersion = 2
    public static let minimumWhiteTextContrast = 4.5

    static let firstGenerationMaximumOffset = 0.080
    static let generationContraction = 0.45

    private static let goldenRatioConjugate = 0.618_033_988_749_894_9
    private static let silverRatioConjugate = 0.414_213_562_373_095_0
    private static let rootThreeConjugate = 0.732_050_807_568_877_2
    private static let candidateCount = 192
    private static let renderedColorTolerance = 0.003

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

    /// Reconciles legacy or prior-algorithm trees exactly once, then preserves
    /// their assigned colors during ordinary saves.
    public static func reconcileColors(in tree: inout TagTreeAsset) {
        if tree.colorAlgorithmVersion < currentAlgorithmVersion {
            for index in tree.nodes.indices {
                tree.nodes[index].colorHex = nil
            }
            tree.colorAlgorithmVersion = currentAlgorithmVersion
        }
        assignMissingColors(in: &tree)
    }

    /// Clears one moved branch so its root and descendants can inherit the new
    /// parent's progressively smaller color neighborhood.
    public static func invalidateSubtree(rootID: String, in tree: inout TagTreeAsset) {
        let nodeIDs = tree.subtreeNodeIDs(rootID: rootID)
        for index in tree.nodes.indices where nodeIDs.contains(tree.nodes[index].id) {
            tree.nodes[index].colorHex = nil
        }
    }

    /// Assigns only missing or invalid colors. Existing valid colors are
    /// stable when a sibling is added, a tag is renamed, or its canvas moves.
    public static func assignMissingColors(in tree: inout TagTreeAsset) {
        guard !tree.nodes.isEmpty else { return }

        let invalidColorRootIDs = tree.nodes.compactMap { node in
            isValidHex(node.colorHex) ? nil : node.id
        }
        var childIDsByParentID: [String: [String]] = [:]
        for node in tree.nodes {
            if let parentID = node.parentID {
                childIDsByParentID[parentID, default: []].append(node.id)
            }
        }
        var invalidColorNodeIDs = Set<String>()
        var pendingInvalidIDs = invalidColorRootIDs
        while let nodeID = pendingInvalidIDs.popLast(), invalidColorNodeIDs.insert(nodeID).inserted {
            pendingInvalidIDs.append(contentsOf: childIDsByParentID[nodeID] ?? [])
        }
        for index in tree.nodes.indices where invalidColorNodeIDs.contains(tree.nodes[index].id) {
            tree.nodes[index].colorHex = nil
        }

        var usedColors: [RGB] = []
        for index in tree.nodes.indices {
            guard let normalized = normalizedHex(tree.nodes[index].colorHex),
                  let rgb = RGB(hex: normalized) else {
                tree.nodes[index].colorHex = nil
                continue
            }
            tree.nodes[index].colorHex = normalized
            usedColors.append(rgb)
        }

        var unresolved = Set(tree.nodes.indices.filter { tree.nodes[$0].colorHex == nil })
        while !unresolved.isEmpty {
            var assignedAny = false
            for index in unresolved.sorted() {
                let parentIndex = tree.nodes[index].parentID.flatMap { parentID in
                    tree.nodes.firstIndex(where: { $0.id == parentID })
                }
                if let parentIndex, tree.nodes[parentIndex].colorHex == nil {
                    continue
                }

                let parentRGB = parentIndex.flatMap { RGB(hex: tree.nodes[$0].colorHex) }
                let siblingColors = tree.nodes.indices.compactMap { siblingIndex -> RGB? in
                    guard siblingIndex != index,
                          tree.nodes[siblingIndex].parentID == tree.nodes[index].parentID else {
                        return nil
                    }
                    return RGB(hex: tree.nodes[siblingIndex].colorHex)
                }
                let edgeDepth = tree.depth(ofNodeAt: index)
                let siblingOrdinal = tree.nodes[..<index].filter {
                    $0.parentID == tree.nodes[index].parentID
                }.count
                let rgb = generatedColor(
                    parent: parentRGB,
                    edgeDepth: edgeDepth,
                    ordinal: siblingOrdinal,
                    siblingColors: siblingColors,
                    usedColors: usedColors
                )
                tree.nodes[index].colorHex = rgb.hex
                usedColors.append(rgb)
                unresolved.remove(index)
                assignedAny = true
            }

            if !assignedAny, let index = unresolved.min() {
                // Invalid cyclic legacy trees still get a readable color;
                // semantic tree validation remains authoritative elsewhere.
                let rgb = generatedRootColor(ordinal: index, usedColors: usedColors)
                tree.nodes[index].colorHex = rgb.hex
                usedColors.append(rgb)
                unresolved.remove(index)
            }
        }
    }

    static func maximumOffset(edgeDepth: Int) -> Double {
        guard edgeDepth > 0 else { return .greatestFiniteMagnitude }
        return firstGenerationMaximumOffset
            * pow(generationContraction, Double(edgeDepth - 1))
    }

    static func perceptualDistance(_ lhs: String?, _ rhs: String?) -> Double? {
        guard let lhsRGB = RGB(hex: lhs), let rhsRGB = RGB(hex: rhs) else { return nil }
        return OKLab(rgb: lhsRGB).distance(to: OKLab(rgb: rhsRGB))
    }

    private static func generatedColor(
        parent: RGB?,
        edgeDepth: Int,
        ordinal: Int,
        siblingColors: [RGB],
        usedColors: [RGB]
    ) -> RGB {
        guard let parent else {
            return generatedRootColor(ordinal: ordinal, usedColors: usedColors)
        }
        return generatedDescendantColor(
            parent: parent,
            edgeDepth: max(1, edgeDepth),
            ordinal: ordinal,
            siblingColors: siblingColors,
            usedColors: usedColors
        )
    }

    private static func generatedRootColor(ordinal: Int, usedColors: [RGB]) -> RGB {
        var best: (rgb: RGB, distance: Double)?
        for candidateIndex in 0..<candidateCount {
            let sequenceIndex = Double(candidateIndex + 1 + ordinal * candidateCount)
            let hue = fractional(sequenceIndex * goldenRatioConjugate) * 360
            let saturation = 58 + fractional(sequenceIndex * silverRatioConjugate) * 24
            var lightness = 27 + fractional(sequenceIndex * rootThreeConjugate) * 15
            var rgb = RGB(hsl: .init(hue: hue, saturation: saturation, lightness: lightness))
            while rgb.contrastAgainstWhite < minimumWhiteTextContrast, lightness > 18 {
                lightness -= 0.5
                rgb = RGB(hsl: .init(hue: hue, saturation: saturation, lightness: lightness))
            }

            let candidate = OKLab(rgb: rgb)
            let minimumDistance = usedColors
                .map { candidate.distance(to: OKLab(rgb: $0)) }
                .min() ?? .greatestFiniteMagnitude
            if best == nil || minimumDistance > best!.distance {
                best = (rgb, minimumDistance)
            }
        }
        return best!.rgb
    }

    private static func generatedDescendantColor(
        parent: RGB,
        edgeDepth: Int,
        ordinal: Int,
        siblingColors: [RGB],
        usedColors: [RGB]
    ) -> RGB {
        let parentLab = OKLab(rgb: parent)
        let siblingLabs = siblingColors.map(OKLab.init)
        let usedLabs = usedColors.map(OKLab.init)
        let usedHexes = Set(usedColors.map(\.hex))
        let radius = maximumOffset(edgeDepth: edgeDepth)
        var best: (rgb: RGB, score: Double)?
        var readableFallback: (rgb: RGB, score: Double)?

        for candidateIndex in 0..<candidateCount {
            let sequenceIndex = Double(candidateIndex + 1 + ordinal * candidateCount)
            let angle = fractional(sequenceIndex * goldenRatioConjugate) * 2 * Double.pi
            let radialFraction = 0.72 + fractional(sequenceIndex * silverRatioConjugate) * 0.18
            let deltaLightness = (
                (fractional(sequenceIndex * rootThreeConjugate) * 2) - 1
            ) * radius * 0.18
            let maximumPlaneRadius = sqrt(max(0, (radius * radius) - (deltaLightness * deltaLightness)))
            let planeRadius = maximumPlaneRadius * radialFraction
            let candidateLab = OKLab(
                lightness: parentLab.lightness + deltaLightness,
                a: parentLab.a + cos(angle) * planeRadius,
                b: parentLab.b + sin(angle) * planeRadius
            )
            guard let rawRGB = RGB(oklab: candidateLab),
                  rawRGB.contrastAgainstWhite >= minimumWhiteTextContrast,
                  let displayedRGB = RGB(hex: rawRGB.hex) else {
                continue
            }

            let displayedLab = OKLab(rgb: displayedRGB)
            let parentDistance = displayedLab.distance(to: parentLab)
            guard parentDistance <= radius + renderedColorTolerance else { continue }
            let siblingSeparation = siblingLabs
                .map { displayedLab.distance(to: $0) }
                .min() ?? parentDistance
            let globalSeparation = usedLabs
                .map { displayedLab.distance(to: $0) }
                .min() ?? parentDistance
            // The hard radius enforces hierarchy. Within it, sibling distance
            // dominates; global separation only breaks otherwise close ties.
            let score = (siblingSeparation * 1_000)
                + (globalSeparation * 10)
                + parentDistance

            if readableFallback == nil || score > readableFallback!.score {
                readableFallback = (displayedRGB, score)
            }
            guard !usedHexes.contains(displayedRGB.hex) else { continue }
            if best == nil || score > best!.score {
                best = (displayedRGB, score)
            }
        }

        // At extreme depths, 8-bit sRGB can no longer represent a unique color
        // inside the shrinking neighborhood. Reusing the closest readable
        // rendered candidate preserves hierarchy and never drops the tag.
        return best?.rgb ?? readableFallback?.rgb ?? parent
    }

    private static func fractional(_ value: Double) -> Double {
        value - floor(value)
    }
}

private extension TagTreeAsset {
    func depth(ofNodeAt index: Int) -> Int {
        var depth = 0
        var currentParentID = nodes[index].parentID
        var visited = Set([nodes[index].id])
        while let parentID = currentParentID,
              visited.insert(parentID).inserted,
              let parent = nodes.first(where: { $0.id == parentID }) {
            depth += 1
            currentParentID = parent.parentID
        }
        return depth
    }
}

private struct HSL {
    var hue: Double
    var saturation: Double
    var lightness: Double
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

    init(hsl: HSL) {
        let saturation = hsl.saturation / 100
        let lightness = hsl.lightness / 100
        let chroma = (1 - abs((2 * lightness) - 1)) * saturation
        let hueSection = hsl.hue / 60
        let intermediate = chroma * (1 - abs(hueSection.truncatingRemainder(dividingBy: 2) - 1))
        let base: (Double, Double, Double)
        switch hueSection {
        case 0..<1: base = (chroma, intermediate, 0)
        case 1..<2: base = (intermediate, chroma, 0)
        case 2..<3: base = (0, chroma, intermediate)
        case 3..<4: base = (0, intermediate, chroma)
        case 4..<5: base = (intermediate, 0, chroma)
        default: base = (chroma, 0, intermediate)
        }
        let match = lightness - chroma / 2
        red = base.0 + match
        green = base.1 + match
        blue = base.2 + match
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

    init(rgb: RGB) {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let red = linear(rgb.red)
        let green = linear(rgb.green)
        let blue = linear(rgb.blue)
        let l = (0.4122214708 * red) + (0.5363325363 * green) + (0.0514459929 * blue)
        let m = (0.2119034982 * red) + (0.6806995451 * green) + (0.1073969566 * blue)
        let s = (0.0883024619 * red) + (0.2817188376 * green) + (0.6299787005 * blue)
        let lRoot = cbrt(l)
        let mRoot = cbrt(m)
        let sRoot = cbrt(s)
        lightness = (0.2104542553 * lRoot) + (0.7936177850 * mRoot) - (0.0040720468 * sRoot)
        a = (1.9779984951 * lRoot) - (2.4285922050 * mRoot) + (0.4505937099 * sRoot)
        b = (0.0259040371 * lRoot) + (0.7827717662 * mRoot) - (0.8086757660 * sRoot)
    }

    func distance(to other: OKLab) -> Double {
        let deltaLightness = lightness - other.lightness
        let deltaA = a - other.a
        let deltaB = b - other.b
        return sqrt((deltaLightness * deltaLightness) + (deltaA * deltaA) + (deltaB * deltaB))
    }
}
