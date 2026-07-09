import SwiftUI

struct CalendarDayNavigator: View {
    @Binding var selectedDate: Date
    @State private var showingCalendar = false

    private var calendar: Calendar { .current }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                selectedDate = DayHistory.shiftDays(selectedDate, by: -1, calendar: calendar)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.bordered)

            Button {
                showingCalendar = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .foregroundStyle(SyncFitTheme.accent)
                    VStack(spacing: 2) {
                        Text(DayHistory.displayTitle(for: selectedDate, calendar: calendar))
                            .font(.subheadline.weight(.semibold))
                        Text(selectedDate.formatted(.dateTime.weekday(.wide)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                selectedDate = DayHistory.shiftDays(selectedDate, by: 1, calendar: calendar)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.bordered)
            .disabled(isForwardDisabled)
        }
        .sheet(isPresented: $showingCalendar) {
            NavigationStack {
                VStack(spacing: 16) {
                    DatePicker(
                        "Select a day",
                        selection: $selectedDate,
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .padding(.horizontal)

                    if !calendar.isDateInToday(selectedDate) {
                        Button("Jump to Today") {
                            selectedDate = .now
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom)
                .navigationTitle("Pick a Day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingCalendar = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: selectedDate) { _, newValue in
            selectedDate = calendar.startOfDay(for: newValue)
        }
    }

    private var isForwardDisabled: Bool {
        DayHistory.isTodayOrFuture(selectedDate, calendar: calendar)
    }
}

struct NutritionWeekStrip: View {
    @Binding var selectedDate: Date
    let hasLoggedFood: (Date) -> Bool
    var scheduleAccentColor: ((Date) -> Color?)? = nil

    @State private var showingCalendar = false

    private var calendar: Calendar { .current }

    private var weekDates: [Date] {
        DayHistory.sundayToSaturdayDates(for: selectedDate, calendar: calendar)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                selectedDate = DayHistory.shiftDays(selectedDate, by: -7, calendar: calendar)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 44)
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                ForEach(Array(weekDates.enumerated()), id: \.offset) { index, day in
                    dayButton(day, letter: DayHistory.sundayWeekdayLabels[index])
                }
            }

            Button {
                guard canGoForward else { return }
                selectedDate = DayHistory.shiftDays(selectedDate, by: 7, calendar: calendar)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(canGoForward ? .secondary : .tertiary)
                    .frame(width: 28, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)

            Button {
                showingCalendar = true
            } label: {
                Image(systemName: "calendar")
                    .font(.body.weight(.medium))
                    .foregroundStyle(SyncFitTheme.accent)
                    .frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pick a date")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingCalendar) {
            NutritionDayPickerSheet(selectedDate: $selectedDate, isPresented: $showingCalendar)
        }
        .onChange(of: selectedDate) { _, newValue in
            selectedDate = calendar.startOfDay(for: newValue)
        }
    }

    private var canGoForward: Bool {
        let nextWeek = DayHistory.shiftDays(selectedDate, by: 7, calendar: calendar)
        return calendar.startOfDay(for: nextWeek) <= calendar.startOfDay(for: .now)
    }

    private func dayButton(_ day: Date, letter: String) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)
        let isFuture = day > calendar.startOfDay(for: .now)
        let dayNumber = calendar.component(.day, from: day)
        let logged = hasLoggedFood(day)
        let scheduleColor = scheduleAccentColor?(day)

        return Button {
            guard !isFuture else { return }
            selectedDate = day
        } label: {
            VStack(spacing: 6) {
                Text(letter)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? SyncFitTheme.accent : .secondary)

                ZStack {
                    if logged {
                        Circle()
                            .fill(SyncFitTheme.accent.opacity(isSelected ? 0.22 : 0.12))
                            .frame(width: 36, height: 36)
                    } else if let scheduleColor {
                        Circle()
                            .fill(scheduleColor.opacity(isSelected ? 0.22 : 0.12))
                            .frame(width: 36, height: 36)
                    }

                    Circle()
                        .stroke(
                            isSelected
                                ? (scheduleColor ?? SyncFitTheme.accent)
                                : Color.clear,
                            lineWidth: 2
                        )
                        .frame(width: 36, height: 36)

                    if isToday, !isSelected {
                        Circle()
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                            .frame(width: 36, height: 36)
                    }

                    Text("\(dayNumber)")
                        .font(.subheadline.weight(isSelected ? .bold : .medium))
                        .foregroundStyle(
                            isSelected ? (scheduleColor ?? SyncFitTheme.accent) : .primary
                        )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .opacity(isFuture ? 0.35 : 1)
    }
}

struct NutritionDayPickerSheet: View {
    @Binding var selectedDate: Date
    @Binding var isPresented: Bool

    private var calendar: Calendar { .current }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker(
                    "Select a day",
                    selection: $selectedDate,
                    in: ...Date.now,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal)

                if !calendar.isDateInToday(selectedDate) {
                    Button("Jump to Today") {
                        selectedDate = .now
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.horizontal)
                }
            }
            .padding(.bottom)
            .navigationTitle("Pick a Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: selectedDate) { _, newValue in
            selectedDate = calendar.startOfDay(for: newValue)
        }
    }
}

struct WorkoutWeekSelector: View {
    @Binding var selectedDate: Date
    let hasWorkout: (Date) -> Bool

    private var calendar: Calendar { .current }
    private var weekDates: [Date] {
        DayHistory.mondayToSundayDates(calendar: calendar)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekDates.enumerated()), id: \.offset) { index, day in
                Button {
                    guard day <= calendar.startOfDay(for: .now) else { return }
                    selectedDate = day
                } label: {
                    VStack(spacing: 8) {
                        Text(DayHistory.weekdayLabels[index])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ZStack {
                            if isSelected(day) {
                                Circle()
                                    .stroke(SyncFitTheme.accentBright, lineWidth: 2)
                                    .frame(width: 22, height: 22)
                            }

                            Circle()
                                .fill(dotFill(for: day))
                                .frame(width: isSelected(day) ? 10 : 8, height: isSelected(day) ? 10 : 8)
                        }
                        .frame(height: 22)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(day > calendar.startOfDay(for: .now))
                .opacity(day > calendar.startOfDay(for: .now) ? 0.35 : 1)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: selectedDate) { _, newValue in
            selectedDate = calendar.startOfDay(for: newValue)
        }
    }

    private func isSelected(_ day: Date) -> Bool {
        calendar.isDate(day, inSameDayAs: selectedDate)
    }

    private func dotFill(for day: Date) -> Color {
        if hasWorkout(day) {
            return SyncFitTheme.accentBright
        }
        if isSelected(day) {
            return SyncFitTheme.accent.opacity(0.45)
        }
        return Color(.tertiaryLabel).opacity(0.35)
    }
}
