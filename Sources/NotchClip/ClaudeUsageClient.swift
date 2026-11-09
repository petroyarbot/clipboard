import Foundation

/// Result of one attempt to read Claude plan limits from the OAuth usage endpoint.
enum ClaudeFetchResult: Equatable {
    case success(Limits)
    case notLoggedIn
    case tokenExpired
    case rateLimited
    /// The user denied the Keychain prompt. Not retried automatically.
    case accessDenied
    case failure(String)
}

struct ClaudeCredentials: Equatable {
    /// Never logged, printed or written anywhere.
    let accessToken: String
    let expiresAt: Date?
}

enum ClaudeCredentialsResult: Equatable {
    case found(ClaudeCredentials)
    case notLoggedIn
    case accessDenied
    case failure(String)
}

/// Supplies the Claude Code OAuth login. Tests inject a fake; the app uses ClaudeKeychain.readCredentials.
typealias ClaudeTokenProvider = @Sendable () async -> ClaudeCredentialsResult

/// Sends one HTTP GET. Tests inject a fake; the app uses URLSessionUsageTransport.
protocol UsageTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

struct URLSessionUsageTransport: UsageTransport {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (body, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }
}

/// Reads the Claude Code login from the keychain item through /usr/bin/security.
/// Using that binary (not SecItemCopyMatching) keeps the user's "Always Allow" across ad-hoc rebuilds.
enum ClaudeKeychain {
    static let service = "Claude Code-credentials"
    /// The first read shows the Keychain "Allow" dialog, which waits for the user, so this must be long.
    static let timeout: TimeInterval = 120
    /// Exit status of `security` when the item does not exist (errSecItemNotFound).
    static let itemNotFoundStatus: Int32 = 44
    static let accessDeniedText = "Нет доступа к связке ключей — нажми «Обновить сейчас» в настройках"

    private enum SecurityRun {
        case output(Data)
        case exited(Int32)
        case timedOut
        case launchFailed
    }

    static func readCredentials() async -> ClaudeCredentialsResult {
        let run = await Task.detached(priority: .utility) {
            ClaudeKeychain.runSecurity(timeout: ClaudeKeychain.timeout)
        }.value
        switch run {
        case .output(let data): return parse(data)
        case .exited(let status) where status == itemNotFoundStatus: return .notLoggedIn
        // Any other failure of the read comes from the Keychain refusing access (denied dialog, locked item).
        case .exited: return .accessDenied
        case .timedOut: return .failure("Связка ключей не ответила")
        case .launchFailed: return .failure("Не удалось прочитать вход Claude")
        }
    }

    /// Parses {"claudeAiOauth": {"accessToken": ..., "expiresAt": <ms epoch>}}. Error text never includes the input.
    static func parse(_ data: Data) -> ClaudeCredentialsResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure("Не удалось прочитать вход Claude")
        }
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return .notLoggedIn }
        let expires = UsageParser.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return .found(ClaudeCredentials(accessToken: token, expiresAt: expires))
    }

    private static func runSecurity(timeout: TimeInterval) -> SecurityRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .launchFailed
        }

        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = stdout.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            process.waitUntilExit()
            return .timedOut
        }
        guard readDone.wait(timeout: .now() + 2) == .success else { return .timedOut }
        let status = process.terminationStatus
        return status == 0 ? .output(box.data) : .exited(status)
    }
}

/// Parses the usage endpoint response. utilization is percent used; the app shows percent left.
enum ClaudeUsageResponse {
    static func limits(from data: Data, now: Date) -> Limits? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let five = window(root["five_hour"])
        let week = window(root["seven_day"])
        guard five != nil || week != nil else { return nil }
        return Limits(
            fiveHourLeft: five?.left,
            fiveHourReset: five?.reset,
            weekLeft: week?.left,
            weekReset: week?.reset,
            updatedAt: now
        )
    }

    /// Percent left is rounded down, so the app never shows more left than the server reports.
    static func window(_ value: Any?) -> (left: Int?, reset: Date?)? {
        guard let dict = value as? [String: Any], let used = UsageParser.number(dict["utilization"]) else { return nil }
        let reset = (dict["resets_at"] as? String).flatMap(UsageParser.parseDate)
        let left = min(100, max(0, 100 - used)).rounded(.down)
        return (Int(left), reset)
    }
}

/// Fetches Claude plan limits. Never refreshes the OAuth token: the Claude Code CLI does that when it runs.
struct ClaudeUsageClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let timeout: TimeInterval = 10

    let tokenProvider: ClaudeTokenProvider
    let transport: UsageTransport

    init(
        tokenProvider: @escaping ClaudeTokenProvider = { await ClaudeKeychain.readCredentials() },
        transport: UsageTransport = URLSessionUsageTransport()
    ) {
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    func fetch(now: Date = Date()) async -> ClaudeFetchResult {
        let credentials: ClaudeCredentials
        switch await tokenProvider() {
        case .notLoggedIn:
            return .notLoggedIn
        case .failure(let message):
            return .failure(message)
        case .accessDenied:
            return .accessDenied
        case .found(let found):
            credentials = found
        }
        if let expiresAt = credentials.expiresAt, expiresAt < now {
            return .tokenExpired
        }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("NotchClip", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: (status: Int, body: Data)
        do {
            response = try await transport.send(request)
        } catch {
            return .failure("Нет связи с сервером Claude")
        }
        switch response.status {
        case 200..<300:
            guard let limits = ClaudeUsageResponse.limits(from: response.body, now: now) else {
                return .failure("Не удалось разобрать ответ Claude")
            }
            return .success(limits)
        case 401, 403:
            return .tokenExpired
        case 429:
            return .rateLimited
        default:
            return .failure("Claude ответил ошибкой \(response.status)")
        }
    }
}
