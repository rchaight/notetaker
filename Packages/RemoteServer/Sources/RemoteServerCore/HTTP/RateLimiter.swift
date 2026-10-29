import Foundation

/// A token bucket: `capacity` tokens, refilled continuously over `window`.
struct TokenBucket {
    let capacity: Double
    let window: TimeInterval
    private(set) var tokens: Double
    private var updated: Date

    init(capacity: Int, window: TimeInterval, now: Date) {
        self.capacity = Double(capacity)
        self.window = window
        tokens = Double(capacity)
        updated = now
    }

    /// Takes one token, or returns how many seconds until one is available.
    mutating func take(now: Date) -> TimeInterval? {
        let elapsed = max(0, now.timeIntervalSince(updated))
        tokens = min(capacity, tokens + elapsed * capacity / window)
        updated = now
        if tokens >= 1 {
            tokens -= 1
            return nil
        }
        return (1 - tokens) * window / capacity
    }
}

/// Process-wide limits. Spec 07 adds its auth-endpoint buckets next to these.
public actor RateLimiter {
    public struct Settings: Sendable {
        public var toolsPerMinute = 60
        public var toolsPerHour = 1500
        public var failuresPerWindow = 20
        public var failureWindow: TimeInterval = 60
        public var tarpit: TimeInterval = 60

        public init() {}
    }

    public enum Decision: Sendable, Equatable {
        case allowed
        case limited(retryAfter: Int)
    }

    private let settings: Settings
    private let now: @Sendable () -> Date
    private var minute: TokenBucket
    private var hour: TokenBucket
    private var failures: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]

    public init(settings: Settings = Settings(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.now = now
        minute = TokenBucket(capacity: settings.toolsPerMinute, window: 60, now: now())
        hour = TokenBucket(capacity: settings.toolsPerHour, window: 3600, now: now())
    }

    /// Global tool-call buckets (60/min, 1,500/h). Both must have a token.
    public func admitToolCall() -> Decision {
        let moment = now()
        // Check the hour bucket first without spending a minute token on a refusal.
        var hourProbe = hour
        if let wait = hourProbe.take(now: moment) {
            return .limited(retryAfter: max(1, Int(wait.rounded(.up))))
        }
        var minuteProbe = minute
        if let wait = minuteProbe.take(now: moment) {
            return .limited(retryAfter: max(1, Int(wait.rounded(.up))))
        }
        hour = hourProbe
        minute = minuteProbe
        return .allowed
    }

    /// Is this client inside a 60 s tarpit window?
    public func isTarpitted(key: String) -> Decision {
        let moment = now()
        if let until = blockedUntil[key] {
            if until > moment {
                return .limited(retryAfter: max(1, Int(until.timeIntervalSince(moment).rounded(.up))))
            }
            blockedUntil[key] = nil
            failures[key] = nil
        }
        return .allowed
    }

    /// Records an unauthenticated/denied request. Returns true when this one
    /// tripped the window (the caller audits `auth.tarpit`).
    @discardableResult
    public func recordAuthFailure(key: String) -> Bool {
        let moment = now()
        var recent = (failures[key] ?? []).filter { moment.timeIntervalSince($0) < settings.failureWindow }
        recent.append(moment)
        failures[key] = recent
        if recent.count >= settings.failuresPerWindow {
            blockedUntil[key] = moment.addingTimeInterval(settings.tarpit)
            failures[key] = nil
            return true
        }
        return false
    }
}
