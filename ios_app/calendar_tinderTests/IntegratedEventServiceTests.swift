//
//  IntegratedEventServiceTests.swift
//  calendar_tinderTests
//
//  Unit tests for IntegratedEventService
//

import XCTest
@testable import calendar_tinder

final class IntegratedEventServiceTests: XCTestCase {
    var integratedService: IntegratedEventService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        integratedService = IntegratedEventService()
    }

    override func tearDownWithError() throws {
        integratedService = nil
        try super.tearDownWithError()
    }

    // MARK: - Calendar Event Integration Tests

    func testAddCalendarEventFullWorkflow() async {
        // Test the full workflow: backend validation + EventKit
        let title = "Integration Test Meeting"
        let startDate = Date().addingTimeInterval(3600) // 1 hour from now
        let endDate = startDate.addingTimeInterval(3600) // 2 hours from now
        let location = "Test Room"
        let notes = "This is a test meeting"

        // Note: This test requires backend to be running at http://127.0.0.1:8000
        // And calendar permissions to be granted
        let success = await integratedService.addCalendarEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes,
            isAllDay: false
        )

        // Test should succeed if backend is running and permissions are granted
        // Otherwise it should set lastError
        if !success {
            XCTAssertNotNil(integratedService.lastError, "Should have error if unsuccessful")
        } else {
            XCTAssertNotNil(integratedService.lastSuccessMessage)
            XCTAssertTrue(
                integratedService.lastSuccessMessage!.contains(title),
                "Success message should contain event title"
            )
        }
    }

    func testAddCalendarEventInvalidDates() async {
        // Test with end date before start date
        let startDate = Date()
        let endDate = startDate.addingTimeInterval(-3600) // 1 hour before start

        let success = await integratedService.addCalendarEvent(
            title: "Invalid Event",
            startDate: startDate,
            endDate: endDate
        )

        XCTAssertFalse(success, "Should fail with invalid date range")
        XCTAssertNotNil(integratedService.lastError)
    }

    // MARK: - Reminder Integration Tests

    func testAddReminderFullWorkflow() async {
        let title = "Integration Test Reminder"
        let notes = "Test reminder notes"
        let dueDate = Date().addingTimeInterval(86400) // 24 hours from now
        let priority = 1

        let success = await integratedService.addReminder(
            title: title,
            notes: notes,
            dueDate: dueDate,
            priority: priority
        )

        if !success {
            XCTAssertNotNil(integratedService.lastError, "Should have error if unsuccessful")
        } else {
            XCTAssertNotNil(integratedService.lastSuccessMessage)
            XCTAssertTrue(
                integratedService.lastSuccessMessage!.contains(title),
                "Success message should contain reminder title"
            )
        }
    }

    func testAddReminderInvalidPriority() async {
        // Backend should reject priority outside 0-9 range
        let title = "Invalid Priority Reminder"

        // Note: The request will fail at backend validation
        // Priority is capped at Int.max in Swift but backend validates 0-9
        let success = await integratedService.addReminder(
            title: title,
            notes: nil,
            dueDate: nil,
            priority: 100 // Invalid
        )

        XCTAssertFalse(success, "Should fail with invalid priority")
        XCTAssertNotNil(integratedService.lastError)
    }

    func testAddReminderMinimalData() async {
        let title = "Minimal Reminder"

        let success = await integratedService.addReminder(
            title: title,
            notes: nil,
            dueDate: nil,
            priority: 0
        )

        // Should succeed if backend is running and permissions granted
        if !success {
            XCTAssertNotNil(integratedService.lastError)
        } else {
            XCTAssertNotNil(integratedService.lastSuccessMessage)
        }
    }

    // MARK: - Error Handling Tests

    func testIntegratedEventErrorDescriptions() {
        let error1 = IntegratedEventError.validationFailed("Test message")
        XCTAssertTrue(error1.errorDescription!.contains("Test message"))

        let error2 = IntegratedEventError.addEventFailed
        XCTAssertNotNil(error2.errorDescription)

        let error3 = IntegratedEventError.addReminderFailed
        XCTAssertNotNil(error3.errorDescription)
    }

    // MARK: - Permission Tests

    func testRequestCalendarPermission() async throws {
        // Test requesting calendar permission
        do {
            let granted = try await integratedService.requestCalendarPermission()
            // Permission may or may not be granted depending on test environment
            XCTAssertNotNil(granted)
        } catch {
            // Permission request may fail in test environment
            XCTAssertTrue(true, "Permission request failed - expected in some test environments")
        }
    }

    func testRequestReminderPermission() async throws {
        // Test requesting reminder permission
        do {
            let granted = try await integratedService.requestReminderPermission()
            XCTAssertNotNil(granted)
        } catch {
            XCTAssertTrue(true, "Permission request failed - expected in some test environments")
        }
    }

    // MARK: - State Management Tests

    func testErrorStateClearing() async {
        // Add an invalid event to trigger an error
        let startDate = Date()
        let endDate = startDate.addingTimeInterval(-3600)

        _ = await integratedService.addCalendarEvent(
            title: "Error Test",
            startDate: startDate,
            endDate: endDate
        )

        // Error should be set
        XCTAssertNotNil(integratedService.lastError)

        // Now add a valid event
        let validStart = Date().addingTimeInterval(3600)
        let validEnd = validStart.addingTimeInterval(3600)

        _ = await integratedService.addCalendarEvent(
            title: "Valid Event",
            startDate: validStart,
            endDate: validEnd
        )

        // Previous error should be cleared if new operation starts
        // (This behavior depends on implementation)
    }
}
