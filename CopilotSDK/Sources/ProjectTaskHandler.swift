import Foundation
import os

private let log = Logger(subsystem: "com.copilot.sdk", category: "project-task")

/// Handles create_project_request delegation from the relay server.
/// Creates repo, pushes template files from device, creates issue,
/// then sends create_project_done back via WebSocket.
public final class ProjectTaskHandler {
    
    /// Base URL for the relay HTTP server (e.g., http://host:8766 or https://relay.domain)
    private let proxyBaseURL: URL
    
    /// Callback to send a JSON-RPC notification back to the relay via WebSocket.
    private let sendNotification: (String, [String: JSONValue]) async -> Void
    
    /// GitHub org for project creation.
    private let githubOrg: String
    
    /// Expo owner for app.json.
    private let expoOwner: String
    
    /// Workspace directory on device (to read .templates/).
    private let workspaceURL: URL
    
    public init(
        proxyBaseURL: URL,
        workspaceURL: URL,
        githubOrg: String = "neos-apps",
        expoOwner: String = "neos-apps",
        sendNotification: @escaping (String, [String: JSONValue]) async -> Void
    ) {
        self.proxyBaseURL = proxyBaseURL
        self.workspaceURL = workspaceURL
        self.githubOrg = githubOrg
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
    
    // MARK: - Tool handler (agent flow)

    /// Create a project: repo + template files + issue.
    /// Called as a tool handler when the agent calls start_coding_task.
    /// Returns a JSON string with {repo, issueNumber} for the relay to parse and run activation.
    public func createProject(appName: String, taskDescription: String, model: String = "") async -> String {
        let slug = Self.slugify(appName)
        let id = Self.shortId()
        let repoName = "\(slug)-\(id)"
        let bundleId = "com.neos.\(slug.replacingOccurrences(of: "-", with: ""))\(id)"

        NSLog("[ProjectTaskHandler] createProject: %@ → %@", appName, repoName)

        do {
            // 1. Read template files from device
            let files = try readTemplateFiles(projectType: "expo-app", appName: appName, repoName: repoName, bundleId: bundleId)
            NSLog("[ProjectTaskHandler] Read %d template files", files.count)

            // 2. Create repo
            let createRes = try await githubProxy(
                "POST",
                "/orgs/\(githubOrg)/repos",
                body: [
                    "name": repoName,
                    "description": appName,
                    "private": false,
                    "auto_init": true,
                ] as [String: Any]
            )
            guard createRes.status == 201 else {
                return "Error: Repo creation failed (HTTP \(createRes.status)): \(createRes.text.prefix(200))"
            }

            // 3. Push template files via Git Trees API
            try await pushFilesViaGitTrees(repoName: repoName, appName: appName, files: files)

            // 3b. Update package.json in existing scaffold directory (or create new one)
            let scaffoldDir = workspaceURL.appendingPathComponent(slug, isDirectory: true)
            let projectDir: URL
            if FileManager.default.fileExists(atPath: scaffoldDir.path) {
                projectDir = scaffoldDir
            } else {
                projectDir = workspaceURL.appendingPathComponent(repoName, isDirectory: true)
                try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            }
            let localPkg: [String: Any] = [
                "name": repoName, "displayName": appName, "description": taskDescription,
                "repo": "\(githubOrg)/\(repoName)", "bundleId": bundleId, "projectType": "expo-app",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: localPkg, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: projectDir.appendingPathComponent("package.json"))
            }

            // 4. Create issue
            let issueNumber = try await createIssue(repoName: repoName, appName: appName, taskDescription: taskDescription)

            NSLog("[ProjectTaskHandler] Project created: %@/%@ issue #%d", githubOrg, repoName, issueNumber)
            // Return JSON so relay can parse repo + issueNumber for activation
            return "{\"repo\":\"\(githubOrg)/\(repoName)\",\"issueNumber\":\(issueNumber),\"bundleId\":\"\(bundleId)\"}"
        } catch {
            NSLog("[ProjectTaskHandler] createProject failed: %@", error.localizedDescription)
            return "Error: \(error.localizedDescription)"
        }
    }

