//
//  BackendAPIService.swift
//  calendar_tinder
//
//  Service for communicating with the Python FastAPI backend
//

import Foundation

// MARK: - API Models

struct CalendarEventRequest: Codable {
    let title: String
    let location: String?
    let start_date: String
    let end_date: String
    let notes: String?
    let all_day: Bool
}

struct CalendarEventResponse: Codable {
    let success: Bool
    let message: String
    let event_data: EventData?

    struct EventData: Codable {
        let title: String
        let location: String?
        let start_date: String
        let end_date: String
        let notes: String?
        let all_day: Bool
        let validated_at: String
    }
}

struct ReminderRequest: Codable {
    let title: String
    let notes: String?
    let due_date: String?
    let priority: Int
}

struct ReminderResponse: Codable {
    let success: Bool
    let message: String
    let reminder_data: ReminderData?

    struct ReminderData: Codable {
        let title: String
        let notes: String?
        let due_date: String?
        let priority: Int
        let validated_at: String
    }
}

// MARK: - Backend API Service

class BackendAPIService {
    static let shared = BackendAPIService()
    private let baseURL = "http://127.0.0.1:8000"

    private init() {}

    // MARK: - Calendar Event API

    func validateCalendarEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil,
        isAllDay: Bool = false
    ) async throws -> CalendarEventResponse {
        let url = URL(string: "\(baseURL)/calendar/event")!

        let dateFormatter = ISO8601DateFormatter()

        let request = CalendarEventRequest(
            title: title,
            location: location,
            start_date: dateFormatter.string(from: startDate),
            end_date: dateFormatter.string(from: endDate),
            notes: notes,
            all_day: isAllDay
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }

        let decoder = JSONDecoder()
        return try decoder.decode(CalendarEventResponse.self, from: data)
    }

    // MARK: - Reminder API

    func validateReminder(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: Int = 0
    ) async throws -> ReminderResponse {
        let url = URL(string: "\(baseURL)/reminders/todo")!

        let dateFormatter = ISO8601DateFormatter()
        let dueDateString = dueDate.map { dateFormatter.string(from: $0) }

        let request = ReminderRequest(
            title: title,
            notes: notes,
            due_date: dueDateString,
            priority: priority
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }

        let decoder = JSONDecoder()
        return try decoder.decode(ReminderResponse.self, from: data)
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case decodingError
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid server response"
        case .decodingError:
            return "Failed to decode server response"
        case .serverError(let message):
            return "Server error: \(message)"
        }
    }
}
