import Foundation

/// Filesystem broker for custom rules. Every path is relative to one managed
/// folder and the response uses string fields so it can cross the native JS
/// bridge unchanged.
public struct LocalFileBroker {
    public static let maximumBytes = 1024 * 1024

    private static let allowedExtensions: Set<String> = ["txt", "csv", "json"]
    private static let allowedPathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _.,@()-")

    private let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL.standardizedFileURL
        try? FileManager.default.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
    }

    public func handle(action: String, path: String, text: String?, requestID: String) -> [String: String] {
        var response = responseBase(action: action, path: path, requestID: requestID)

        do {
            switch action {
            case "read", "readJson":
                let fileURL = try resolveFile(path)
                let data = try readLimitedData(at: fileURL)
                guard let fileText = String(data: data, encoding: .utf8) else {
                    throw LocalFileError.invalidText
                }
                if action == "readJson" {
                    try validateJSON(data)
                    response["valueJSON"] = fileText
                }
                response["eventName"] = "read"
                response["text"] = fileText
                response["bytes"] = String(data.count)

            case "write", "writeJson":
                let fileURL = try resolveFile(path)
                let fileText = text ?? ""
                let data = Data(fileText.utf8)
                if action == "writeJson" {
                    try validateJSON(data)
                }
                try enforceSize(data.count)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                response["eventName"] = "write"
                response["bytes"] = String(data.count)

            case "append":
                let fileURL = try resolveFile(path)
                var data = Data()
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    data = try readLimitedData(at: fileURL)
                }
                data.append(Data((text ?? "").utf8))
                try enforceSize(data.count)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                response["eventName"] = "append"
                response["bytes"] = String(data.count)

            case "list":
                let directoryPath = try normalizePath(path, allowsDirectory: true)
                let directoryURL = try resolve(directoryPath)
                let contents = try FileManager.default.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                var entries: [[String: String]] = []
                for item in contents {
                    let name = item.lastPathComponent
                    guard !name.isEmpty, !name.hasPrefix(".") else { continue }
                    let values = try item.resourceValues(forKeys: [.isDirectoryKey])
                    let entryPath = directoryPath.isEmpty ? name : directoryPath + "/" + name
                    if values.isDirectory == true {
                        entries.append(["name": name, "path": entryPath, "kind": "directory"])
                    } else if Self.allowedExtensions.contains(item.pathExtension.lowercased()) {
                        entries.append([
                            "name": name,
                            "path": entryPath,
                            "kind": "file",
                            "extension": "." + item.pathExtension.lowercased()
                        ])
                    }
                }
                entries.sort {
                    let leftKind = $0["kind"] ?? ""
                    let rightKind = $1["kind"] ?? ""
                    if leftKind != rightKind { return leftKind < rightKind }
                    return ($0["name"] ?? "") < ($1["name"] ?? "")
                }
                let entriesData = try JSONSerialization.data(withJSONObject: entries)
                response["eventName"] = "list"
                response["directoryPath"] = directoryPath
                response["entriesJSON"] = String(decoding: entriesData, as: UTF8.self)

            case "exists":
                let fileURL = try resolveFile(path)
                response["eventName"] = "exists"
                response["exists"] = FileManager.default.fileExists(atPath: fileURL.path) ? "true" : "false"

            default:
                throw LocalFileError.unsupportedAction
            }
            response["ok"] = "true"
        } catch let error as LocalFileError {
            response["eventName"] = "error"
            response["error"] = error.rawValue
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            response["eventName"] = "error"
            response["error"] = "not-found"
        } catch {
            response["eventName"] = "error"
            response["error"] = "local-file-error"
        }

        return response
    }

    private func responseBase(action: String, path: String, requestID: String) -> [String: String] {
        [
            "ok": "false",
            "eventName": action,
            "action": action,
            "path": path,
            "directoryPath": "",
            "requestId": requestID
        ]
    }

    private func resolveFile(_ path: String) throws -> URL {
        let normalized = try normalizePath(path, allowsDirectory: false)
        let url = try resolve(normalized)
        guard Self.allowedExtensions.contains(url.pathExtension.lowercased()) else {
            throw LocalFileError.unsupportedFileType
        }
        return url
    }

    private func normalizePath(_ relativePath: String, allowsDirectory: Bool) throws -> String {
        let raw = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: #"/+"#, with: "/", options: .regularExpression)
            .replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)

        if raw.isEmpty, allowsDirectory {
            return ""
        }
        guard !raw.isEmpty,
              !raw.hasPrefix("/"),
              raw.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) == nil,
              raw.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil else {
            throw LocalFileError.invalidPath
        }

        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { throw LocalFileError.invalidPath }
        for part in parts {
            guard part != ".",
                  part != "..",
                  !part.hasPrefix("."),
                  part.unicodeScalars.allSatisfy(Self.allowedPathCharacters.contains) else {
                throw LocalFileError.invalidPath
            }
        }
        return parts.joined(separator: "/")
    }

    private func resolve(_ normalizedPath: String) throws -> URL {
        var resolved = baseURL
        if !normalizedPath.isEmpty {
            for component in normalizedPath.split(separator: "/") {
                resolved.appendPathComponent(String(component), isDirectory: false)
            }
        }
        resolved = resolved.standardizedFileURL
        let basePath = baseURL.path
        guard resolved.path == basePath || resolved.path.hasPrefix(basePath + "/") else {
            throw LocalFileError.invalidPath
        }
        return resolved
    }

    private func readLimitedData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        try enforceSize(values.fileSize ?? 0)
        let data = try Data(contentsOf: url)
        try enforceSize(data.count)
        return data
    }

    private func enforceSize(_ byteCount: Int) throws {
        guard byteCount <= Self.maximumBytes else { throw LocalFileError.fileTooLarge }
    }

    private func validateJSON(_ data: Data) throws {
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            throw LocalFileError.invalidJson
        }
    }

    private enum LocalFileError: String, Error {
        case invalidPath = "invalid-path"
        case unsupportedFileType = "unsupported-file-type"
        case unsupportedAction = "unsupported-action"
        case invalidJson = "invalid-json"
        case invalidText = "invalid-text"
        case fileTooLarge = "file-too-large"
    }
}
