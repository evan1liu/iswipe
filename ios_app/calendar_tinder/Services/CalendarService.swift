//
//  CalendarService.swift
//  calendar_tinder
//
//  Service for managing Apple Calendar integration using EventKit
//

import Foundation
import EventKit
import Combine

class CalendarService: ObservableObject {
    private let eventStore = EKEventStore()
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined

    init() {
        checkAuthorizationStatus()
    }

    // MARK: - Authorization

    func checkAuthorizationStatus() {
        if #available(iOS 17.0, *) {
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        } else {
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        }
    }

    func requestCalendarAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            let granted = try await eventStore.requestFullAccessToEvents()
            await MainActor.run {
                self.authorizationStatus = granted ? .fullAccess : .denied
            }
            return granted
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, error in
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

    // MARK: - Calendar Event Management

    func addEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil,
        isAllDay: Bool = false
    ) async throws -> String {
        // Check authorization
        let hasAccess = try await ensureAuthorization()
        guard hasAccess else {
            throw CalendarError.accessDenied
        }

        // Create the event
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.location = location
        event.notes = notes
        event.isAllDay = isAllDay
        event.calendar = eventStore.defaultCalendarForNewEvents

        // Add a 15-minute reminder
        let alarm = EKAlarm(relativeOffset: -15 * 60) // 15 minutes before
        event.addAlarm(alarm)

        // Save the event
        try eventStore.save(event, span: .thisEvent)

        return event.eventIdentifier
    }

    func deleteEvent(eventId: String) async throws {
        let hasAccess = try await ensureAuthorization()
        guard hasAccess else {
            throw CalendarError.accessDenied
        }

        guard let event = eventStore.event(withIdentifier: eventId) else {
            throw CalendarError.eventNotFound
        }

        try eventStore.remove(event, span: .thisEvent)
    }

    func getEvents(from startDate: Date, to endDate: Date) -> [EKEvent] {
        if #available(iOS 17.0, *) {
            guard authorizationStatus == .fullAccess || authorizationStatus == .writeOnly else {
                return []
            }
        } else {
            guard authorizationStatus == .authorized else {
                return []
            }
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )

        return eventStore.events(matching: predicate)
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
            return try await requestCalendarAccess()
        }

        return false
    }
}

// MARK: - Errors

enum CalendarError: LocalizedError {
    case accessDenied
    case eventNotFound
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access was denied. Please enable calendar access in Settings."
        case .eventNotFound:
            return "The calendar event was not found."
        case .saveFailed:
            return "Failed to save the calendar event."
        }
    }
}
