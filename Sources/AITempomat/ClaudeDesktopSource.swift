import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Reads the selected desktop login only after explicit, directory-specific consent.
/// Authentication material stays in memory and is never renewed, persisted, or logged.
actor ClaudeDesktopSource: UsageSource {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func consentKey(for directory: URL) -> String {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "claudeDesktopAccess.\(digest)"
    }

    static func isAccessAllowed(to directory: URL) -> Bool {
        UserDefaults.standard.bool(forKey: consentKey(for: directory))
    }

    /// Call only after the user accepts the profile connection's access explanation.
    static func allowAccess(to directory: URL) {
        UserDefaults.standard.set(true, forKey: consentKey(for: directory))
    }

    static func revokeAccess(to directory: URL) {
        UserDefaults.standard.removeObject(forKey: consentKey(for: directory))
    }

    func fetch() async throws -> [LimitRow] {
        guard Self.isAccessAllowed(to: directory) else { throw ClaudeDesktopError.consentRequired }
        let directory = directory
        let token: String
        do {
            // Security may display the system Keychain permission dialog; keep it off the UI thread.
            token = try await Task.detached(priority: .utility) {
                try Self.readAccessToken(in: directory)
            }.value
        } catch ClaudeDesktopError.keychainUnavailable {
            Self.revokeAccess(to: directory)
            throw ClaudeDesktopError.keychainUnavailable
        }
        guard Self.isAccessAllowed(to: directory) else { throw ClaudeDesktopError.consentRequired }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ClaudeUsageRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // URLSession diagnostics can include request details, so display only a fixed message.
            throw ClaudeDesktopError.networkUnavailable
        }
        guard let response = response as? HTTPURLResponse else { throw ClaudeDesktopError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw ClaudeDesktopError.loginExpired
        case 429: throw ClaudeDesktopError.rateLimited
        default: throw ClaudeDesktopError.serverUnavailable
        }
        return try ClaudeDesktopUsageParser.parse(data)
    }

    private static func readAccessToken(in directory: URL) throws -> String {
        // Recheck at the actual access boundary, including when the worker was queued.
        guard isAccessAllowed(to: directory) else { throw ClaudeDesktopError.consentRequired }
        let config: [String: Any]
        do {
            let data = try Data(contentsOf: directory.appending(path: "config.json"))
            guard data.count <= 8 * 1024 * 1024,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClaudeDesktopError.unsupportedLogin
            }
            config = object
        } catch { throw ClaudeDesktopError.unsupportedLogin }
        guard let account = config["lastKnownAccountUuid"] as? String, UUID(uuidString: account) != nil,
              let encoded = config["oauth:tokenCacheV2"] as? String,
              let encrypted = Data(base64Encoded: encoded) else { throw ClaudeDesktopError.unsupportedLogin }
        guard isAccessAllowed(to: directory) else { throw ClaudeDesktopError.consentRequired }
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, var password = item as? Data, !password.isEmpty else {
            throw ClaudeDesktopError.keychainUnavailable
        }
        defer { password.resetBytes(in: 0..<password.count) }
        var decrypted = try ClaudeSafeStorage.decrypt(encrypted, password: password)
        defer { decrypted.resetBytes(in: 0..<decrypted.count) }
        return try ClaudeDesktopCredentialParser.accessToken(
            from: decrypted, accountID: account,
            organizationID: ClaudeDesktopCredentialParser.activeOrganization(in: directory))
    }
}

private final class ClaudeUsageRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward a bearer to a redirect destination.
        completionHandler(nil)
    }
}

