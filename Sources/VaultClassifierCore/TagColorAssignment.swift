import Foundation

/// Assigns persistent, presentation-only colors from tag-tree structure.
///
/// There is no hash or preset palette. Roots are neutral grey anchors.
/// First-level children seed the full readable OKLCH space through a
/// non-uniform density function over lightness, relative chroma, and hue.
/// Deeper descendants are selected inside a bounded OKLab neighborhood around
/// their parent, and that neighborhood contracts geometrically at each
/// generation. Siblings disperse across all three perceptual properties while
/// hierarchy similarity remains the stronger constraint.
public enum TagColorAssignment {
    public static let currentAlgorithmVersion = 3
    public static let minimumWhiteTextContrast = 4.5

    static let firstInheritedMaximumOffset = 0.080
    static let generationContraction = 0.45
    static let rootNeutralLightness = 0.55

    private static let goldenRatioConjugate = 0.618_033_988_749_894_9
    private static let silverRatioConjugate = 0.414_213_562_373_095_0
    private static let rootThreeConjugate = 0.732_050_807_568_877_2
    private static let seedLightnessMinimum = 0.40
    private static let seedLightnessMaximum = 0.58
    private static let seedRelativeChromaMinimum = 0.32
    private static let seedRelativeChromaMaximum = 0.94
    private static let densityFloor = 0.16
    private static let localDensityProbeRadius = 0.032
    private static let candidateCount = 384
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

