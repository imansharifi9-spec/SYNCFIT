import Foundation

enum DayHistory {
    static func dateRange(for date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    static func shiftDays(_ date: Date, by amount: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: amount, to: calendar.startOfDay(for: date)) ?? date
    }

    static func displayTitle(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func isTodayOrFuture(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: date) >= calendar.startOfDay(for: .now)
    }

    static func mondayToSundayDates(for referenceDate: Date = .now, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: referenceDate)
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    static func sundayToSaturdayDates(for referenceDate: Date = .now, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: referenceDate)
        let weekday = calendar.component(.weekday, from: today)
        let daysFromSunday = weekday - 1
        guard let sunday = calendar.date(byAdding: .day, value: -daysFromSunday, to: today) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: sunday) }
    }

    static let weekdayLabels = ["M", "T", "W", "T", "F", "S", "S"]
    static let sundayWeekdayLabels = ["S", "M", "T", "W", "T", "F", "S"]
}

struct DaySection<Item> {
    let date: Date
    let items: [Item]
}

enum HistoryGrouping {
    static func groupByDay<Item>(
        _ items: [Item],
        date: (Item) -> Date,
        calendar: Calendar = .current
    ) -> [DaySection<Item>] {
        let grouped = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: date(item))
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { DaySection(date: $0.key, items: $0.value.sorted { date($0) > date($1) }) }
    }
}