    private static func slugify(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private static func shortId() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<6).map { _ in chars.randomElement()! })
    }

    // MARK: - Handle Delegation (legacy)
    
    /// Handle a create_project_request notification from the relay.
    /// Creates repo, pushes template files from device, creates issue, reports done.
    public func handleCreateProjectRequest(params: [String: JSONValue]) async {
        NSLog("[ProjectTaskHandler] handleCreateProjectRequest called with %d params", params.count)
        guard case .string(let requestId) = params["requestId"],
              case .string(let repoName) = params["repoName"],
              case .string(let appName) = params["appName"] else {
            NSLog("[ProjectTaskHandler] Missing required params!")
            log.error("create_project_request missing required params")
            await sendDone(requestId: "unknown", error: "Missing required params (requestId, repoName, appName)")
            return
        }
        
        NSLog("[ProjectTaskHandler] requestId=%@, repoName=%@, appName=%@", requestId, repoName, appName)
        
        let taskDescription: String
        if case .string(let td) = params["taskDescription"] { taskDescription = td } else { taskDescription = "" }
        
        let bundleId: String
        if case .string(let bi) = params["bundleId"] { bundleId = bi } else { bundleId = "" }
        
        let projectType: String
        if case .string(let pt) = params["projectType"] { projectType = pt } else { projectType = "expo-app" }
        
        log.info("Handling create_project_request: \(repoName) (\(appName)) type=\(projectType)")
        NSLog("[ProjectTaskHandler] proxyBaseURL=%@", proxyBaseURL.absoluteString)
        
        do {
            // 1. Read template files from device
            NSLog("[ProjectTaskHandler] Step 1: Reading template files...")
            let files = try readTemplateFiles(projectType: projectType, appName: appName, repoName: repoName, bundleId: bundleId)
            NSLog("[ProjectTaskHandler] Step 1 done: %d files read", files.count)
            log.info("Read \(files.count) template files from device")
            
            // 2. Create repo with initial commit (auto_init enables Git Trees API)
            NSLog("[ProjectTaskHandler] Step 2: Creating repo %@...", repoName)
            let createRes = try await githubProxy(
                "POST",
                "/orgs/\(githubOrg)/repos",
                body: [
                    "name": repoName,
                    "description": appName,
                    "private": false,
                    "auto_init": true,
                ] as [String: Any]
            )
            
            guard createRes.status == 201 else {
                NSLog("[ProjectTaskHandler] Step 2 failed: status=%d body=%@", createRes.status, createRes.text)
                throw ProjectTaskError.repoCreation(status: createRes.status, body: createRes.text)
            }
            
            NSLog("[ProjectTaskHandler] Step 2 done: repo created")
            log.info("Repo created: \(self.githubOrg)/\(repoName)")
            
            // 3. Push all files via Git trees API
            NSLog("[ProjectTaskHandler] Step 3: Pushing files...")
            try await pushFilesViaGitTrees(repoName: repoName, appName: appName, files: files)
            NSLog("[ProjectTaskHandler] Step 3 done: files pushed")
            
            // 3b. Save package.json locally so the project is self-describing
            let projectDir = workspaceURL.appendingPathComponent(repoName, isDirectory: true)
            try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let localPkg: [String: Any] = [
                "name": repoName,
                "displayName": appName,
                "description": taskDescription,
                "repo": "\(githubOrg)/\(repoName)",
                "bundleId": bundleId,
                "projectType": projectType,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: localPkg, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: projectDir.appendingPathComponent("package.json"))
                NSLog("[ProjectTaskHandler] Saved local package.json for %@", repoName)
            }
            
            // 4. Create issue with task spec
            NSLog("[ProjectTaskHandler] Step 4: Creating issue...")
            let issueNumber = try await createIssue(
                repoName: repoName,
                appName: appName,
                taskDescription: taskDescription
            )
            
            NSLog("[ProjectTaskHandler] Step 4 done: issue #%d created", issueNumber)
            log.info("Project created: \(self.githubOrg)/\(repoName) issue #\(issueNumber)")
            
            // 5. Report done
            NSLog("[ProjectTaskHandler] Step 5: Sending done...")
            await sendDone(
                requestId: requestId,
                repo: "\(githubOrg)/\(repoName)",
                issueNumber: issueNumber
            )
            
        } catch {
            NSLog("[ProjectTaskHandler] FAILED: %@", error.localizedDescription)
            log.error("create_project_request failed: \(error.localizedDescription)")
            await sendDone(requestId: requestId, error: error.localizedDescription)
        }
    }
    
    // MARK: - Template Files
    
    private struct TemplateFile {
        let path: String
        let data: Data
        let isExecutable: Bool
    }
    
    /// Read and merge template files from device filesystem.
    /// Merges coding-agent-infra/ + projects/{projectType}/.
    private func readTemplateFiles(projectType: String, appName: String, repoName: String, bundleId: String) throws -> [TemplateFile] {
        let manager = FileManager.default
        let templatesDir = workspaceURL.appendingPathComponent(".templates", isDirectory: true)
        
        var files: [TemplateFile] = []
        
        // Read coding-agent-infra (always included)
        let infraDir = templatesDir.appendingPathComponent("coding-agent-infra", isDirectory: true)
        if manager.fileExists(atPath: infraDir.path) {
            files.append(contentsOf: try readDirectory(infraDir))
        }
        
        // Read project type template
        let projectDir = templatesDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectType, isDirectory: true)
        if manager.fileExists(atPath: projectDir.path) {
            files.append(contentsOf: try readDirectory(projectDir))
        }
        
        // Customize app.json and package.json in-memory
        return files.map { file in
            if file.path == "app.json", let customized = customizeAppJson(file.data, appName: appName, repoName: repoName, bundleId: bundleId) {
                return TemplateFile(path: file.path, data: customized, isExecutable: file.isExecutable)
            }
            if file.path == "package.json", let customized = customizePackageJson(file.data, repoName: repoName, appName: appName) {
                return TemplateFile(path: file.path, data: customized, isExecutable: file.isExecutable)
            }
            return file
        }
    }
    
    /// Recursively read all files from a directory, returning relative paths.
    private func readDirectory(_ dir: URL) throws -> [TemplateFile] {
        let manager = FileManager.default
        var result: [TemplateFile] = []
        
        guard let enumerator = manager.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isExecutableKey],
            options: []
        ) else { return result }
        
        // Resolve symlinks for consistent path comparison (iOS /var ↔ /private/var)
        let dirResolved = dir.resolvingSymlinksInPath().path
        
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isExecutableKey])
            if values.isDirectory == true { continue }
            
            let itemResolved = item.resolvingSymlinksInPath().path
            var relativePath = itemResolved.replacingOccurrences(of: dirResolved + "/", with: "")
            // Strip leading "/" if path replacement didn't fully resolve
            while relativePath.hasPrefix("/") { relativePath = String(relativePath.dropFirst()) }
            guard !relativePath.isEmpty, relativePath != itemResolved else { continue }
            log.info("Template file: \(relativePath) (dir: \(dir.lastPathComponent))")
            
            let data = try Data(contentsOf: item)
            let isExec = values.isExecutable == true && relativePath.hasSuffix(".sh")
            result.append(TemplateFile(path: relativePath, data: data, isExecutable: isExec))
        }
        
        return result
    }
    
    private func customizeAppJson(_ data: Data, appName: String, repoName: String, bundleId: String) -> Data? {
        guard var appJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var expo = appJson["expo"] as? [String: Any] else { return nil }
        
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
        return try? JSONSerialization.data(withJSONObject: appJson, options: [.prettyPrinted, .sortedKeys])
    }
    
    private func customizePackageJson(_ data: Data, repoName: String, appName: String) -> Data? {
        guard var pkgJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        pkgJson["name"] = repoName
        pkgJson["description"] = appName
        return try? JSONSerialization.data(withJSONObject: pkgJson, options: [.prettyPrinted, .sortedKeys])
    }
    
    // MARK: - Git Trees API
    
    /// Push all files as a single commit via Git trees API.
    private func pushFilesViaGitTrees(repoName: String, appName: String, files: [TemplateFile]) async throws {
        let repoPath = "/repos/\(githubOrg)/\(repoName)"
        
        // Get the current main branch HEAD (repo was created with auto_init)
        // Retry with delay — GitHub may not have the main ref ready immediately after auto_init
        var refRes: ProxyResponse!
        for attempt in 1...5 {
            refRes = try await githubProxy("GET", "\(repoPath)/git/ref/heads/main", body: nil)
            if refRes.status == 200 { break }
            NSLog("[ProjectTaskHandler] GET main ref attempt %d → %d, retrying...", attempt, refRes.status)
            try await Task.sleep(for: .seconds(Double(attempt)))
        }
        guard refRes.status == 200,
              let refJson = refRes.json as? [String: Any],
              let refObj = refJson["object"] as? [String: Any],
              let parentSha = refObj["sha"] as? String else {
            throw ProjectTaskError.gitTreeCreation(body: "Failed to get main ref: \(refRes.text)")
        }
        
        // Create blobs for each file
        var treeEntries: [[String: Any]] = []
        for file in files {
            let isText = !isBinaryFile(file.path)
            let blobBody: [String: Any] = isText
                ? ["content": String(data: file.data, encoding: .utf8) ?? "", "encoding": "utf-8"]
                : ["content": file.data.base64EncodedString(), "encoding": "base64"]
            
            let blobRes = try await githubProxy("POST", "\(repoPath)/git/blobs", body: blobBody)
            guard blobRes.status == 201,
                  let json = blobRes.json as? [String: Any],
                  let sha = json["sha"] as? String else {
                log.warning("Failed to create blob for \(file.path)")
                continue
            }
            
            treeEntries.append([
                "path": file.path,
                "mode": file.isExecutable ? "100755" : "100644",
                "type": "blob",
                "sha": sha,
            ])
        }
        
        // Create tree (no base_tree — replaces entire tree with our files)
        let treeRes = try await githubProxy("POST", "\(repoPath)/git/trees", body: ["tree": treeEntries])
        guard treeRes.status == 201,
              let treeJson = treeRes.json as? [String: Any],
              let treeSha = treeJson["sha"] as? String else {
            throw ProjectTaskError.gitTreeCreation(body: treeRes.text)
        }
        
        // Create commit with parent (replaces auto_init README)
        let commitRes = try await githubProxy("POST", "\(repoPath)/git/commits", body: [
            "message": "Initial project: \(appName)",
            "tree": treeSha,
            "parents": [parentSha],
        ] as [String: Any])
        guard commitRes.status == 201,
              let commitJson = commitRes.json as? [String: Any],
              let commitSha = commitJson["sha"] as? String else {
            throw ProjectTaskError.gitCommitCreation(body: commitRes.text)
        }
        
        // Update main branch ref to new commit
        let updateRes = try await githubProxy("PATCH", "\(repoPath)/git/refs/heads/main", body: [
            "sha": commitSha,
        ])
        guard updateRes.status == 200 else {
            throw ProjectTaskError.gitRefCreation(body: updateRes.text)
        }
        
        log.info("Pushed \(treeEntries.count) files via Git trees API")
    }
    
    private func isBinaryFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "ico", "webp", "pdf", "zip", "tar", "gz"].contains(ext)
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
        // Build URL string directly to avoid appendingPathComponent encoding slashes
        let baseStr = proxyBaseURL.absoluteString.hasSuffix("/")
            ? String(proxyBaseURL.absoluteString.dropLast())
            : proxyBaseURL.absoluteString
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: "\(baseStr)/github\(cleanPath)") else {
            throw ProjectTaskError.gitTreeCreation(body: "Invalid proxy URL for path: \(path)")
        }
        log.info("GitHub proxy: \(method) \(url.absoluteString)")
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
    
    // MARK: - Repo Management
    
    /// Archive a GitHub repo via the relay's GitHub proxy.
    /// - Parameter repo: Full repo path, e.g. "neos-apps/my-project"
    public func archiveRepo(_ repo: String) async {
        let repoPath = "/repos/\(repo)"
        do {
            let res = try await githubProxy("PATCH", repoPath, body: ["archived": true])
            NSLog("[ProjectTaskHandler] archiveRepo %@: status=%d", repo, res.status)
        } catch {
            NSLog("[ProjectTaskHandler] archiveRepo error: %@", error.localizedDescription)
        }
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
    case gitTreeCreation(body: String)
    case gitCommitCreation(body: String)
    case gitRefCreation(body: String)
    
    var errorDescription: String? {
        switch self {
        case .repoCreation(let status, let body):
            return "Repo creation failed (HTTP \(status)): \(body.prefix(200))"
        case .issueCreation(let status, let body):
            return "Issue creation failed (HTTP \(status)): \(body.prefix(200))"
        case .gitTreeCreation(let body):
            return "Git tree creation failed: \(body.prefix(200))"
        case .gitCommitCreation(let body):
            return "Git commit creation failed: \(body.prefix(200))"
        case .gitRefCreation(let body):
            return "Git ref creation failed: \(body.prefix(200))"
        }
    }
}
