import Foundation

// MARK: - Auth Strategy

/// How the adapter authenticates with the site.
public enum AuthStrategy: Equatable, Sendable {
    case none
    case cookie(domain: String)
    case header(name: String, value: String)
}

// MARK: - Adapter Argument

/// Describes a parameter that an adapter accepts.
public struct AdapterArg: Sendable {
    public let name: String
    public let type: ArgType
    public let defaultValue: String?
    public let description: String?

    public enum ArgType: String, Sendable {
        case string
        case int
        case bool
    }

    public init(name: String, type: ArgType, defaultValue: String? = nil, description: String? = nil) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.description = description
    }
}

// MARK: - Pipeline Step

/// A single step in a YAML adapter pipeline.
public enum PipelineStep: Sendable {
    /// Fetch a URL and store the JSON result.
    case fetch(String)
    /// Slice the array: keep items from `from` to `to`.
    case slice(from: Int, to: Int?)
    /// Fetch each item's URL in parallel.
    case fetchEach(String)
    /// Filter items using an expression.
    case filter(String)
    /// Map items to a new shape.
    case map([String: String])
    /// Extract a nested path from each item. If the result is an array, flatten it.
    case extract(String)
}

// MARK: - Parse Error

public enum AdapterParseError: Error, LocalizedError {
    case invalidFormat(String)
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return "Invalid adapter format: \(msg)"
        case .missingField(let field): return "Missing required field: \(field)"
        }
    }
}

// MARK: - YAML Adapter

/// A site adapter parsed from a YAML-like definition string.
/// Uses a simple key-value parser (no external YAML dependency).
public struct YAMLAdapter: Sendable {
    public let site: String
    public let name: String
    public let adapterDescription: String
    public let auth: AuthStrategy
    public let requiresBrowser: Bool
    public let args: [AdapterArg]
    public let pipeline: [PipelineStep]

    // Browser-based adapter fields
    public let preNavigate: String?
    public let waitSeconds: Int?
    public let script: String?
    public let domain: String?

    // MARK: - Parse

    /// Parse a YAML-like adapter definition string.
    public static func parse(_ text: String) throws -> YAMLAdapter {
        let lines = text.components(separatedBy: "\n")
        var fields: [String: String] = [:]
        var argsBlock: [String: [String: String]] = [:]
        var pipelineSteps: [PipelineStep] = []
        var scriptLines: [String] = []
        var currentSection: String?
        var currentArgName: String?
        var inScript = false
        var scriptIndent = 0

        for line in lines {
            // Handle script block (multi-line)
            if inScript {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let lineIndent = line.prefix(while: { $0 == " " }).count
                if lineIndent >= scriptIndent && !trimmed.isEmpty {
                    scriptLines.append(trimmed)
                    continue
                } else if trimmed.isEmpty {
                    scriptLines.append("")
                    continue
                } else {
                    inScript = false
                    // fall through to parse this line normally
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            // Top-level field
            if indent == 0, let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

                if key == "args" {
                    currentSection = "args"
                    currentArgName = nil
                    continue
                } else if key == "pipeline" {
                    currentSection = "pipeline"
                    continue
                } else if key == "script" && value.hasSuffix("|") {
                    inScript = true
                    scriptIndent = 2
                    currentSection = nil
                    continue
                }

                currentSection = nil
                fields[key] = value
                continue
            }

            // Args section
            if currentSection == "args" {
                if indent == 2, let colonIdx = trimmed.firstIndex(of: ":") {
                    let argName = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    currentArgName = argName
                    argsBlock[argName] = [:]
                } else if indent >= 4, let argName = currentArgName,
                          let colonIdx = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                    argsBlock[argName, default: [:]][key] = value
                }
                continue
            }

            // Pipeline section
            if currentSection == "pipeline" {
                if trimmed.hasPrefix("- ") {
                    let stepStr = String(trimmed.dropFirst(2))
                    if let step = parsePipelineStep(stepStr) {
                        pipelineSteps.append(step)
                    }
                }
                continue
            }
        }

        // Validate required fields
        guard let site = fields["site"], !site.isEmpty else {
            throw AdapterParseError.missingField("site")
        }
        guard let name = fields["name"], !name.isEmpty else {
            throw AdapterParseError.missingField("name")
        }

        let description = fields["description"] ?? ""
        let requiresBrowser = fields["requiresBrowser"] == "true"
        let domainStr = fields["domain"]

        // Parse auth
        let auth: AuthStrategy
        switch fields["auth"] {
        case "cookie":
            auth = .cookie(domain: domainStr ?? site)
        case "header":
            auth = .header(name: "Authorization", value: "")
        default:
            auth = .none
        }

        // Parse args
        let adapterArgs = argsBlock.map { (argName, props) in
            let type = AdapterArg.ArgType(rawValue: props["type"] ?? "string") ?? .string
            return AdapterArg(
                name: argName,
                type: type,
                defaultValue: props["default"],
                description: props["description"]
            )
        }.sorted(by: { $0.name < $1.name })

        // Script
        let scriptStr = scriptLines.isEmpty ? nil : scriptLines.joined(separator: "\n")

        return YAMLAdapter(
            site: site,
            name: name,
            adapterDescription: description,
            auth: auth,
            requiresBrowser: requiresBrowser,
            args: adapterArgs,
            pipeline: pipelineSteps,
            preNavigate: fields["preNavigate"],
            waitSeconds: fields["waitSeconds"].flatMap { Int($0) },
            script: scriptStr,
            domain: domainStr
        )
    }

    // MARK: - Pipeline Step Parsing

    private static func parsePipelineStep(_ text: String) -> PipelineStep? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // fetch: URL
        if trimmed.hasPrefix("fetch:") {
            let url = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return .fetch(url)
        }

        // fetchEach: URL template
        if trimmed.hasPrefix("fetchEach:") {
            let template = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return .fetchEach(template)
        }

        // slice: { to: N } or { from: N, to: N }
        if trimmed.hasPrefix("slice:") {
            let body = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .trimmingCharacters(in: .whitespaces)
            var from = 0
            var to: Int?
            for part in body.components(separatedBy: ",") {
                let kv = part.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 {
                    let key = kv[0]
                    let val = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if key == "to" {
                        to = Int(val)
                    } else if key == "from" {
                        from = Int(val) ?? 0
                    }
                }
            }
            return .slice(from: from, to: to)
        }

        // filter: expression
        if trimmed.hasPrefix("filter:") {
            let expr = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return .filter(expr)
        }

        // map: { key: expr, ... }
        if trimmed.hasPrefix("map:") {
            let body = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            return .map(parseMapBody(body))
        }

        // extract: path.to.nested.field
        if trimmed.hasPrefix("extract:") {
            let path = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return .extract(path)
        }

        return nil
    }

    /// Parse a map body like `{ title: "${{ item.title }}", score: "${{ item.score }}" }`
    private static func parseMapBody(_ text: String) -> [String: String] {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).trimmingCharacters(in: .whitespaces)
        var result: [String: String] = [:]
        // Split on comma, but respect quoted strings
        var parts: [String] = []
        var current = ""
        var depth = 0
        for char in body {
            if char == "{" { depth += 1 }
            if char == "}" { depth -= 1 }
            if char == "," && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { parts.append(current) }

        for part in parts {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 {
                let key = kv[0]
                let value = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                result[key] = value
            }
        }
        return result
    }
}
