import Foundation

/// Assigns persistent, presentation-only color pairs from tag-tree structure.
///
/// There is no hash or preset palette. Roots are neutral grey anchors.
/// First-level children seed a hue-neutral, readable OKLCH domain. Every tag
/// owns a dark fill for white text and a brightness-inverted light fill for
/// black text. Deeper descendants remain inside geometrically contracting
/// OKLab neighborhoods in both themes.
public enum TagColorAssignment {
    public static let currentAlgorithmVersion = 5
    public static let minimumTextContrast = 7.0

    static let firstInheritedMaximumOffset = 0.080
    static let generationContraction = 0.45
    static let darkLightnessMinimum = 0.36
    static let darkLightnessMaximum = 0.46
    static let lightnessInversionSum = 1.28
    static let rootDarkLightness = 0.41

    private static let goldenRatioConjugate = 0.618_033_988_749_894_9
    private static let silverRatioConjugate = 0.414_213_562_373_095_0
    private static let rootThreeConjugate = 0.732_050_807_568_877_2
    private static let seedRelativeChromaMinimum = 0.50
    private static let seedRelativeChromaMaximum = 0.92
    private static let preferredDarkLightness = 0.41
    private static let preferredDarkLightnessWidth = 0.035
    private static let preferredRelativeChroma = 0.72
    private static let preferredRelativeChromaWidth = 0.17
    private static let densityFloor = 0.15
    private static let localDensityProbeRadius = 0.020
    private static let candidateCount = 256
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

    public static func isValidThemePair(lightHex: String?, darkHex: String?) -> Bool {
        guard let pair = ColorPair(lightHex: lightHex, darkHex: darkHex) else { return false }
        return isAcceptablePersistedPair(pair)
    }

    /// Reconciles legacy or prior-algorithm trees exactly once, then preserves
    /// both assigned variants during ordinary saves.
    public static func reconcileColors(in tree: inout TagTreeAsset) {
        if tree.colorAlgorithmVersion < currentAlgorithmVersion {
            for index in tree.nodes.indices {
                tree.nodes[index].lightColorHex = nil
                tree.nodes[index].darkColorHex = nil
            }
            tree.colorAlgorithmVersion = currentAlgorithmVersion
        }
        assignMissingColors(in: &tree)
    }

    /// Clears one moved branch so its variants can inherit the new parent's
    /// progressively smaller neighborhoods.
    public static func invalidateSubtree(rootID: String, in tree: inout TagTreeAsset) {
        let nodeIDs = tree.subtreeNodeIDs(rootID: rootID)
        for index in tree.nodes.indices where nodeIDs.contains(tree.nodes[index].id) {
            tree.nodes[index].lightColorHex = nil
            tree.nodes[index].darkColorHex = nil
        }
    }

