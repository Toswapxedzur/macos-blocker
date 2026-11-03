import Foundation
import XCTest
@testable import VaultClassifierCore

final class TagColorAssignmentTests: XCTestCase {
    func testHorizontalOrderSplitsChildrenAroundParentInCreationOrder() {
        let tree = TagTreeAsset(name: "Topics", nodes: [
            .init(id: "parent", name: "Parent", positionX: 500, positionY: 50),
            .init(id: "a", name: "A", parentID: "parent", positionX: 900, positionY: 100),
            .init(id: "b", name: "B", parentID: "parent", positionX: 100, positionY: 100),
            .init(id: "c", name: "C", parentID: "parent", positionX: 700, positionY: 100),
            .init(id: "d", name: "D", parentID: "parent", positionX: 300, positionY: 100),
            .init(id: "a1", name: "A1", parentID: "a", positionX: 800, positionY: 150),
            .init(id: "a2", name: "A2", parentID: "a", positionX: 200, positionY: 150),
        ])
        XCTAssertEqual(TagColorAssignment.horizontalOrder(in: tree), ["a1", "a", "a2", "b", "parent", "c", "d"])
    }

    func testHueWheelIsEvenlySpacedAndCanvasMovesDoNotRecolor() throws {
        var tree = TagTreeAsset(name: "Topics", nodes: (0..<8).map { index in
            .init(id: "tag-\(index)", name: "Tag \(index)")
        }, colorAlgorithmVersion: 5)
        TagColorAssignment.reconcileColors(in: &tree)
        XCTAssertEqual(tree.colorAlgorithmVersion, TagColorAssignment.currentAlgorithmVersion)
        let hues = try tree.nodes.map { node in
            XCTAssertTrue(TagColorAssignment.isValidThemePair(
                lightHex: node.lightColorHex, darkHex: node.darkColorHex
            ))
            return try hueRadians(of: XCTUnwrap(node.darkColorHex))
        }
        var intervals: [Double] = []
        for index in hues.indices {
            let next = hues[(index + 1) % hues.count]
            let delta = next - hues[index] + 2 * Double.pi
            intervals.append(delta.truncatingRemainder(dividingBy: 2 * Double.pi))
        }
        for interval in intervals {
            XCTAssertEqual(interval, 2 * Double.pi / Double(hues.count), accuracy: 0.09)
        }
        let original = tree.nodes.map { ($0.lightColorHex, $0.darkColorHex) }
        tree.nodes[0].positionX = 999
        TagColorAssignment.reconcileColors(in: &tree)
        for (index, node) in tree.nodes.enumerated() {
            XCTAssertEqual(node.lightColorHex, original[index].0)
            XCTAssertEqual(node.darkColorHex, original[index].1)
        }
    }

    func testAddingTagRedistributesWholeWheelAndMalformedCycleDoesNotCrash() {
        var tree = TagTreeAsset(name: "Topics", nodes: [
            .init(id: "parent", name: "Parent"),
            .init(id: "a", name: "A", parentID: "parent"),
            .init(id: "b", name: "B", parentID: "parent"),
        ])
        TagColorAssignment.reconcileColors(in: &tree)
        let previous = Dictionary(uniqueKeysWithValues: tree.nodes.map { ($0.id, $0.darkColorHex) })
        tree.nodes.append(.init(id: "c", name: "C", parentID: "parent"))
        TagColorAssignment.reconcileColors(in: &tree)
        XCTAssertEqual(TagColorAssignment.horizontalOrder(in: tree), ["a", "parent", "b", "c"])
        XCTAssertTrue(tree.nodes.contains { $0.id != "a" && $0.darkColorHex != previous[$0.id] })
        XCTAssertTrue(tree.nodes.allSatisfy {
            TagColorAssignment.isValidThemePair(lightHex: $0.lightColorHex, darkHex: $0.darkColorHex)
        })

        var cyclic = TagTreeAsset(name: "Legacy", nodes: [
            .init(id: "x", name: "X", parentID: "y"),
            .init(id: "y", name: "Y", parentID: "x"),
        ], colorAlgorithmVersion: 0)
        TagColorAssignment.reconcileColors(in: &cyclic)
        XCTAssertEqual(Set(TagColorAssignment.horizontalOrder(in: cyclic)), ["x", "y"])
        XCTAssertTrue(cyclic.nodes.allSatisfy { $0.lightColorHex != nil && $0.darkColorHex != nil })
    }

    func testLargeTreeKeepsBothThemeVariantsReadable() {
        var tree = TagTreeAsset(name: "Many tags", nodes: (0..<513).map { index in
            .init(id: "tag-\(index)", name: "Tag \(index)")
        })
        TagColorAssignment.reconcileColors(in: &tree)
        XCTAssertEqual(tree.nodes.count, 513)
        XCTAssertTrue(tree.nodes.allSatisfy {
            TagColorAssignment.isValidThemePair(lightHex: $0.lightColorHex, darkHex: $0.darkColorHex)
        })
    }

    private func hueRadians(of hex: String) throws -> Double {
        let digits = try XCTUnwrap(Int(hex.dropFirst(), radix: 16))
        func linear(_ byte: Int) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let red = linear((digits >> 16) & 255)
        let green = linear((digits >> 8) & 255)
        let blue = linear(digits & 255)
        let l = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let m = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let s = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let angle = atan2(b, a)
        return angle < 0 ? angle + 2 * Double.pi : angle
    }
}
