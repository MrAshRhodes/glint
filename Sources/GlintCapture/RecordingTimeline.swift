import Foundation

enum RecordingLimits {
    /// Longest recording in seconds. At this length the session stops on its own, finalises the file and
    /// returns it normally; `ScreenRecordingSession.stopReason` is then `.timeLimit`.
    static let maximumDuration: TimeInterval = 10 * 60
    static let frameRate = 30
}

/// The countdown offered before a recording starts.
enum RecordingCountdownChoice: Int, CaseIterable {
    case none = 0, three = 3, five = 5, ten = 10

    var seconds: Int { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .three, .five, .ten: return "\(rawValue)s"
        }
    }

    /// What VoiceOver and the tooltips call the choice.
    var spokenTitle: String {
        switch self {
        case .none: return "No countdown"
        case .three, .five, .ten: return "\(rawValue) seconds"
        }
    }
}

/// Counts whole seconds down to zero. The session shows `remaining` and calls `tick()` once per second.
struct RecordingCountdown: Equatable {
    enum Step: Equatable {
        case counting(Int)
        case finished
    }

    private(set) var remaining: Int

    init(seconds: Int) {
        remaining = max(seconds, 0)
    }

    var isFinished: Bool { remaining == 0 }

    /// One second has passed.
    @discardableResult
    mutating func tick() -> Step {
        guard remaining > 0 else { return .finished }
        remaining -= 1
        return remaining == 0 ? .finished : .counting(remaining)
    }
}

enum ElapsedTimeFormatter {
    /// `mm:ss`, or `h:mm:ss` from one hour; fractions are dropped and negative values read as zero.
    static func string(from interval: TimeInterval) -> String {
        let total = interval.isFinite ? max(Int(interval), 0) : 0
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The same time in words for VoiceOver, such as "1 minute, 5 seconds".
    static func spoken(from interval: TimeInterval, locale: Locale = .current) -> String {
        let total = interval.isFinite ? max(Int(interval), 0) : 0
        var calendar = Calendar.current
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(total)) ?? "\(total) seconds"
    }
}
