import Foundation
import os

private let log = Logger(subsystem: "com.copilot.sdk", category: "project-task")

/// Handles create_project_request delegation from the relay server.
/// Performs GitHub operations via the relay's /github/* proxy,
/// then sends create_project_done back via WebSocket.
public final class ProjectTaskHandler {
    
    /// Base URL for the relay HTTP server (e.g., http://host:8766 or https://relay.domain)
    private let proxyBaseURL: URL
    
    /// Callback to send a JSON-RPC notification back to the relay via WebSocket.
    private let sendNotification: (String, [String: JSONValue]) async -> Void
    
    /// GitHub org for project creation.
    private let githubOrg: String
    
    /// Template repo name.
    private let templateRepo: String
    
    /// Expo owner for app.json.
    private let expoOwner: String
    
    public init(
        proxyBaseURL: URL,
        githubOrg: String = "neos-apps",
        templateRepo: String = "expo-app-template",
        expoOwner: String = "neos-apps",
        sendNotification: @escaping (String, [String: JSONValue]) async -> Void
    ) {
        self.proxyBaseURL = proxyBaseURL
        self.githubOrg = githubOrg
        self.templateRepo = templateRepo
        self.expoOwner = expoOwner
        self.sendNotification = sendNotification
    }
    
    /// Derive the relay HTTP base URL from a WebSocket URL.
    /// ws://host:8765 → http://host:8766 (port + 1)
    /// wss://host:443 → https://host (same host, Caddy routes /github/)
    public static func httpURL(from wsURL: URL) -> URL {
        let isSecure = wsURL.scheme == "wss"
        let httpScheme = isSecure ? "https" : "http"
        let host = wsURL.host ?? "localhost"
        let wsPort = wsURL.port ?? (isSecure ? 443 : 8765)
        
        if isSecure && wsPort == 443 {
            // Production: Caddy handles routing, same host
            return URL(string: "\(httpScheme)://\(host)")!
        } else {
            // Local dev: HTTP is on WS port + 1
            return URL(string: "\(httpScheme)://\(host):\(wsPort + 1)")!
        }
    }
    
    // MARK: - Handle Delegation
    
    /// Handle a create_project_request notification from the relay.
    /// Performs GitHub operations via /github/* proxy, then reports done.
    public func handleCreateProjectRequest(params: [String: JSONValue]) async {
        guard case .string(let requestId) = params["requestId"],
              case .string(let repoName) = params["repoName"],
              case .string(let appName) = params["appName"] else {
            log.error("create_project_request missing required params")
            await sendDone(requestId: "unknown", error: "Missing required params (requestId, repoName, appName)")
            return
        }
        
        let taskDescription: String
        if case .string(let td) = params["taskDescription"] { taskDescription = td } else { taskDescription = "" }
        
        let bundleId: String
        if case .string(let bi) = params["bundleId"] { bundleId = bi } else { bundleId = "" }
        
        log.info("Handling create_project_request: \(repoName) (\(appName))")
        
        do {
            // 1. Create repo from template
            let createRes = try await githubProxy(
                "POST",
                "/repos/\(githubOrg)/\(templateRepo)/generate",
                body: [
                    "owner": githubOrg,
                    "name": repoName,
                    "description": appName,
                    "private": false,
                    "include_all_branches": false,
                ] as [String: Any]
            )
            
            guard createRes.status == 201 else {
                throw ProjectTaskError.repoCreation(status: createRes.status, body: createRes.text)
            }
            
            log.info("Repo created: \(self.githubOrg)/\(repoName)")
            
            // 2. Wait for repo to be ready (template generation is async)
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3s
            
            // 3. Customize app.json
            try await customizeAppJson(repoName: repoName, appName: appName, bundleId: bundleId)
            
            // 4. Create issue with task spec
            let issueNumber = try await createIssue(
                repoName: repoName,
                appName: appName,
                taskDescription: taskDescription
            )
            
            log.info("Project created: \(self.githubOrg)/\(repoName) issue #\(issueNumber)")
            
            // 5. Report done
            await sendDone(
                requestId: requestId,
                repo: "\(githubOrg)/\(repoName)",
                issueNumber: issueNumber
            )
            
        } catch {
            log.error("create_project_request failed: \(error.localizedDescription)")
            await sendDone(requestId: requestId, error: error.localizedDescription)
        }
    }
    
