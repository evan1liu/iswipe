//
//  IntegratedEventService.swift
//  calendar_tinder
//
//  Integrated service that combines backend validation with EventKit
//

import Foundation
import Combine

class IntegratedEventService: ObservableObject {
    private let calendarService = CalendarService()
    private let reminderService = ReminderService()
    private let apiService = BackendAPIService.shared

    @Published var lastError: Error?
    @Published var lastSuccessMessage: String?

    // MARK: - Calendar Events

    /// Validates event data with backend, then adds to Apple Calendar
    func addCalendarEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil,
        isAllDay: Bool = false
    ) async -> Bool {
        do {
            // Step 1: Validate with backend
            let validationResponse = try await apiService.validateCalendarEvent(
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes,
                isAllDay: isAllDay
            )

            guard validationResponse.success else {
                await MainActor.run {
                    self.lastError = IntegratedEventError.validationFailed(validationResponse.message)
                }
                return false
            }

            // Step 2: Add to Apple Calendar via EventKit
            _ = try await calendarService.addEvent(
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes,
                isAllDay: isAllDay
            )

            await MainActor.run {
                self.lastSuccessMessage = "Event '\(title)' added to calendar successfully!"
            }

            return true

        } catch {
            await MainActor.run {
                self.lastError = error
            }
            return false
        }
    }

    // MARK: - Reminders

    /// Validates reminder data with backend, then adds to Apple Reminders
    func addReminder(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: Int = 0
    ) async -> Bool {
        do {
            // Step 1: Validate with backend
            let validationResponse = try await apiService.validateReminder(
                title: title,
                notes: notes,
                dueDate: dueDate,
                priority: priority
            )

            guard validationResponse.success else {
                await MainActor.run {
                    self.lastError = IntegratedEventError.validationFailed(validationResponse.message)
                }
                return false
            }

            // Step 2: Add to Apple Reminders via EventKit
            let reminderId = try await reminderService.addReminder(
                title: title,
                notes: notes,
                dueDate: dueDate,
                priority: priority
            )

            await MainActor.run {
                self.lastSuccessMessage = "Reminder '\(title)' added successfully!"
            }

            return true

        } catch {
            await MainActor.run {
                self.lastError = error
            }
            return false
        }
    }

    // MARK: - Permission Requests

    func requestCalendarPermission() async throws -> Bool {
        return try await calendarService.requestCalendarAccess()
    }

    func requestReminderPermission() async throws -> Bool {
        return try await reminderService.requestReminderAccess()
    }
}

// MARK: - Errors

enum IntegratedEventError: LocalizedError {
    case validationFailed(String)
    case addEventFailed
    case addReminderFailed

    var errorDescription: String? {
        switch self {
        case .validationFailed(let message):
            return "Validation failed: \(message)"
        case .addEventFailed:
            return "Failed to add event to calendar"
        case .addReminderFailed:
            return "Failed to add reminder"
        }
    }
}
