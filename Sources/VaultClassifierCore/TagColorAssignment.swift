import Foundation

/// Assigns persistent, presentation-only tag colors from tree structure.
///
/// This deliberately uses no named or preset palette. Candidate colors are
/// generated across continuous HSL space with irrational low-discrepancy
/// sequences. A bounded search chooses the candidate furthest from existing
/// tag colors in OKLab while constraining descendants to their parent's hue
/// family. Once assigned, the resulting hex color is persisted on the tag and
/// is never recalculated merely because the tree later changes.
public enum TagColorAssignment {
    public static let minimumWhiteTextContrast = 4.5

    private static let goldenRatioConjugate = 0.618_033_988_749_894_9
    private static let silverRatioConjugate = 0.414_213_562_373_095_0
    private static let rootThreeConjugate = 0.732_050_807_568_877_2
    private static let candidateCount = 144

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

    public static func assignMissingColors(in tree: inout TagTreeAsset) {
        guard !tree.nodes.isEmpty else { return }

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
                let depth = tree.depth(ofNodeAt: index)
                let siblingOrdinal = tree.nodes[..<index].filter {
                    $0.parentID == tree.nodes[index].parentID
                }.count
                let rgb = generatedColor(
                    parent: parentRGB,
                    depth: depth,
                    ordinal: siblingOrdinal,
                    usedColors: usedColors
                )
                tree.nodes[index].colorHex = rgb.hex
                usedColors.append(rgb)
                unresolved.remove(index)
                assignedAny = true
            }

            if !assignedAny, let index = unresolved.min() {
                // Invalid cyclic legacy trees are still made presentation-safe;
                // semantic validation remains authoritative elsewhere.
                let rgb = generatedColor(
                    parent: nil,
                    depth: 0,
                    ordinal: index,
                    usedColors: usedColors
                )
                tree.nodes[index].colorHex = rgb.hex
                usedColors.append(rgb)
                unresolved.remove(index)
            }
        }
    }

    private static func generatedColor(
        parent: RGB?,
        depth: Int,
        ordinal: Int,
        usedColors: [RGB]
    ) -> RGB {
        let parentHSL = parent.map(HSL.init)
        let constrainedSpread = max(16.0, 58.0 / sqrt(Double(max(1, depth))))
        var best: (rgb: RGB, distance: Double)?

        for candidateIndex in 0..<candidateCount {
            let sequenceIndex = Double(candidateIndex + 1 + ordinal * candidateCount)
            let hueFraction = fractional(sequenceIndex * goldenRatioConjugate)
            let saturationFraction = fractional(sequenceIndex * silverRatioConjugate)
            let lightnessFraction = fractional(sequenceIndex * rootThreeConjugate)

            let hue: Double
            let saturation: Double
            let initialLightness: Double
            if let parentHSL {
                hue = normalizedHue(
                    parentHSL.hue + ((hueFraction * 2) - 1) * constrainedSpread
                )
                saturation = clamped(
                    parentHSL.saturation + (saturationFraction - 0.5) * 22,
                    minimum: 52,
                    maximum: 82
                )
                initialLightness = clamped(
                    parentHSL.lightness + (lightnessFraction - 0.5) * 15,
                    minimum: 24,
                    maximum: 43
                )
            } else {
                hue = hueFraction * 360
                saturation = 58 + saturationFraction * 24
                initialLightness = 27 + lightnessFraction * 15
            }

            var lightness = initialLightness
            var rgb = RGB(hsl: .init(hue: hue, saturation: saturation, lightness: lightness))
            while rgb.contrastAgainstWhite < minimumWhiteTextContrast, lightness > 18 {
                lightness -= 0.5
                rgb = RGB(hsl: .init(hue: hue, saturation: saturation, lightness: lightness))
            }

            let lab = OKLab(rgb: rgb)
            let minimumDistance = usedColors
                .map { lab.distance(to: OKLab(rgb: $0)) }
                .min() ?? .greatestFiniteMagnitude
            if best == nil || minimumDistance > best!.distance {
                best = (rgb, minimumDistance)
            }
        }

        return best!.rgb
    }

    private static func fractional(_ value: Double) -> Double {
        value - floor(value)
    }

    private static func normalizedHue(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
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

private struct HSL {
    var hue: Double
    var saturation: Double
    var lightness: Double

    init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    init(rgb: RGB) {
        let red = rgb.red
        let green = rgb.green
        let blue = rgb.blue
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2

        var hue = 0.0
        var saturation = 0.0
        if delta > 0 {
            saturation = delta / (1 - abs((2 * lightness) - 1))
            if maximum == red {
                hue = 60 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6))
            } else if maximum == green {
                hue = 60 * (((blue - red) / delta) + 2)
            } else {
                hue = 60 * (((red - green) / delta) + 4)
            }
        }
        self.hue = hue < 0 ? hue + 360 : hue
        self.saturation = saturation * 100
        self.lightness = lightness * 100
    }
}

private struct RGB {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

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