enum ClaudeDesktopError: LocalizedError {
    case consentRequired, keychainUnavailable, unsupportedLogin, ambiguousOrganization
    case loginExpired, invalidResponse, networkUnavailable, serverUnavailable, rateLimited

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            "Click Connect for this Claude profile to allow local Keychain access and read its subscription usage."
        case .keychainUnavailable:
            "Claude's Keychain item was unavailable or access was declined. Click Connect to try again and approve the macOS prompt."
        case .unsupportedLogin:
            "This profile has no supported Claude Code desktop login. Open its Claude app, sign in, and open the Code tab, then refresh."
        case .ambiguousOrganization:
            "This desktop login contains multiple organizations. Use a separate Claude profile with one organization to avoid showing the wrong subscription."
        case .loginExpired:
            "This Claude profile's login has expired or cannot read usage. Open its Claude app and the Code tab, then refresh."
        case .invalidResponse:
            "Claude returned an unsupported usage response. Update Claude and try again."
        case .networkUnavailable:
            "Couldn't reach Claude's usage service. Check your connection and refresh."
        case .serverUnavailable:
            "Claude's usage service is temporarily unavailable. It will retry automatically."
        case .rateLimited:
            "Claude's usage service is rate limited. Wait a few minutes before refreshing."
        }
    }
}

/// Electron's macOS v10 format. Protocol reference:
/// https://github.com/chromium/chromium/blob/130.0.6723.69/components/os_crypt/sync/os_crypt_mac.mm
enum ClaudeSafeStorage {
    static func decrypt(_ encrypted: Data, password: Data) throws -> Data {
        guard encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3,
              (encrypted.count - 3).isMultiple(of: kCCBlockSizeAES128) else {
            throw ClaudeDesktopError.unsupportedLogin
        }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let keySize = key.count
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let derivation = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                                password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                1003, &key, keySize)
        }
        guard derivation == kCCSuccess else { throw ClaudeDesktopError.unsupportedLogin }
        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        defer { _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let capacity = output.count
        var written = 0
        let status = ciphertext.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, bytes.baseAddress, ciphertext.count, &output, capacity, &written)
        }
        guard status == kCCSuccess else { throw ClaudeDesktopError.unsupportedLogin }
        return Data(output.prefix(written))
    }
}

enum ClaudeDesktopCredentialParser {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// The Code tab's scopes. Newer desktop versions add more (user:plugins), so these are a minimum.
    static let codeScopes: Set<String> = ["user:inference", "user:file_upload", "user:profile", "user:sessions:claude_code"]

    /// `organizationID` is the desktop app's own active organization, when known: it settles which
    /// token to use when the login has more than one.
    static func accessToken(from data: Data, accountID: String, organizationID: String? = nil,
                            now: Date = Date()) throws -> String {
        guard UUID(uuidString: accountID) != nil,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeDesktopError.unsupportedLogin
        }
        var matching: [(organization: String, entry: [String: Any])] = []
        var organizations = Set<String>()
        for (key, value) in entries {
            let identityParts = key.components(separatedBy: "|")
            guard identityParts.count == 2,
                  identityParts[0].lowercased() == "acct:\(accountID.lowercased())" else { continue }
            let scopeParts = identityParts[1].components(separatedBy: ":https://api.anthropic.com:")
            guard scopeParts.count == 2,
                  codeScopes.isSubset(of: scopeParts[1].split(separator: " ").map(String.init)) else { continue }
            let clientParts = scopeParts[0].split(separator: ":").map(String.init)
            guard clientParts.count == 2, clientParts[0] == clientID, UUID(uuidString: clientParts[1]) != nil else { continue }
            // A tombstoned organization still makes the active organization ambiguous. It
            // must not cause a different organization's surviving token to be selected.
            organizations.insert(clientParts[1].lowercased())
            guard let entry = value as? [String: Any] else { continue }
            matching.append((clientParts[1].lowercased(), entry))
        }
        if organizations.count > 1 {
            guard let active = organizationID?.lowercased(), organizations.contains(active) else {
                throw ClaudeDesktopError.ambiguousOrganization
            }
            matching.removeAll { $0.organization != active }
        }
        // One organization may hold several tokens (one per scope set); use the one that lasts longest.
        let tokens = matching.compactMap { match -> (token: String, expiresAt: Double)? in
            guard let token = match.entry["token"] as? String, !token.isEmpty,
                  let expiresAt = match.entry["expiresAt"] as? Double, expiresAt.isFinite else { return nil }
            return (token, expiresAt)
        }
        guard let best = tokens.max(by: { $0.expiresAt < $1.expiresAt }) else { throw ClaudeDesktopError.unsupportedLogin }
        guard best.expiresAt > now.timeIntervalSince1970 * 1000 else { throw ClaudeDesktopError.loginExpired }
        return best.token
    }

    /// The organization the desktop app last read plan usage for, from its own plan-usage-history.json.
    static func activeOrganization(in directory: URL) -> String? {
        struct History: Decodable { struct Sample: Decodable { let t: Double; let org: String? }; let samples: [Sample] }
        guard let data = try? Data(contentsOf: directory.appending(path: "plan-usage-history.json")), data.count <= 8 * 1024 * 1024,
              let history = try? JSONDecoder().decode(History.self, from: data) else { return nil }
        return history.samples.max { $0.t < $1.t }?.org.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
    }
}