    // MARK: - GitHub Operations
    
    private func customizeAppJson(repoName: String, appName: String, bundleId: String) async throws {
        // Fetch current app.json
        let getRes = try await githubProxy("GET", "/repos/\(githubOrg)/\(repoName)/contents/app.json")
        guard getRes.status == 200 else { return }
        
        guard let json = getRes.json as? [String: Any],
              let contentBase64 = json["content"] as? String,
              let sha = json["sha"] as? String,
              let contentData = Data(base64Encoded: contentBase64.replacingOccurrences(of: "\n", with: "")),
              let contentStr = String(data: contentData, encoding: .utf8),
              var appJson = try? JSONSerialization.jsonObject(with: Data(contentStr.utf8)) as? [String: Any],
              var expo = appJson["expo"] as? [String: Any] else { return }
        
        expo["name"] = appName
        expo["slug"] = repoName
        expo["owner"] = expoOwner
        
        if var ios = expo["ios"] as? [String: Any] {
            ios["bundleIdentifier"] = bundleId
            expo["ios"] = ios
        }
        if var android = expo["android"] as? [String: Any] {
            android["package"] = bundleId
            expo["android"] = android
        }
        
        appJson["expo"] = expo
        
        let updatedData = try JSONSerialization.data(withJSONObject: appJson, options: [.prettyPrinted, .sortedKeys])
        let updatedBase64 = updatedData.base64EncodedString()
        
        _ = try await githubProxy("PUT", "/repos/\(githubOrg)/\(repoName)/contents/app.json", body: [
            "message": "chore: configure app for \(appName)",
            "content": updatedBase64,
            "sha": sha,
        ])
        
        log.info("app.json customized for \(appName)")
    }
    
    private func createIssue(repoName: String, appName: String, taskDescription: String) async throws -> Int {
        let issueBody = """
        ## Goal
        \(taskDescription)
        
        ## Constraints
        - Expo SDK 55+, React Native, TypeScript
        - No ejecting from managed workflow
        - Keep it simple and working
        
        ## Validation
        - [ ] `npx tsc --noEmit` passes
        - [ ] App renders correctly on iOS
        """
        
        let res = try await githubProxy("POST", "/repos/\(githubOrg)/\(repoName)/issues", body: [
            "title": appName,
            "body": issueBody,
            "labels": ["enhancement"],
        ] as [String : Any])
        
        guard res.status == 201,
              let json = res.json as? [String: Any],
              let number = json["number"] as? Int else {
            throw ProjectTaskError.issueCreation(status: res.status, body: res.text)
        }
        
        return number
    }
    
    // MARK: - GitHub Proxy
    
    private struct ProxyResponse {
        let status: Int
        let data: Data
        let text: String
        var json: Any? { try? JSONSerialization.jsonObject(with: data) }
    }
    
    private func githubProxy(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> ProxyResponse {
        let url = proxyBaseURL.appendingPathComponent("github").appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        let text = String(data: data, encoding: .utf8) ?? ""
        
        return ProxyResponse(status: httpResponse.statusCode, data: data, text: text)
    }
    
    // MARK: - Response
    
    private func sendDone(requestId: String, repo: String? = nil, issueNumber: Int? = nil, error: String? = nil) async {
        var params: [String: JSONValue] = ["requestId": .string(requestId)]
        if let repo { params["repo"] = .string(repo) }
        if let issueNumber { params["issueNumber"] = .int(issueNumber) }
        if let error { params["error"] = .string(error) }
        
        await sendNotification("create_project_done", params)
    }
}

// MARK: - Errors

enum ProjectTaskError: LocalizedError {
    case repoCreation(status: Int, body: String)
    case issueCreation(status: Int, body: String)
    
    var errorDescription: String? {
        switch self {
        case .repoCreation(let status, let body):
            return "Repo creation failed (HTTP \(status)): \(body.prefix(200))"
        case .issueCreation(let status, let body):
            return "Issue creation failed (HTTP \(status)): \(body.prefix(200))"
        }
    }
}
