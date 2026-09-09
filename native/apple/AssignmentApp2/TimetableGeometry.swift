import Foundation

/// One wall-clock scale shared by ticks, rules and course rectangles. The weekly
/// timetable displays each meeting's own local clock; it never rewrites its zone.
struct TimetableGeometry {
    let startMinute: Double
    let endMinute: Double
    let pointsPerMinute: Double
    let placements: [Placement]
    struct Placement: Identifiable {
        let meeting: CourseMeeting
        let start: Double
        let end: Double
        let lane: Int
        var laneCount: Int
        var id: Int64 { meeting.id }
    }

    init(meetings: [CourseMeeting], pointsPerMinute: Double = 1.4) {
        self.pointsPerMinute = pointsPerMinute
        let active = meetings.filter { $0.deletedAt == nil }
        let starts = active.map { Self.minutes($0.startTimeLocal) }
        let ends = active.map { Self.minutes($0.endTimeLocal) }
        startMinute = min(8 * 60, floor((starts.min() ?? 480) / 60) * 60)
        endMinute = max(18 * 60, ceil((ends.max() ?? 1080) / 60) * 60)
        var result: [Placement] = []
        for weekday in 1...7 {
            let sorted = active.filter { $0.weekday == weekday }.sorted {
                if $0.startTimeLocal != $1.startTimeLocal { return $0.startTimeLocal < $1.startTimeLocal }
                if $0.endTimeLocal != $1.endTimeLocal { return $0.endTimeLocal < $1.endTimeLocal }
                return $0.id < $1.id
            }
            var laneEnds: [Double] = []
            var cluster: [Placement] = []
            func finishCluster() {
                for var item in cluster { item.laneCount = laneEnds.count; result.append(item) }
                cluster = []; laneEnds = []
            }
            for meeting in sorted {
                let start = Self.minutes(meeting.startTimeLocal)
                let end = Self.minutes(meeting.endTimeLocal)
                // Allocate enough horizontal space for short-course hit targets;
                // visual heights remain exact and are never inflated to 44 pt.
                if !laneEnds.isEmpty && laneEnds.allSatisfy({ $0 <= start }) { finishCluster() }
                let lane = laneEnds.firstIndex(where: { $0 <= start }) ?? laneEnds.count
                let hitEnd = max(end, start + 44 / pointsPerMinute)
                if lane == laneEnds.count { laneEnds.append(hitEnd) } else { laneEnds[lane] = hitEnd }
                cluster.append(Placement(meeting: meeting, start: start, end: end, lane: lane, laneCount: 1))
            }
            finishCluster()
        }
        placements = result
    }
    var height: Double { (endMinute - startMinute) * pointsPerMinute }
    var ticks: [Double] { Array(stride(from: startMinute, through: endMinute, by: 30)) }
    func y(_ minute: Double) -> Double { (minute - startMinute) * pointsPerMinute }
    func height(_ placement: Placement) -> Double { (placement.end - placement.start) * pointsPerMinute }
    static func minutes(_ clock: String) -> Double {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 60 + parts[1] + parts[2] / 60
    }
    static func weekdayLabel(_ day: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.shortStandaloneWeekdaySymbols[day % 7]
    }

    static func label(_ minute: Double) -> String {
        String(format: "%02d:%02d", Int(minute) / 60, Int(minute) % 60)
    }
}