enum ClaudeDesktopUsageParser {
    static func parse(_ data: Data) throws -> [LimitRow] {
        guard data.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeDesktopError.invalidResponse
        }
        var rows: [LimitRow] = []
        if let limits = object["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String,
                      ["session", "weekly_all", "weekly_scoped"].contains(kind) else { continue }
                let scope = limit["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                if kind == "weekly_scoped" && model == nil && surface == nil { continue }
                rows.append(try row(kind: kind, percent: limit["percent"], reset: limit["resets_at"],
                                    model: model, surface: surface,
                                    active: limit["is_active"] as? Bool ?? false))
            }
        }
        let legacy: [(String, String, String?)] = [
            ("five_hour", "session", nil), ("seven_day", "weekly_all", nil),
            ("seven_day_sonnet", "weekly_scoped", "Sonnet"), ("seven_day_opus", "weekly_scoped", "Opus"),
        ]
        for (key, kind, model) in legacy {
            guard !rows.contains(where: { $0.kind == kind && $0.scope?.model?.displayName == model }),
                  let limit = object[key] as? [String: Any], let usage = limit["utilization"], !(usage is NSNull) else { continue }
            rows.append(try row(kind: kind, percent: usage, reset: limit["resets_at"], model: model))
        }
        guard !rows.isEmpty else { throw UsageError.noMeters }
        if !rows.contains(where: \.isActive) {
            // Older endpoints omit the server's active pick. Prefer an almost-full weekly
            // limit, otherwise the session, while keeping every available limit visible.
            let selected = rows.indices.filter { rows[$0].group == "weekly" && rows[$0].percent >= 90 }
                .max { rows[$0].percent < rows[$1].percent }
                ?? rows.firstIndex(where: { $0.kind == "session" }) ?? rows.startIndex
            rows[selected].isActive = true
        }
        return rows
    }

    private static func row(kind: String, percent value: Any?, reset: Any?, model: String? = nil,
                            surface: String? = nil, active: Bool = false) throws -> LimitRow {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...100).contains(number.doubleValue) else {
            throw ClaudeDesktopError.invalidResponse
        }
        let percent = number.doubleValue
        let resetsAt: String?
        if let string = reset as? String {
            resetsAt = string
        } else if let seconds = reset as? NSNumber, CFGetTypeID(seconds) != CFBooleanGetTypeID(), seconds.doubleValue.isFinite {
            resetsAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds.doubleValue))
        } else {
            resetsAt = nil
        }
        return LimitRow(kind: kind, group: kind == "session" ? "session" : "weekly", percent: percent,
                        resetsAt: resetsAt,
                        scope: model != nil || surface != nil ? .init(model: model.map { .init(displayName: $0) },
                                                                     surface: surface.map { .init(displayName: $0) }) : nil,
                        severity: percent >= 90 ? "critical" : percent >= 75 ? "warning" : "normal", isActive: active)
    }
}
