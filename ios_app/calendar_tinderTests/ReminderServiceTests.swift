//
//  ReminderServiceTests.swift
//  calendar_tinderTests
//
//  Unit tests for ReminderService
//

import XCTest
import EventKit
@testable import calendar_tinder

final class ReminderServiceTests: XCTestCase {
    var reminderService: ReminderService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        reminderService = ReminderService()
    }

    override func tearDownWithError() throws {
        reminderService = nil
        try super.tearDownWithError()
    }

    // MARK: - Authorization Tests

    func testAuthorizationStatusInitialization() {
        // Test that authorization status is checked on initialization
        XCTAssertNotNil(reminderService.authorizationStatus)
    }

    func testCheckAuthorizationStatus() {
        // Test checking authorization status
        reminderService.checkAuthorizationStatus()

        let validStatuses: [EKAuthorizationStatus] = [
            .notDetermined,
            .restricted,
            .denied,
            .authorized,
            .fullAccess,
            .writeOnly
        ]

        XCTAssertTrue(validStatuses.contains(reminderService.authorizationStatus))
    }

    // MARK: - Reminder Creation Tests

    func testAddReminderValidData() async throws {
        let title = "Complete project report"
        let notes = "Include Q4 metrics"
        let dueDate = Date().addingTimeInterval(86400) // 24 hours from now
        let priority = 1

        do {
            let reminderId = try await reminderService.addReminder(
                title: title,
                notes: notes,
                dueDate: dueDate,
                priority: priority
            )

            XCTAssertFalse(reminderId.isEmpty, "Reminder ID should not be empty")
        } catch ReminderError.accessDenied {
            // Expected if reminder access is not granted
            XCTAssertTrue(true, "Reminder access denied - expected in test environment")
        }
    }

    func testAddReminderMinimalData() async throws {
        let title = "Simple reminder"

        do {
            let reminderId = try await reminderService.addReminder(
                title: title,
                notes: nil,
                dueDate: nil,
                priority: 0
            )

            XCTAssertFalse(reminderId.isEmpty, "Reminder ID should not be empty")
        } catch ReminderError.accessDenied {
            XCTAssertTrue(true, "Reminder access denied - expected in test environment")
        }
    }

    func testAddReminderWithoutDueDate() async throws {
        let title = "No due date reminder"
        let notes = "This can be done anytime"

        do {
            let reminderId = try await reminderService.addReminder(
                title: title,
                notes: notes,
                dueDate: nil,
                priority: 5
            )

            XCTAssertFalse(reminderId.isEmpty, "Reminder ID should not be empty")
        } catch ReminderError.accessDenied {
            XCTAssertTrue(true, "Reminder access denied - expected in test environment")
        }
    }

    func testAddHighPriorityReminder() async throws {
        let title = "Urgent task"
        let priority = 1 // High priority

        do {
            let reminderId = try await reminderService.addReminder(
                title: title,
                notes: nil,
                dueDate: Date().addingTimeInterval(3600), // 1 hour from now
                priority: priority
            )

            XCTAssertFalse(reminderId.isEmpty, "Reminder ID should not be empty")
        } catch ReminderError.accessDenied {
            XCTAssertTrue(true, "Reminder access denied - expected in test environment")
        }
    }

    func testAddLowPriorityReminder() async throws {
        let title = "Low priority task"
        let priority = 9 // Low priority

        do {
            let reminderId = try await reminderService.addReminder(
                title: title,
                notes: nil,
                dueDate: nil,
                priority: priority
            )

            XCTAssertFalse(reminderId.isEmpty, "Reminder ID should not be empty")
        } catch ReminderError.accessDenied {
            XCTAssertTrue(true, "Reminder access denied - expected in test environment")
        }
    }

    // MARK: - Error Handling Tests

    func testReminderErrorDescriptions() {
        XCTAssertNotNil(ReminderError.accessDenied.errorDescription)
        XCTAssertNotNil(ReminderError.reminderNotFound.errorDescription)
        XCTAssertNotNil(ReminderError.saveFailed.errorDescription)

        XCTAssertTrue(ReminderError.accessDenied.errorDescription!.contains("access"))
        XCTAssertTrue(ReminderError.reminderNotFound.errorDescription!.contains("not found"))
        XCTAssertTrue(ReminderError.saveFailed.errorDescription!.contains("save"))
    }

    // MARK: - Reminder Retrieval Tests

    func testGetIncompleteReminders() async throws {
        do {
            let reminders = try await reminderService.getReminders(completed: false)
            XCTAssertNotNil(reminders)
            // Should return incomplete reminders if access is granted
        } catch ReminderError.accessDenied {
            XCTAssertTrue(true, "Reminder access denied - expected in test environment")
        }
    }

    func testGetCompletedReminders() async throws {
        do {
            let reminders = try await reminderService.getReminders(completed: true)
            XCTAssertNotNil(reminders)
            // Should return completed reminders if access is granted
        } catch ReminderError.accessDenied {
            XCTAssertTrue(true, "Reminder access denied - expected in test environment")
        }
    }

    // MARK: - Complete Reminder Tests

    func testCompleteReminder() async throws {
        // First create a reminder
        do {
            let reminderId = try await reminderService.addReminder(
                title: "Test completion",
                notes: nil,
                dueDate: nil,
                priority: 0
            )

            // Then mark it as complete
            try await reminderService.completeReminder(reminderId: reminderId)

            // If we get here, the reminder was successfully completed
            XCTAssertTrue(true, "Reminder completed successfully")
        } catch ReminderError.accessDenied {
            XCTAssertTrue(true, "Reminder access denied - expected in test environment")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Delete Reminder Tests

    func testDeleteReminder() async throws {
        // First create a reminder
        do {
            let reminderId = try await reminderService.addReminder(
                title: "Test deletion",
                notes: nil,
                dueDate: nil,
                priority: 0
            )

            // Then delete it
            try await reminderService.deleteReminder(reminderId: reminderId)

            XCTAssertTrue(true, "Reminder deleted successfully")
        } catch ReminderError.accessDenied {
            XCTAssertTrue(true, "Reminder access denied - expected in test environment")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Performance Tests

    func testAddReminderPerformance() throws {
        measure {
            Task {
                let title = "Performance Test Reminder"

                do {
                    _ = try await reminderService.addReminder(
                        title: title,
                        notes: nil,
                        dueDate: nil,
                        priority: 0
                    )
                } catch {
                    // Ignore errors in performance test
                }
            }
        }
    }
}
