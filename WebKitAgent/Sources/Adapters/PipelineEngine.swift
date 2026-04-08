import Foundation

/// Executes YAML adapter pipelines: fetch, slice, filter, map, fetchEach.
@MainActor
public final class PipelineEngine {

    public init() {}

    // MARK: - Execute Pipeline

    /// Execute a full pipeline on the given adapter with arguments.
    public func execute(
        pipeline: [PipelineStep],
        args: [String: String]
    ) async throws -> [Any] {
        var data: [Any] = []

        for step in pipeline {
            switch step {
            case .fetch(let urlStr):
                let resolvedURL = resolveURLTemplate(urlStr, item: nil, args: args)
                data = try await fetchJSON(resolvedURL)

            case .slice(let from, let to):
                data = executeSlice(data: data, from: from, to: to)

            case .fetchEach(let template):
                data = try await executeFetchEach(data: data, template: template, args: args)

            case .filter(let expression):
                data = executeFilter(data: data, expression: expression)

            case .map(let mapping):
                data = executeMap(data: data, mapping: mapping)

            case .extract(let path):
                data = executeExtract(data: data, path: path)
            }
        }

        return data
    }

    // MARK: - Extract

    public func executeExtract(data: [Any], path: String) -> [Any] {
        let keys = path.components(separatedBy: ".")
        var results: [Any] = []
        for item in data {
            let value = navigatePath(item, keys: keys)
            if let array = value as? [Any] {
                results.append(contentsOf: array)
            } else if let value = value {
                results.append(value)
            }
        }
        return results
    }