        let rootHex = neutralRootColor.hex
        for index in tree.nodes.indices where tree.nodes[index].parentID == nil {
            tree.nodes[index].colorHex = rootHex
        }

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
                let rgb = neutralRootColor
                tree.nodes[index].colorHex = rgb.hex
                usedColors.append(rgb)
                unresolved.remove(index)
            }
        }
    }

    static func maximumOffset(edgeDepth: Int) -> Double {
        guard edgeDepth > 1 else { return .greatestFiniteMagnitude }
        return firstInheritedMaximumOffset
            * pow(generationContraction, Double(edgeDepth - 2))
    }

    static func perceptualDistance(_ lhs: String?, _ rhs: String?) -> Double? {
        guard let lhsRGB = RGB(hex: lhs), let rhsRGB = RGB(hex: rhs) else { return nil }
        return OKLab(rgb: lhsRGB).distance(to: OKLab(rgb: rhsRGB))
    }

    static var neutralRootHex: String {
        neutralRootColor.hex
    }

    static func perceptualProperties(
        _ value: String?
    ) -> (lightness: Double, relativeChroma: Double, hueRadians: Double)? {
        guard let rgb = RGB(hex: value) else { return nil }
        let tuple = colorTuple(for: OKLab(rgb: rgb))
        return (tuple.lightness, tuple.relativeChroma, tuple.hueRadians)
    }

    static func preferenceDensity(_ value: String?) -> Double? {
        guard let rgb = RGB(hex: value) else { return nil }
        let lab = OKLab(rgb: rgb)
        return preferenceDensity(at: colorTuple(for: lab), lab: lab, rgb: rgb)
    }

    private static func generatedColor(
        parent: RGB?,
        edgeDepth: Int,
        ordinal: Int,
        siblingColors: [RGB],
        usedColors: [RGB]
    ) -> RGB {
        guard let parent, edgeDepth > 0 else {
            return neutralRootColor
        }
        if edgeDepth == 1 {
            return generatedSeedColor(
                ordinal: ordinal,
                siblingColors: siblingColors,
                usedColors: usedColors
            )
        }
        return generatedDescendantColor(
            parent: parent,
            edgeDepth: edgeDepth,
            ordinal: ordinal,
            siblingColors: siblingColors,
            usedColors: usedColors
        )
    }

    private static var neutralRootColor: RGB {
        let lab = OKLab(lightness: rootNeutralLightness, a: 0, b: 0)
        guard let rawRGB = RGB(oklab: lab), let displayedRGB = RGB(hex: rawRGB.hex) else {
            preconditionFailure("The neutral root color must be representable in sRGB.")
        }
        return displayedRGB
    }

    private static func generatedSeedColor(
        ordinal: Int,
        siblingColors: [RGB],
        usedColors: [RGB]
    ) -> RGB {
        let chromaticUsedColors = usedColors.filter {
            colorTuple(for: OKLab(rgb: $0)).chroma > 0.02
        }
        let referenceColors = siblingColors.isEmpty ? chromaticUsedColors : siblingColors
        let referenceLabs = referenceColors.map(OKLab.init)
        let referenceTuples = referenceLabs.map(colorTuple)
        let usedLabs = usedColors.map(OKLab.init)
        let usedHexes = Set(usedColors.map(\.hex))
        var best: (rgb: RGB, score: Double)?
        var readableFallback: (rgb: RGB, score: Double)?

        for candidateIndex in 0..<candidateCount {
            let sequenceIndex = Double(candidateIndex + 1 + ordinal * candidateCount)
            let hue = fractional(sequenceIndex * goldenRatioConjugate) * 2 * Double.pi
            let lightness = seedLightnessMinimum
                + fractional(sequenceIndex * silverRatioConjugate)
                * (seedLightnessMaximum - seedLightnessMinimum)
            let relativeChroma = seedRelativeChromaMinimum
                + fractional(sequenceIndex * rootThreeConjugate)
                * (seedRelativeChromaMaximum - seedRelativeChromaMinimum)
            let maximumChroma = maximumDisplayableChroma(lightness: lightness, hueRadians: hue)
            let candidateLab = OKLab(
                lightness: lightness,
                a: cos(hue) * maximumChroma * relativeChroma,
                b: sin(hue) * maximumChroma * relativeChroma
            )
            guard let rawRGB = RGB(oklab: candidateLab),
                  rawRGB.contrastAgainstWhite >= minimumWhiteTextContrast,
                  let displayedRGB = RGB(hex: rawRGB.hex) else {
                continue
            }

            let displayedLab = OKLab(rgb: displayedRGB)
            let displayedTuple = colorTuple(for: displayedLab)
            let density = preferenceDensity(
                at: displayedTuple,
                lab: displayedLab,
                rgb: displayedRGB
            )
            let jointSeparation = referenceTuples
                .map { jointTupleDistance(displayedTuple, $0) }
                .min() ?? 1
            let perceptualSeparation = referenceLabs
                .map { displayedLab.distance(to: $0) }
                .min() ?? 0.25
            let globalSeparation = usedLabs
                .map { displayedLab.distance(to: $0) }
                .min() ?? 0
            // Variable-radius farthest-point sampling in three dimensions:
            // local spacing is proportional to density^(-1/3), so dense
            // tuples admit more colors without erasing sparse regions.
            let score = (jointSeparation * pow(density, 1.0 / 3.0) * 1_000)
                + (perceptualSeparation * 100)
                + (globalSeparation * 10)

            if readableFallback == nil || score > readableFallback!.score {
                readableFallback = (displayedRGB, score)
            }
            guard !usedHexes.contains(displayedRGB.hex) else { continue }
            if best == nil || score > best!.score {
                best = (displayedRGB, score)
            }
        }

        if let best {
            return best.rgb
        }
        if let readableFallback {
            return readableFallback.rgb
        }
        preconditionFailure("The readable OKLCH seed domain must contain a displayable color.")
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
        let parentTuple = colorTuple(for: parentLab)
        let siblingTuples = siblingLabs.map(colorTuple)
        let usedLabs = usedColors.map(OKLab.init)
        let usedHexes = Set(usedColors.map(\.hex))
        let radius = maximumOffset(edgeDepth: edgeDepth)
        var best: (rgb: RGB, score: Double)?
        var readableFallback: (rgb: RGB, score: Double)?

        for candidateIndex in 0..<candidateCount {
            let sequenceIndex = Double(candidateIndex + 1 + ordinal * candidateCount)
            let angle = fractional(sequenceIndex * goldenRatioConjugate) * 2 * Double.pi
            let radialFraction = 0.72 + fractional(sequenceIndex * silverRatioConjugate) * 0.18
            let vertical = (fractional(sequenceIndex * rootThreeConjugate) * 2) - 1
            let plane = sqrt(max(0, 1 - (vertical * vertical)))
            let offset = radius * radialFraction
            let candidateLab = OKLab(
                lightness: parentLab.lightness + (vertical * offset),
                a: parentLab.a + (cos(angle) * plane * offset),
                b: parentLab.b + (sin(angle) * plane * offset)
            )
            guard let rawRGB = RGB(oklab: candidateLab),
                  rawRGB.contrastAgainstWhite >= minimumWhiteTextContrast,
                  let displayedRGB = RGB(hex: rawRGB.hex) else {
                continue
            }

            let displayedLab = OKLab(rgb: displayedRGB)
            let displayedTuple = colorTuple(for: displayedLab)
            let parentDistance = displayedLab.distance(to: parentLab)
            guard parentDistance <= radius + renderedColorTolerance else { continue }
            let siblingSeparation = siblingLabs
                .map { displayedLab.distance(to: $0) }
                .min() ?? parentDistance
            let propertySeparation = siblingTuples
                .map { jointTupleDistance(displayedTuple, $0) }
                .min() ?? jointTupleDistance(displayedTuple, parentTuple)
            let globalSeparation = usedLabs
                .map { displayedLab.distance(to: $0) }
                .min() ?? parentDistance
            let density = preferenceDensity(
                at: displayedTuple,
                lab: displayedLab,
                rgb: displayedRGB
            )
            // The hard radius enforces hierarchy. Within it, sibling distance
            // dominates across lightness, chroma, and hue. Tuple density and
            // global separation only influence choices inside that radius.
            let score = (siblingSeparation * pow(density, 1.0 / 3.0) * 1_000)
                + (propertySeparation * 100)
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

    private static func preferenceDensity(
        at tuple: ColorTuple,
        lab: OKLab,
        rgb: RGB
    ) -> Double {
        let usableVolume = localUsableVolume(around: lab)
        let contrastHeadroom = clamped(
            (rgb.contrastAgainstWhite - minimumWhiteTextContrast) / 4,
            minimum: 0.04,
            maximum: 1
        )
        let chromaOffset = (tuple.relativeChroma - 0.66) / 0.25
        let chromaQuality = exp(-0.5 * chromaOffset * chromaOffset)
        let jointQuality = pow(
            max(0.000_001, usableVolume * contrastHeadroom * chromaQuality),
            1.0 / 3.0
        )
        return densityFloor + ((1 - densityFloor) * jointQuality)
    }

    private static func localUsableVolume(around lab: OKLab) -> Double {
        let diagonal = 1 / sqrt(3.0)
        let directions: [(Double, Double, Double)] = [
            (1, 0, 0), (-1, 0, 0),
            (0, 1, 0), (0, -1, 0),
            (0, 0, 1), (0, 0, -1),
            (diagonal, diagonal, diagonal),
            (diagonal, diagonal, -diagonal),
            (diagonal, -diagonal, diagonal),
            (diagonal, -diagonal, -diagonal),
            (-diagonal, diagonal, diagonal),
            (-diagonal, diagonal, -diagonal),
            (-diagonal, -diagonal, diagonal),
            (-diagonal, -diagonal, -diagonal),
        ]
        let validCount = directions.reduce(into: 0) { count, direction in
            let probe = OKLab(
                lightness: lab.lightness + (direction.0 * localDensityProbeRadius),
                a: lab.a + (direction.1 * localDensityProbeRadius),
                b: lab.b + (direction.2 * localDensityProbeRadius)
            )
            if let rgb = RGB(oklab: probe),
               rgb.contrastAgainstWhite >= minimumWhiteTextContrast {
                count += 1
            }
        }
        return Double(validCount) / Double(directions.count)
    }

    private static func colorTuple(for lab: OKLab) -> ColorTuple {
        let chroma = sqrt((lab.a * lab.a) + (lab.b * lab.b))
        var hue = atan2(lab.b, lab.a)
        if hue < 0 {
            hue += 2 * Double.pi
        }
        let maximumChroma = maximumDisplayableChroma(
            lightness: lab.lightness,
            hueRadians: hue
        )
        return ColorTuple(
            lightness: lab.lightness,
            chroma: chroma,
            relativeChroma: maximumChroma > 0 ? min(1, chroma / maximumChroma) : 0,
            hueRadians: hue
        )
    }

    private static func jointTupleDistance(_ lhs: ColorTuple, _ rhs: ColorTuple) -> Double {
        let lightnessRange = seedLightnessMaximum - seedLightnessMinimum
        let chromaRange = seedRelativeChromaMaximum - seedRelativeChromaMinimum
        let lightnessDistance = (lhs.lightness - rhs.lightness) / lightnessRange
        let chromaDistance = (lhs.relativeChroma - rhs.relativeChroma) / chromaRange
        let rawHueDistance = abs(lhs.hueRadians - rhs.hueRadians)
        let hueDistance = min(rawHueDistance, (2 * Double.pi) - rawHueDistance) / Double.pi
        return sqrt(
            (
                (lightnessDistance * lightnessDistance)
                + (chromaDistance * chromaDistance)
                + (hueDistance * hueDistance)
            ) / 3
        )
    }

    private static func maximumDisplayableChroma(
        lightness: Double,
        hueRadians: Double
    ) -> Double {
        var lowerBound = 0.0
        var upperBound = 0.5
        for _ in 0..<18 {
            let midpoint = (lowerBound + upperBound) / 2
            let lab = OKLab(
                lightness: lightness,
                a: cos(hueRadians) * midpoint,
                b: sin(hueRadians) * midpoint
            )
            if RGB(oklab: lab) == nil {
                upperBound = midpoint
            } else {
                lowerBound = midpoint
            }
        }
        return lowerBound
    }

    private static func fractional(_ value: Double) -> Double {
        value - floor(value)
    }

    private static func clamped(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(maximum, max(minimum, value))
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

private struct ColorTuple {
    var lightness: Double
    var chroma: Double
    var relativeChroma: Double
    var hueRadians: Double
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
