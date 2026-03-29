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
            }
        }

        return data
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

        // Compound expressions with &&
        if expr.contains("&&") {
            let parts = expr.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.allSatisfy { evaluateFilterExpression($0, item: item) }
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

        // item.key
        if expr.hasPrefix("item.") {
            let key = String(expr.dropFirst(5))
            return item[key] as Any
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

        var lines: [String] = []
        for (i, item) in data.enumerated() {
            if let dict = item as? [String: Any] {
                let pairs = dict.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: " | ")
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
