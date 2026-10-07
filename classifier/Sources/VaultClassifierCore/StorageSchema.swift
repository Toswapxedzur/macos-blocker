import Foundation

/// Product releases and local document formats have independent clocks.
public struct StorageProduct: Codable, Equatable, Sendable {
    public var product: String
    public var appVersion: String
    public var major: Int { Int(appVersion.split(separator: ".").first ?? "") ?? -1 }

    public init(product: String, appVersion: String) {
        self.product = product
        self.appVersion = appVersion
    }

    public static var current: StorageProduct {
        #if os(Windows)
        let product = "windows"
        #else
        let product = "mac"
        #endif
        let versions = (Bundle.module.url(forResource: "storage-product-versions", withExtension: "json", subdirectory: "Resources")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
        let appBundleVersion = Bundle.main.bundleIdentifier?.hasPrefix("com.adamancia.vault.mac") == true
            ? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String : nil
        let version = ProcessInfo.processInfo.environment["VAULT_STORAGE_APP_VERSION"]
            ?? appBundleVersion
            ?? versions[product] ?? "unknown"
        return .init(product: product, appVersion: version)
    }

    /// Alpha import is a bounded transformation, removed after the next major.
    /// These are introduction majors, not schema numbers or beta marketing versions.
    public var alphaImportMajor: Int { product == "windows" ? 0 : product == "mac" ? 2 : 3 }
}

public struct StorageMetadata: Codable, Equatable, Sendable {
    public var format: String
    public var schemaVersion: Int
    public var product: String
    public var writtenByAppVersion: String

    public init(format: String, schemaVersion: Int, writer: StorageProduct = .current) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.product = writer.product
        self.writtenByAppVersion = writer.appVersion
    }
}

public enum StorageSchemaError: Error, Equatable, LocalizedError {
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): return "Unsupported storage (\(detail)). Saved data is preserved; this build cannot write it."
        }
    }
}

/// Registries identify formats by schema; expiry follows the writing product's
/// app major. Compatible current schemas need no transformation at all.
public struct StorageSchemaPolicy: Sendable {
    public let format: String
    public let currentSchema: Int
    public let writer: StorageProduct
    public init(format: String, currentSchema: Int = 1, writer: StorageProduct = .current) {
        self.format = format; self.currentSchema = currentSchema; self.writer = writer
    }

    public var metadata: StorageMetadata { .init(format: format, schemaVersion: currentSchema, writer: writer) }

    public func validate(_ stored: StorageMetadata?) throws {
        guard writer.major >= 0 else { throw StorageSchemaError.unsupported("missing product version") }
        guard let stored else {
            guard writer.major <= writer.alphaImportMajor + 1 else { throw StorageSchemaError.unsupported("expired alpha import") }
            return
        }
        guard stored.format == format, (1...currentSchema).contains(stored.schemaVersion),
              !stored.product.isEmpty, StorageProduct(product: stored.product, appVersion: stored.writtenByAppVersion).major >= 0 else {
            throw StorageSchemaError.unsupported("\(stored.format) schema \(stored.schemaVersion)")
        }
        if stored.schemaVersion < currentSchema, stored.product == writer.product {
            let origin = StorageProduct(product: stored.product, appVersion: stored.writtenByAppVersion).major
            guard origin >= max(0, writer.major - 1) else { throw StorageSchemaError.unsupported("expired app-major \(origin) migration") }
        }
    }

    public func payload(from data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = object as? [String: Any], let raw = root["storageMetadata"] else {
            try validate(nil)
            return data
        }
        let header = try JSONSerialization.data(withJSONObject: raw)
        let stored = try JSONDecoder().decode(StorageMetadata.self, from: header)
        try validate(stored)
        guard let value = root["value"] else { throw StorageSchemaError.unsupported("missing payload") }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    public func wrap(_ payload: Data) throws -> Data {
        let header = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))
        let value = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: ["storageMetadata": header, "value": value], options: [.sortedKeys])
    }

    /// Check the destination, not just the caller's previously loaded copy.
    /// A failed read must never turn into an empty state that overwrites it.
    public func checkDestination(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { _ = try payload(from: Data(contentsOf: url)) }
    }

    /// Flat editor/Classifier documents retain their public keys. Metadata is
    /// additive; it never enters an enforcement projection or a wire frame.
    public func validateFlat(_ root: [String: Any]) throws {
        if let rawVersion = root["schemaVersion"] {
            guard let data = try? JSONSerialization.data(withJSONObject: rawVersion, options: [.fragmentsAllowed]),
                  let version = try? JSONDecoder().decode(Int.self, from: data),
                  (0...currentSchema).contains(version) else {
                throw StorageSchemaError.unsupported("invalid or newer \(format) schema")
            }
        }
        if let raw = root["storageMetadata"] {
            let header = try JSONSerialization.data(withJSONObject: raw)
            let stored = try JSONDecoder().decode(StorageMetadata.self, from: header)
            guard (root["schemaVersion"] as? Int) == stored.schemaVersion else {
                throw StorageSchemaError.unsupported("inconsistent schema metadata")
            }
            try validate(stored)
        } else {
            try validate(nil)
        }
    }

    public func stampFlat(_ root: [String: Any]) throws -> [String: Any] {
        try validateFlat(root)
        var next = root
        next["schemaVersion"] = currentSchema
        next["storageMetadata"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))
        return next
    }
}
