//
//  ReminderService.swift
//  calendar_tinder
//
//  Service for managing Apple Reminders integration using EventKit
//

import Foundation
import EventKit
import Combine

class ReminderService: ObservableObject {
    private let eventStore = EKEventStore()
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined

    init() {
        checkAuthorizationStatus()
    }

    // MARK: - Authorization

    func checkAuthorizationStatus() {
        if #available(iOS 17.0, *) {
            authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        } else {
            authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        }
    }

    func requestReminderAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            let granted = try await eventStore.requestFullAccessToReminders()
            await MainActor.run {
                self.authorizationStatus = granted ? .fullAccess : .denied
            }
            return granted
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        Task { @MainActor in
                            self.authorizationStatus = granted ? .authorized : .denied
                        }
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    // MARK: - Reminder Management

    func addReminder(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: Int = 0
    ) async throws -> String {
        // Check authorization
        let hasAccess = try await ensureAuthorization()
        guard hasAccess else {
            throw ReminderError.accessDenied
        }

        // Create the reminder
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        // Set due date if provided
        if let dueDate = dueDate {
            let dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
            reminder.dueDateComponents = dueDateComponents
        }

        // Set priority (0 = none, 1-4 = high, 5 = medium, 6-9 = low)
        reminder.priority = priority

        // Save the reminder
        try eventStore.save(reminder, commit: true)

        return reminder.calendarItemIdentifier
    }

    func deleteReminder(reminderId: String) async throws {
        let hasAccess = try await ensureAuthorization()
        guard hasAccess else {
            throw ReminderError.accessDenied
        }

        guard let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            throw ReminderError.reminderNotFound
        }

        try eventStore.remove(reminder, commit: true)
    }

    func completeReminder(reminderId: String) async throws {
        let hasAccess = try await ensureAuthorization()
        guard hasAccess else {
            throw ReminderError.accessDenied
        }

        guard let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            throw ReminderError.reminderNotFound
        }

        reminder.isCompleted = true
        try eventStore.save(reminder, commit: true)
    }

    func getReminders(completed: Bool = false) async throws -> [EKReminder] {
        let hasAccess = try await ensureAuthorization()
        guard hasAccess else {
            throw ReminderError.accessDenied
        }

        let predicate = eventStore.predicateForReminders(in: nil)

        return try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders = reminders {
                    let filtered = reminders.filter { $0.isCompleted == completed }
                    continuation.resume(returning: filtered)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func ensureAuthorization() async throws -> Bool {
        checkAuthorizationStatus()

        if #available(iOS 17.0, *) {
            if authorizationStatus == .fullAccess || authorizationStatus == .writeOnly {
                return true
            }
        } else {
            if authorizationStatus == .authorized {
                return true
            }
        }

        if authorizationStatus == .notDetermined {
            return try await requestReminderAccess()
        }

        return false
    }
}

// MARK: - Errors

enum ReminderError: LocalizedError {
    case accessDenied
    case reminderNotFound
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Reminders access was denied. Please enable reminders access in Settings."
        case .reminderNotFound:
            return "The reminder was not found."
        case .saveFailed:
            return "Failed to save the reminder."
        }
    }
}