    private func navigatePath(_ value: Any, keys: [String]) -> Any? {
        var current: Any = value
        for key in keys {
            if let dict = current as? [String: Any], let next = dict[key] {
                current = next
            } else if let array = current as? [Any], let index = Int(key), index < array.count {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    // MARK: - Fetch

    private func fetchJSON(_ urlString: String) async throws -> [Any] {
        guard let url = URL(string: urlString) else {
            throw PipelineError.invalidURL(urlString)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data)
        if let array = json as? [Any] {
            return array
        } else {
            return [json]
        }
    }

    // MARK: - Slice

    public func executeSlice(data: [Any], from: Int, to: Int?) -> [Any] {
        let start = min(from, data.count)
        let end = min(to ?? data.count, data.count)
        if start >= end { return [] }
        return Array(data[start..<end])
    }

    // MARK: - FetchEach

    private func executeFetchEach(data: [Any], template: String, args: [String: String]) async throws -> [Any] {
        var results: [Any] = []
        for item in data {
            let urlStr = resolveURLTemplate(template, item: item, args: args)
            if let url = URL(string: urlStr) {
                do {
                    let (fetchedData, _) = try await URLSession.shared.data(from: url)
                    if let json = try? JSONSerialization.jsonObject(with: fetchedData) {
                        results.append(json)
                    }
                } catch {
                    // Skip failed fetches
                    continue
                }
            }
        }
        return results
    }

    // MARK: - Filter

    public func executeFilter(data: [Any], expression: String) -> [Any] {
        data.filter { item in
            evaluateFilterExpression(expression, item: item)
        }
    }

    private func evaluateFilterExpression(_ expression: String, item: Any) -> Bool {
        let expr = expression.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        // Compound expressions with && (must be checked first)
        if expr.contains("&&") {
            let parts = expr.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.allSatisfy { evaluateFilterExpression($0, item: item) }
        }

        // item.key != nil
        if expr.hasSuffix("!= nil") {
            let keyPath = expr.replacingOccurrences(of: " != nil", with: "")
                .replacingOccurrences(of: "item.", with: "")
            if let dict = item as? [String: Any] {
                return dict[keyPath] != nil
            }
            return false
        }

        // item.key == nil
        if expr.hasSuffix("== nil") {
            let keyPath = expr.replacingOccurrences(of: " == nil", with: "")
                .replacingOccurrences(of: "item.", with: "")
            if let dict = item as? [String: Any] {
                return dict[keyPath] == nil
            }
            return true
        }

        // !item.key (falsy check)
        if expr.hasPrefix("!item.") {
            let key = String(expr.dropFirst(6))
            if let dict = item as? [String: Any] {
                if let boolVal = dict[key] as? Bool {
                    return !boolVal
                }
                return dict[key] == nil
            }
            return true
        }

        // Default: true (unknown expressions pass)
        return true
    }

    // MARK: - Map

    public func executeMap(data: [Any], mapping: [String: String]) -> [Any] {
        data.enumerated().map { (index, item) in
            var result: [String: Any] = [:]
            let itemDict = item as? [String: Any] ?? [:]
            for (key, template) in mapping {
                result[key] = evaluateTemplate(template, item: itemDict, index: index, args: [:])
            }
            return result
        }
    }

    // MARK: - Template Evaluation

    /// Evaluate a template like `${{ item.title }}` or `${{ index + 1 }}`.
    public func evaluateTemplate(_ template: String, item: [String: Any], index: Int, args: [String: String]) -> Any {
        let trimmed = template.trimmingCharacters(in: .whitespaces)

        // Check for ${{ ... }} pattern
        guard trimmed.hasPrefix("${{") && trimmed.hasSuffix("}}") else {
            return trimmed
        }

        let expr = String(trimmed.dropFirst(3).dropLast(2)).trimmingCharacters(in: .whitespaces)

        // index + N
        if expr.hasPrefix("index") {
            if expr.contains("+") {
                let parts = expr.components(separatedBy: "+")
                if parts.count == 2, let offset = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    return index + offset
                }
            }
            return index
        }

        // args.key
        if expr.hasPrefix("args.") {
            let key = String(expr.dropFirst(5))
            return args[key] as Any
        }

        // item.key or item.key.nested
        if expr.hasPrefix("item.") {
            let keyPath = String(expr.dropFirst(5))
            let keys = keyPath.components(separatedBy: ".")
            var current: Any = item
            for key in keys {
                if let dict = current as? [String: Any], let next = dict[key] {
                    current = next
                } else {
                    return template as Any
                }
            }
            return current
        }

        // item (the whole item)
        if expr == "item" {
            return item
        }

        return template
    }

    // MARK: - URL Template Resolution

    /// Resolve a URL template, replacing `${{ item }}`, `${{ item.id }}`, `${{ args.key }}`.
    public func resolveURLTemplate(_ template: String, item: Any?, args: [String: String]) -> String {
        var result = template

        // Replace ${{ item.key }}
        let itemPropertyPattern = try? NSRegularExpression(pattern: #"\$\{\{\s*item\.(\w+)\s*\}\}"#)
        if let regex = itemPropertyPattern {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                let key = String(result[Range(match.range(at: 1), in: result)!])
                var replacement = ""
                if let dict = item as? [String: Any], let val = dict[key] {
                    replacement = "\(val)"
                }
                result = result.replacingCharacters(in: Range(match.range, in: result)!, with: replacement)
            }
        }

        // Replace ${{ item }}
        let itemPattern = try? NSRegularExpression(pattern: #"\$\{\{\s*item\s*\}\}"#)
        if let regex = itemPattern {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                let replacement = "\(item ?? "")"
                result = result.replacingCharacters(in: Range(match.range, in: result)!, with: replacement)
            }
        }

        // Replace ${{ args.key }}
        let argsPattern = try? NSRegularExpression(pattern: #"\$\{\{\s*args\.(\w+)\s*\}\}"#)
        if let regex = argsPattern {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                let key = String(result[Range(match.range(at: 1), in: result)!])
                let replacement = args[key] ?? ""
                result = result.replacingCharacters(in: Range(match.range, in: result)!, with: replacement)
            }
        }

        return result
    }

    // MARK: - Format Output

    /// Format pipeline results as a readable string for the LLM.
    public static func formatOutput(_ data: [Any]) -> String {
        if data.isEmpty {
            return "No results."
        }

        // Priority ordering for common fields
        let priorityKeys = ["rank", "title", "name", "url", "score", "author", "status", "message", "error"]

        var lines: [String] = []
        for (i, item) in data.enumerated() {
            if let dict = item as? [String: Any] {
                let keys = dict.keys.sorted { a, b in
                    let ai = priorityKeys.firstIndex(of: a) ?? priorityKeys.count
                    let bi = priorityKeys.firstIndex(of: b) ?? priorityKeys.count
                    return ai == bi ? a < b : ai < bi
                }
                let pairs = keys.map { "\($0): \(dict[$0]!)" }.joined(separator: " | ")
                lines.append("\(i + 1). \(pairs)")
            } else {
                lines.append("\(i + 1). \(item)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Pipeline Error

public enum PipelineError: Error, LocalizedError {
    case invalidURL(String)
    case fetchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid pipeline URL: \(url)"
        case .fetchFailed(let reason): return "Pipeline fetch failed: \(reason)"
        }
    }
}
