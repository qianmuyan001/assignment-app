import SwiftUI

struct TimetableGrid: View {
    let meetings: [CourseMeeting]
    let days: [Int]
    let courseName: (Int64) -> String
    let onEdit: (CourseMeeting) -> Void
    let onDelete: (CourseMeeting) -> Void
    @State private var horizontalOffset: CGFloat = 0
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let axisWidth: CGFloat = 64
    private let topInset: CGFloat = 12
    private let scale: TimetableGeometry
    private let columns: [Int: [TimetableGeometry.Placement]]
    private let colors: [Int64: Color]

    init(meetings: [CourseMeeting], days: [Int], courses: [Course], courseName: @escaping (Int64) -> String,
         onEdit: @escaping (CourseMeeting) -> Void, onDelete: @escaping (CourseMeeting) -> Void) {
        self.meetings = meetings; self.days = days; self.courseName = courseName
        self.onEdit = onEdit; self.onDelete = onDelete
        let geometry = TimetableGeometry(meetings: meetings)
        scale = geometry
        colors = Dictionary(uniqueKeysWithValues: courses.compactMap { course in
            guard let hex = course.colorHex, hex.count == 7,
                  let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            return (course.id, Color(red: Double((rgb >> 16) & 255) / 255,
                                     green: Double((rgb >> 8) & 255) / 255,
                                     blue: Double(rgb & 255) / 255))
        })
        columns = Dictionary(grouping: geometry.placements, by: { $0.meeting.weekday })
    }

    var body: some View {
        GeometryReader { viewport in
            let geometry = scale
            let columnWidth = max(dynamicTypeSize.isAccessibilitySize ? 240 : 170,
                                  (viewport.size.width - axisWidth) / CGFloat(max(days.count, 1)))
            ScrollView(.vertical) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        HStack(alignment: .top, spacing: 0) {
                            timeAxis(geometry)
                            ScrollView(.horizontal) {
                                HStack(spacing: 0) {
                                    ForEach(days, id: \.self) { day in
                                        dayColumn(day, width: width(for: day, base: columnWidth), geometry: geometry)
                                    }
                                }
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                // Global coordinates stay consistent across Catalyst's nested
                                // scroll views; a named scroll coordinate space can stay at zero.
                                proxy.frame(in: .global).minX - viewport.frame(in: .global).minX - axisWidth
                            } action: { offset in
                                horizontalOffset = offset
                            }
                        }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Text("Time").font(.caption.weight(.semibold)).frame(width: axisWidth)
                            GeometryReader { _ in
                                HStack(spacing: 0) {
                                    ForEach(days, id: \.self) { day in
                                        Text(TimetableGeometry.weekdayLabel(day, locale: locale)).font(.headline)
                                            .frame(width: width(for: day, base: columnWidth), height: 44)
                                            .accessibilityAddTraits(.isHeader)
                                    }
                                }
                                // Synchronize horizontal headers only. Vertical pinning
                                // is native Section behavior, not scroll compensation.
                                .offset(x: horizontalOffset)
                            }.frame(height: 44).clipped()
                        }
                        .background(Color(uiColor: .systemBackground))
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }
            .accessibilityIdentifier("timetable-time-grid")
        }
    }

    private func width(for day: Int, base: CGFloat) -> CGFloat {
        let lanes = columns[day]?.map(\.laneCount).max() ?? 1
        return max(base, CGFloat(lanes) * 160)
    }

    private func timeAxis(_ geometry: TimetableGeometry) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(geometry.ticks.filter { Int($0) % 60 == 0 }, id: \.self) { minute in
                Text(TimetableGeometry.label(minute)).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: axisWidth / 2, y: topInset + geometry.y(minute))
            }
        }
        .frame(width: axisWidth, height: geometry.height + 2 * topInset)
        .background(Color(uiColor: .systemBackground))
    }

    private func dayColumn(_ day: Int, width: CGFloat, geometry: TimetableGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(geometry.ticks, id: \.self) { minute in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: topInset + geometry.y(minute)))
                    path.addLine(to: CGPoint(x: width, y: topInset + geometry.y(minute)))
                }
                .stroke(Color.secondary.opacity(Int(minute) % 60 == 0 ? 0.4 : 0.2),
                        style: StrokeStyle(lineWidth: 0.5, dash: Int(minute) % 60 == 0 ? [] : [3, 3]))
                .accessibilityHidden(true)
            }
            ForEach(columns[day] ?? []) { placement in
                let laneWidth = width / CGFloat(placement.laneCount)
                let height = geometry.height(placement)
                let meeting = placement.meeting
                Button { onEdit(meeting) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        if height >= 22 {
                            Text(courseName(meeting.courseID)).font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        if height >= 32 { Text(MeetingFormatting.timeRange(meeting)).font(.caption2.monospacedDigit()).lineLimit(1) }
                        if height >= 60, let location = meeting.location, !location.isEmpty {
                            Text(location).font(.caption2).lineLimit(1)
                        }
                        if height >= 92, MeetingFormatting.usesForeignTimeZone(meeting) { Text(meeting.timezoneID).font(.caption2).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, height >= 22 ? 6 : 0).padding(.top, height >= 22 ? 4 : 0)
                    .frame(width: max(1, laneWidth - 6), height: height, alignment: .topLeading)
                    .foregroundStyle(.primary)
                    .background((colors[meeting.courseID] ?? .accentColor).opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(colors[meeting.courseID] ?? .accentColor).frame(width: 3) }
                    .clipped()
                    .frame(height: max(44, height), alignment: .top)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: laneWidth * (CGFloat(placement.lane) + 0.5),
                          y: topInset + geometry.y(placement.start) + max(44, height) / 2)
                .help("\(courseName(meeting.courseID)) · \(MeetingFormatting.timeRange(meeting)) · \(meeting.timezoneID)")
                .accessibilityLabel("\(courseName(meeting.courseID)), \(MeetingFormatting.timeRange(meeting)), \(meeting.location ?? ""), \(meeting.timezoneID)")
                .accessibilityIdentifier("meeting-block-\(meeting.id)")
                .contextMenu {
                    Button("Edit", systemImage: "pencil") { onEdit(meeting) }
                    Button("Delete", systemImage: "trash", role: .destructive) { onDelete(meeting) }
                }
            }
        }
        .frame(width: width, height: geometry.height + 2 * topInset)
        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 0.5) }
    }
}