    /// Assigns only missing or invalid pairs. Existing valid pairs are stable
    /// when a sibling is added, a tag is renamed, or its canvas moves.
    public static func assignMissingColors(in tree: inout TagTreeAsset) {
        guard !tree.nodes.isEmpty else { return }

        let rootPair = neutralRootPair
        for index in tree.nodes.indices where tree.nodes[index].parentID == nil {
            tree.nodes[index].lightColorHex = rootPair.light.hex
            tree.nodes[index].darkColorHex = rootPair.dark.hex
        }

        let invalidColorRootIDs = tree.nodes.compactMap { node in
            !isValidThemePair(lightHex: node.lightColorHex, darkHex: node.darkColorHex)
                ? node.id
                : nil
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
            tree.nodes[index].lightColorHex = nil
            tree.nodes[index].darkColorHex = nil
        }

        var usedPairs: [ColorPair] = []
        for index in tree.nodes.indices {
            guard let pair = ColorPair(
                lightHex: tree.nodes[index].lightColorHex,
                darkHex: tree.nodes[index].darkColorHex
            ), isAcceptablePersistedPair(pair) else {
                tree.nodes[index].lightColorHex = nil
                tree.nodes[index].darkColorHex = nil
                continue
            }
            tree.nodes[index].lightColorHex = pair.light.hex
            tree.nodes[index].darkColorHex = pair.dark.hex
            usedPairs.append(pair)
        }

        var unresolved = Set(tree.nodes.indices.filter {
            ColorPair(
                lightHex: tree.nodes[$0].lightColorHex,
                darkHex: tree.nodes[$0].darkColorHex
            ) == nil
        })
        while !unresolved.isEmpty {
            var assignedAny = false
            for index in unresolved.sorted() {
                let parentIndex = tree.nodes[index].parentID.flatMap { parentID in
                    tree.nodes.firstIndex(where: { $0.id == parentID })
                }
                if let parentIndex,
                   ColorPair(
                    lightHex: tree.nodes[parentIndex].lightColorHex,
                    darkHex: tree.nodes[parentIndex].darkColorHex
                   ) == nil {
                    continue
                }

                let parentPair = parentIndex.flatMap {
                    ColorPair(
                        lightHex: tree.nodes[$0].lightColorHex,
                        darkHex: tree.nodes[$0].darkColorHex
                    )
                }
                let siblingPairs = tree.nodes.indices.compactMap { siblingIndex -> ColorPair? in
                    guard siblingIndex != index,
                          tree.nodes[siblingIndex].parentID == tree.nodes[index].parentID else {
                        return nil
                    }
                    return ColorPair(
                        lightHex: tree.nodes[siblingIndex].lightColorHex,
                        darkHex: tree.nodes[siblingIndex].darkColorHex
                    )
                }
                let edgeDepth = tree.depth(ofNodeAt: index)
                let siblingOrdinal = tree.nodes[..<index].filter {
                    $0.parentID == tree.nodes[index].parentID
                }.count
                let pair = generatedPair(
                    parent: parentPair,
                    edgeDepth: edgeDepth,
                    ordinal: siblingOrdinal,
                    siblingPairs: siblingPairs,
                    usedPairs: usedPairs
                )
                tree.nodes[index].lightColorHex = pair.light.hex
                tree.nodes[index].darkColorHex = pair.dark.hex
                usedPairs.append(pair)
                unresolved.remove(index)
                assignedAny = true
            }

            if !assignedAny, let index = unresolved.min() {
                // Invalid cyclic legacy trees still get readable neutral
                // variants; semantic tree validation remains authoritative.
                tree.nodes[index].lightColorHex = rootPair.light.hex
                tree.nodes[index].darkColorHex = rootPair.dark.hex
                usedPairs.append(rootPair)
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

    static var neutralRootLightHex: String {
        neutralRootPair.light.hex
    }

    static var neutralRootDarkHex: String {
        neutralRootPair.dark.hex
    }

    static func perceptualProperties(
        _ value: String?
    ) -> (lightness: Double, relativeChroma: Double, hueRadians: Double)? {
        guard let rgb = RGB(hex: value) else { return nil }
        let tuple = colorTuple(for: OKLab(rgb: rgb))
        return (tuple.lightness, tuple.relativeChroma, tuple.hueRadians)
    }

    static func preferenceDensity(lightHex: String?, darkHex: String?) -> Double? {
        guard let pair = ColorPair(lightHex: lightHex, darkHex: darkHex) else { return nil }
        return preferenceDensity(for: pair)
    }

    private static func generatedPair(
        parent: ColorPair?,
        edgeDepth: Int,
        ordinal: Int,
        siblingPairs: [ColorPair],
        usedPairs: [ColorPair]
    ) -> ColorPair {
        guard let parent, edgeDepth > 0 else {
            return neutralRootPair
        }
        if edgeDepth == 1 {
            return generatedSeedPair(
                ordinal: ordinal,
                siblingPairs: siblingPairs,
                usedPairs: usedPairs
            )
        }
        return generatedDescendantPair(
            parent: parent,
            edgeDepth: edgeDepth,
            ordinal: ordinal,
            siblingPairs: siblingPairs,
            usedPairs: usedPairs
        )
    }

    private static var neutralRootPair: ColorPair {
        let darkLab = OKLab(lightness: rootDarkLightness, a: 0, b: 0)
        guard let pair = renderedPair(forDarkLab: darkLab) else {
            preconditionFailure("The neutral root pair must be representable and readable.")
        }
        return pair
    }

    private static func generatedSeedPair(
        ordinal: Int,
        siblingPairs: [ColorPair],
        usedPairs: [ColorPair]
    ) -> ColorPair {
        let chromaticUsedPairs = usedPairs.filter {
            colorTuple(for: OKLab(rgb: $0.dark)).chroma > 0.02
        }
        let referencePairs = siblingPairs.isEmpty ? chromaticUsedPairs : siblingPairs
        let referenceTuples = referencePairs.map { colorTuple(for: OKLab(rgb: $0.dark)) }
        let usedLightLabs = usedPairs.map { OKLab(rgb: $0.light) }
        let usedDarkLabs = usedPairs.map { OKLab(rgb: $0.dark) }
        let usedLightHexes = Set(usedPairs.map(\.light.hex))
        let usedDarkHexes = Set(usedPairs.map(\.dark.hex))
        var best: (pair: ColorPair, score: Double)?
        var readableFallback: (pair: ColorPair, score: Double)?

        for candidateIndex in 0..<candidateCount {
            let sequenceIndex = Double(candidateIndex + 1 + ordinal * candidateCount)
            let hue = fractional(sequenceIndex * goldenRatioConjugate) * 2 * Double.pi
            let darkLightness = darkLightnessMinimum
                + fractional(sequenceIndex * silverRatioConjugate)
                * (darkLightnessMaximum - darkLightnessMinimum)
            let relativeChroma = seedRelativeChromaMinimum
                + fractional(sequenceIndex * rootThreeConjugate)
                * (seedRelativeChromaMaximum - seedRelativeChromaMinimum)
            let maximumDarkChroma = maximumDisplayableChroma(
                lightness: darkLightness,
                hueRadians: hue
            )
            let candidateDarkLab = OKLab(
                lightness: darkLightness,
                a: cos(hue) * maximumDarkChroma * relativeChroma,
                b: sin(hue) * maximumDarkChroma * relativeChroma
            )
            guard let pair = renderedPair(forDarkLab: candidateDarkLab) else { continue }

            let displayedTuple = colorTuple(for: OKLab(rgb: pair.dark))
            let density = preferenceDensity(for: pair)
            let propertySeparation = referenceTuples
                .map { jointTupleDistance(displayedTuple, $0) }
                .min() ?? 1
            let perceptualSeparation = referencePairs
                .map { minimumThemeDistance(pair, $0) }
                .min() ?? 1
            let globalSeparation = zip(usedLightLabs, usedDarkLabs)
                .map { lightLab, darkLab in
                    min(
                        OKLab(rgb: pair.light).distance(to: lightLab),
                        OKLab(rgb: pair.dark).distance(to: darkLab)
                    )
                }
                .min() ?? 0
            // Distinctiveness dominates. Density is a gentle, hue-neutral
            // preference for the middle of the accepted brightness/chroma
            // bands and cannot overwhelm minimum two-theme separation.
            let score = (perceptualSeparation * (0.90 + (0.10 * density)) * 1_000)
                + (propertySeparation * 100)
                + (globalSeparation * 10)

            if readableFallback == nil || score > readableFallback!.score {
                readableFallback = (pair, score)
            }
            guard !usedLightHexes.contains(pair.light.hex),
                  !usedDarkHexes.contains(pair.dark.hex) else {
                continue
            }
            if best == nil || score > best!.score {
                best = (pair, score)
            }
        }

        if let best {
            return best.pair
        }
        if let readableFallback {
            return readableFallback.pair
        }
        preconditionFailure("The dual-theme OKLCH seed domain must contain a readable pair.")
    }

    private static func generatedDescendantPair(
        parent: ColorPair,
        edgeDepth: Int,
        ordinal: Int,
        siblingPairs: [ColorPair],
        usedPairs: [ColorPair]
    ) -> ColorPair {
        let parentDarkLab = OKLab(rgb: parent.dark)
        let parentLightLab = OKLab(rgb: parent.light)
        let siblingTuples = siblingPairs.map { colorTuple(for: OKLab(rgb: $0.dark)) }
        let parentTuple = colorTuple(for: parentDarkLab)
        let usedLightLabs = usedPairs.map { OKLab(rgb: $0.light) }
        let usedDarkLabs = usedPairs.map { OKLab(rgb: $0.dark) }
        let usedLightHexes = Set(usedPairs.map(\.light.hex))
        let usedDarkHexes = Set(usedPairs.map(\.dark.hex))
        let radius = maximumOffset(edgeDepth: edgeDepth)
        var best: (pair: ColorPair, score: Double)?
        var readableFallback: (pair: ColorPair, score: Double)?

        for candidateIndex in 0..<candidateCount {
            let sequenceIndex = Double(candidateIndex + 1 + ordinal * candidateCount)
            let angle = fractional(sequenceIndex * goldenRatioConjugate) * 2 * Double.pi
            // Probe both the edge and interior of the allowed neighborhood.
            // High-contrast pairs can reach a theme's gamut boundary where an
            // outer-only shell has no representable two-theme candidate.
            let radialFraction = 0.30 + fractional(sequenceIndex * silverRatioConjugate) * 0.60
            let vertical = (fractional(sequenceIndex * rootThreeConjugate) * 2) - 1
            let plane = sqrt(max(0, 1 - (vertical * vertical)))
            let offset = radius * radialFraction
            let candidateDarkLab = OKLab(
                lightness: parentDarkLab.lightness + (vertical * offset),
                a: parentDarkLab.a + (cos(angle) * plane * offset),
                b: parentDarkLab.b + (sin(angle) * plane * offset)
            )
            guard let pair = renderedPair(forDarkLab: candidateDarkLab) else { continue }

            let displayedDarkLab = OKLab(rgb: pair.dark)
            let displayedLightLab = OKLab(rgb: pair.light)
            let darkParentDistance = displayedDarkLab.distance(to: parentDarkLab)
            let lightParentDistance = displayedLightLab.distance(to: parentLightLab)
            guard darkParentDistance <= radius + renderedColorTolerance,
                  lightParentDistance <= radius + renderedColorTolerance else {
                continue
            }

            let displayedTuple = colorTuple(for: displayedDarkLab)
            let siblingSeparation = siblingPairs
                .map { minimumThemeDistance(pair, $0) }
                .min() ?? min(darkParentDistance, lightParentDistance)
            let propertySeparation = siblingTuples
                .map { jointTupleDistance(displayedTuple, $0) }
                .min() ?? jointTupleDistance(displayedTuple, parentTuple)
            let globalSeparation = zip(usedLightLabs, usedDarkLabs)
                .map { lightLab, darkLab in
                    min(
                        displayedLightLab.distance(to: lightLab),
                        displayedDarkLab.distance(to: darkLab)
                    )
                }
                .min() ?? min(darkParentDistance, lightParentDistance)
            let density = preferenceDensity(for: pair)
            let score = (siblingSeparation * (0.90 + (0.10 * density)) * 1_000)
                + (propertySeparation * 100)
                + (globalSeparation * 10)
                + min(darkParentDistance, lightParentDistance)

            if readableFallback == nil || score > readableFallback!.score {
                readableFallback = (pair, score)
            }
            guard !usedLightHexes.contains(pair.light.hex),
                  !usedDarkHexes.contains(pair.dark.hex) else {
                continue
            }
            if best == nil || score > best!.score {
                best = (pair, score)
            }
        }

        // At extreme depths, 8-bit sRGB can no longer represent a unique pair
        // inside both shrinking neighborhoods. Reusing the closest readable
        // pair preserves hierarchy and never drops the tag.
        return best?.pair ?? readableFallback?.pair ?? parent
    }

    private static func renderedPair(forDarkLab darkLab: OKLab) -> ColorPair? {
        guard (darkLightnessMinimum...darkLightnessMaximum).contains(darkLab.lightness) else {
            return nil
        }
        let darkTuple = colorTuple(for: darkLab)
        let lightLightness = lightnessInversionSum - darkLab.lightness
        let maximumLightChroma = maximumDisplayableChroma(
            lightness: lightLightness,
            hueRadians: darkTuple.hueRadians
        )
        let lightLab = OKLab(
            lightness: lightLightness,
            a: cos(darkTuple.hueRadians) * maximumLightChroma * darkTuple.relativeChroma,
            b: sin(darkTuple.hueRadians) * maximumLightChroma * darkTuple.relativeChroma
        )
        guard let rawDark = RGB(oklab: darkLab),
              let rawLight = RGB(oklab: lightLab),
              rawDark.contrastAgainstWhite >= minimumTextContrast,
              rawLight.contrastAgainstBlack >= minimumTextContrast,
              let displayedDark = RGB(hex: rawDark.hex),
              let displayedLight = RGB(hex: rawLight.hex),
              displayedDark.contrastAgainstWhite >= minimumTextContrast,
              displayedLight.contrastAgainstBlack >= minimumTextContrast else {
            return nil
        }
        return ColorPair(light: displayedLight, dark: displayedDark)
    }

    private static func preferenceDensity(for pair: ColorPair) -> Double {
        let darkLab = OKLab(rgb: pair.dark)
        let tuple = colorTuple(for: darkLab)
        let gamutRobustness = dualThemeUsableVolume(around: darkLab)
        let lightnessOffset = (
            tuple.lightness - preferredDarkLightness
        ) / preferredDarkLightnessWidth
        let lightnessPreference = exp(-0.5 * lightnessOffset * lightnessOffset)
        let chromaOffset = (
            tuple.relativeChroma - preferredRelativeChroma
        ) / preferredRelativeChromaWidth
        let chromaPreference = exp(-0.5 * chromaOffset * chromaOffset)
        let quality = pow(max(0.000_001, gamutRobustness), 0.25)
            * pow(max(0.000_001, lightnessPreference), 0.45)
            * pow(max(0.000_001, chromaPreference), 0.30)
        return densityFloor + ((1 - densityFloor) * quality)
    }

    private static func isAcceptablePersistedPair(_ pair: ColorPair) -> Bool {
        guard pair.dark.contrastAgainstWhite >= minimumTextContrast,
              pair.light.contrastAgainstBlack >= minimumTextContrast else {
            return false
        }
        let darkLab = OKLab(rgb: pair.dark)
        let lightLab = OKLab(rgb: pair.light)
        let tolerance = 0.012
        guard darkLab.lightness >= darkLightnessMinimum - tolerance,
              darkLab.lightness <= darkLightnessMaximum + tolerance,
              lightLab.lightness >= (lightnessInversionSum - darkLightnessMaximum) - tolerance,
              lightLab.lightness <= (lightnessInversionSum - darkLightnessMinimum) + tolerance,
              abs((darkLab.lightness + lightLab.lightness) - lightnessInversionSum) <= 0.020 else {
            return false
        }
        let darkTuple = colorTuple(for: darkLab)
        let lightTuple = colorTuple(for: lightLab)
        guard darkTuple.chroma > 0.02 || lightTuple.chroma > 0.02 else {
            return true
        }
        let rawHueDistance = abs(darkTuple.hueRadians - lightTuple.hueRadians)
        return min(rawHueDistance, (2 * Double.pi) - rawHueDistance) <= 0.080
    }

    private static func dualThemeUsableVolume(around darkLab: OKLab) -> Double {
        let directions: [(Double, Double, Double)] = [
            (1, 0, 0), (-1, 0, 0),
            (0, 1, 0), (0, -1, 0),
            (0, 0, 1), (0, 0, -1),
        ]
        let validCount = directions.reduce(into: 0) { count, direction in
            let probe = OKLab(
                lightness: darkLab.lightness + (direction.0 * localDensityProbeRadius),
                a: darkLab.a + (direction.1 * localDensityProbeRadius),
                b: darkLab.b + (direction.2 * localDensityProbeRadius)
            )
            if renderedPair(forDarkLab: probe) != nil {
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
        let lightnessRange = darkLightnessMaximum - darkLightnessMinimum
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

    private static func minimumThemeDistance(_ lhs: ColorPair, _ rhs: ColorPair) -> Double {
        min(
            OKLab(rgb: lhs.light).distance(to: OKLab(rgb: rhs.light)),
            OKLab(rgb: lhs.dark).distance(to: OKLab(rgb: rhs.dark))
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

private struct ColorPair {
    var light: RGB
    var dark: RGB

    init(light: RGB, dark: RGB) {
        self.light = light
        self.dark = dark
    }

    init?(lightHex: String?, darkHex: String?) {
        guard let light = RGB(hex: lightHex), let dark = RGB(hex: darkHex) else {
            return nil
        }
        self.light = light
        self.dark = dark
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
