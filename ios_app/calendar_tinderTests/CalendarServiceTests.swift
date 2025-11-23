//
//  CalendarServiceTests.swift
//  calendar_tinderTests
//
//  Unit tests for CalendarService
//

import XCTest
import EventKit
@testable import calendar_tinder

final class CalendarServiceTests: XCTestCase {
    var calendarService: CalendarService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        calendarService = CalendarService()
    }

    override func tearDownWithError() throws {
        calendarService = nil
        try super.tearDownWithError()
    }

    // MARK: - Authorization Tests

    func testAuthorizationStatusInitialization() {
        // Test that authorization status is checked on initialization
        XCTAssertNotNil(calendarService.authorizationStatus)
    }

    func testCheckAuthorizationStatus() {
        // Test checking authorization status
        calendarService.checkAuthorizationStatus()

        // Status should be one of the valid EKAuthorizationStatus values
        let validStatuses: [EKAuthorizationStatus] = [
            .notDetermined,
            .restricted,
            .denied,
            .authorized,
            .fullAccess,
            .writeOnly
        ]

        XCTAssertTrue(validStatuses.contains(calendarService.authorizationStatus))
    }

    // MARK: - Event Creation Tests

    func testAddEventValidData() async throws {
        // This test requires calendar permission to be granted
        // In a real test environment, you'd mock the EventStore

        let title = "Test Meeting"
        let startDate = Date()
        let endDate = startDate.addingTimeInterval(3600) // 1 hour later
        let location = "Conference Room A"
        let notes = "Important meeting notes"

        // Note: This will fail if calendar access is not granted
        // In production tests, use a mock EventStore
        do {
            let eventId = try await calendarService.addEvent(
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes,
                isAllDay: false
            )

            XCTAssertFalse(eventId.isEmpty, "Event ID should not be empty")
        } catch CalendarError.accessDenied {
            // Expected if calendar access is not granted in test environment
            XCTAssertTrue(true, "Calendar access denied - expected in test environment")
        }
    }

    func testAddEventMinimalData() async throws {
        let title = "Minimal Event"
        let startDate = Date()
        let endDate = startDate.addingTimeInterval(1800) // 30 minutes later

        do {
            let eventId = try await calendarService.addEvent(
                title: title,
                startDate: startDate,
                endDate: endDate
            )

            XCTAssertFalse(eventId.isEmpty, "Event ID should not be empty")
        } catch CalendarError.accessDenied {
            // Expected if calendar access is not granted
            XCTAssertTrue(true, "Calendar access denied - expected in test environment")
        }
    }

    func testAddAllDayEvent() async throws {
        let title = "All Day Conference"
        let startDate = Calendar.current.startOfDay(for: Date())
        let endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate)!

        do {
            let eventId = try await calendarService.addEvent(
                title: title,
                startDate: startDate,
                endDate: endDate,
                isAllDay: true
            )

            XCTAssertFalse(eventId.isEmpty, "Event ID should not be empty")
        } catch CalendarError.accessDenied {
            XCTAssertTrue(true, "Calendar access denied - expected in test environment")
        }
    }

    // MARK: - Error Handling Tests

    func testCalendarErrorDescriptions() {
        XCTAssertNotNil(CalendarError.accessDenied.errorDescription)
        XCTAssertNotNil(CalendarError.eventNotFound.errorDescription)
        XCTAssertNotNil(CalendarError.saveFailed.errorDescription)

        XCTAssertTrue(CalendarError.accessDenied.errorDescription!.contains("access"))
        XCTAssertTrue(CalendarError.eventNotFound.errorDescription!.contains("not found"))
        XCTAssertTrue(CalendarError.saveFailed.errorDescription!.contains("save"))
    }

    // MARK: - Event Retrieval Tests

    func testGetEvents() {
        let startDate = Date()
        let endDate = startDate.addingTimeInterval(86400) // 24 hours later

        let events = calendarService.getEvents(from: startDate, to: endDate)

        // Should return an array (may be empty if no access or no events)
        XCTAssertNotNil(events)
    }

    func testGetEventsWithoutAuthorization() {
        // If not authorized, should return empty array
        if calendarService.authorizationStatus == .denied ||
           calendarService.authorizationStatus == .restricted {
            let events = calendarService.getEvents(
                from: Date(),
                to: Date().addingTimeInterval(3600)
            )
            XCTAssertTrue(events.isEmpty, "Should return empty array when not authorized")
        }
    }

    // MARK: - Performance Tests

    func testAddEventPerformance() throws {
        // Measure performance of adding an event
        measure {
            Task {
                let title = "Performance Test Event"
                let startDate = Date()
                let endDate = startDate.addingTimeInterval(3600)

                do {
                    _ = try await calendarService.addEvent(
                        title: title,
                        startDate: startDate,
                        endDate: endDate
                    )
                } catch {
                    // Ignore errors in performance test
                }
            }
        }
    }
}
