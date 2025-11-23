//
//  EventParser.swift
//  calendar_tinder
//
//  Parses event information from email text
//

import Foundation

struct ParsedEvent {
    let startDate: Date?
    let endDate: Date?
    let location: String?
    let hasEventInfo: Bool

    var isValid: Bool {
        return startDate != nil && endDate != nil
    }
}

class EventParser {

    /// Parses email content to extract event details
    /// Looks for pattern: "Event Time: Month Day, Year at HH:MM AM/PM - HH:MM AM/PM"
    static func parseEvent(from text: String) -> ParsedEvent {
        var startDate: Date? = nil
        var endDate: Date? = nil
        var location: String? = nil

        // Check if email contains "Event Time:" indicator
        let hasEventInfo = text.contains("Event Time:")

        if hasEventInfo {
            // Extract location
            location = extractLocation(from: text)

            // Extract dates using regex pattern
            // Pattern: "Event Time: November 25, 2024 at 2:00 PM - 3:30 PM"
            let pattern = #"Event Time:\s*([A-Za-z]+\s+\d{1,2},\s+\d{4})\s+at\s+(\d{1,2}:\d{2}\s*(?:AM|PM))\s*-\s*(\d{1,2}:\d{2}\s*(?:AM|PM))"#

            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsString = text as NSString
                let results = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

                if let match = results.first, match.numberOfRanges == 4 {
                    let dateString = nsString.substring(with: match.range(at: 1))
                    let startTimeString = nsString.substring(with: match.range(at: 2))
                    let endTimeString = nsString.substring(with: match.range(at: 3))

                    // Parse start date
                    let startDateTimeString = "\(dateString) at \(startTimeString)"
                    startDate = parseDateTime(startDateTimeString)

                    // Parse end date (same day, different time)
                    let endDateTimeString = "\(dateString) at \(endTimeString)"
                    endDate = parseDateTime(endDateTimeString)
                }
            }
        }

        return ParsedEvent(
            startDate: startDate,
            endDate: endDate,
            location: location,
            hasEventInfo: hasEventInfo
        )
    }

    /// Extracts location from email text
    private static func extractLocation(from text: String) -> String? {
        let pattern = #"Location:\s*([^\n]+)"#

        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsString = text as NSString
            let results = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

            if let match = results.first, match.numberOfRanges == 2 {
                let location = nsString.substring(with: match.range(at: 1))
                return location.trimmingCharacters(in: .whitespaces)
            }
        }

        return nil
    }

    /// Parses a date-time string like "November 25, 2024 at 2:00 PM"
    private static func parseDateTime(_ dateTimeString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        return formatter.date(from: dateTimeString)
    }
}
