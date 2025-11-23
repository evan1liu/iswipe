# Calendar and Reminder Integration Guide

This document describes the Apple Calendar and Reminders integration for the Calendar Tinder app, implemented on the `osmond-calendar_remind` branch.

## Overview

The integration allows users to:
- Add email events to Apple Calendar
- Create reminders/to-dos from emails
- Sync data through a FastAPI backend that validates data before local storage
- Use EventKit framework for native iOS Calendar and Reminders integration

## Architecture

### Backend (Python FastAPI)

**Location**: `/backend.py`

The backend provides validation endpoints for calendar events and reminders:

#### Endpoints

1. **POST /calendar/event**
   - Validates calendar event data (dates, times, etc.)
   - Returns validated event data ready for EventKit
   - Request model: `CalendarEventRequest`
   - Response model: `CalendarEventResponse`

2. **POST /reminders/todo**
   - Validates reminder data (due dates, priority)
   - Returns validated reminder data
   - Request model: `ReminderRequest`
   - Response model: `ReminderResponse`

### iOS Services

**Location**: `/ios_app/calendar_tinder/Services/`

#### 1. CalendarService.swift
- Manages Apple Calendar integration via EventKit
- Handles calendar permission requests
- Creates, deletes, and retrieves calendar events
- Adds default 15-minute reminders to events

**Key Methods**:
```swift
func requestCalendarAccess() async throws -> Bool
func addEvent(title, startDate, endDate, location, notes, isAllDay) async throws -> String
func deleteEvent(eventId) async throws
func getEvents(from, to) -> [EKEvent]
```

#### 2. ReminderService.swift
- Manages Apple Reminders integration via EventKit
- Handles reminder permission requests
- Creates, completes, deletes, and retrieves reminders
- Supports priority levels (0-9)

**Key Methods**:
```swift
func requestReminderAccess() async throws -> Bool
func addReminder(title, notes, dueDate, priority) async throws -> String
func deleteReminder(reminderId) async throws
func completeReminder(reminderId) async throws
func getReminders(completed) async throws -> [EKReminder]
```

#### 3. BackendAPIService.swift
- Communicates with Python FastAPI backend
- Validates event and reminder data before local storage
- Handles API errors and responses

**Key Methods**:
```swift
func validateCalendarEvent(...) async throws -> CalendarEventResponse
func validateReminder(...) async throws -> ReminderResponse
```

#### 4. IntegratedEventService.swift
- Combines backend validation with EventKit operations
- Orchestrates the full workflow: validate → add to device
- Manages error states and success messages

**Key Methods**:
```swift
func addCalendarEvent(...) async -> Bool
func addReminder(...) async -> Bool
func requestCalendarPermission() async throws -> Bool
func requestReminderPermission() async throws -> Bool
```

### Frontend (SwiftUI)

**Location**: `/ios_app/calendar_tinder/ContentView.swift`

Updated to include:
- "Add to Calendar" button
- "Add Reminder" button
- Success/error message display
- Integration with IntegratedEventService

## Data Flow

### Adding a Calendar Event

1. User taps "Add to Calendar" button
2. Frontend calls `IntegratedEventService.addCalendarEvent()`
3. Service validates data with backend via `POST /calendar/event`
4. Backend validates dates, format, and returns validated data
5. Service calls `CalendarService.addEvent()`
6. CalendarService requests permission (if needed)
7. Event is added to Apple Calendar via EventKit
8. Success message displayed to user

### Adding a Reminder

1. User taps "Add Reminder" button
2. Frontend calls `IntegratedEventService.addReminder()`
3. Service validates data with backend via `POST /reminders/todo`
4. Backend validates priority, due date format
5. Service calls `ReminderService.addReminder()`
6. ReminderService requests permission (if needed)
7. Reminder is added to Apple Reminders via EventKit
8. Success message displayed to user

## Permissions

### Required Info.plist Entries

Add these to your `Info.plist`:

```xml
<!-- Calendar Access -->
<key>NSCalendarsUsageDescription</key>
<string>Calendar Tinder needs access to your calendar to add accepted events.</string>

<key>NSCalendarsFullAccessUsageDescription</key>
<string>Calendar Tinder needs full calendar access to create and manage events.</string>

<!-- Reminders Access -->
<key>NSRemindersUsageDescription</key>
<string>Calendar Tinder needs access to your reminders to create to-dos from emails.</string>

<key>NSRemindersFullAccessUsageDescription</key>
<string>Calendar Tinder needs full reminders access to create and manage to-dos.</string>
```

## Testing

### Backend Tests

**Location**: `/test_backend.py`

Run backend tests:
```bash
# Install dependencies
pip install -r requirements.txt

# Run tests
pytest test_backend.py -v
```

**Test Coverage**:
- ✅ Valid calendar event creation
- ✅ All-day event creation
- ✅ Invalid date order validation
- ✅ Invalid date format handling
- ✅ Minimal event data
- ✅ Valid reminder creation
- ✅ Reminder without due date
- ✅ Priority validation (0-9)
- ✅ Negative priority rejection
- ✅ Invalid date format in reminders
- ✅ Integration workflow tests

### iOS Unit Tests

**Location**: `/ios_app/calendar_tinderTests/`

Three test suites:

1. **CalendarServiceTests.swift**
   - Authorization status checking
   - Event creation with valid/minimal data
   - All-day event creation
   - Error handling
   - Event retrieval
   - Performance tests

2. **ReminderServiceTests.swift**
   - Authorization status checking
   - Reminder creation with various priorities
   - Reminders with/without due dates
   - Complete/delete reminder operations
   - Error handling
   - Performance tests

3. **IntegratedEventServiceTests.swift**
   - Full workflow tests (backend + EventKit)
   - Invalid data handling
   - Permission request tests
   - Error state management

Run iOS unit tests:
```bash
# From Xcode: Cmd+U
# Or from command line:
xcodebuild test -scheme calendar_tinder -destination 'platform=iOS Simulator,name=iPhone 15'
```

### iOS UI Tests

**Location**: `/ios_app/calendar_tinderUITests/CalendarReminderUITests.swift`

**Test Coverage**:
- ✅ Button existence and accessibility
- ✅ Add calendar event flow
- ✅ Add reminder flow
- ✅ Permission prompts
- ✅ Swipe gestures
- ✅ Backend connection status
- ✅ Error message display
- ✅ Retry functionality
- ✅ Navigation tests
- ✅ Accessibility labels
- ✅ Performance metrics

Run UI tests:
```bash
# From Xcode: Cmd+U (with UI Tests selected)
# Or from command line:
xcodebuild test -scheme calendar_tinder -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:calendar_tinderUITests
```

## Setup Instructions

### 1. Backend Setup

```bash
# Navigate to project root
cd /Users/User/Developer/calendar_tinder

# Create virtual environment (if not exists)
python3 -m venv .venv

# Activate virtual environment
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Run backend server
python backend.py
```

Backend will be available at: `http://127.0.0.1:8000`

### 2. iOS App Setup

1. Open `ios_app/calendar_tinder.xcodeproj` in Xcode
2. Update `Info.plist` with calendar and reminder permissions (see Permissions section)
3. Ensure the backend URL is correct in `BackendAPIService.swift` (line 73)
4. Build and run the app (Cmd+R)

### 3. Testing the Integration

1. **Start the backend**:
   ```bash
   python backend.py
   ```

2. **Run the iOS app** in simulator or device

3. **Test workflow**:
   - Tap "Load Emails" to fetch emails from backend
   - Navigate through email cards
   - Tap "Add to Calendar" - should prompt for calendar permission
   - Tap "Add Reminder" - should prompt for reminders permission
   - Check Apple Calendar and Reminders apps to verify events/reminders were created

4. **Run tests**:
   ```bash
   # Backend tests
   pytest test_backend.py -v

   # iOS tests (from Xcode)
   Cmd+U
   ```

## API Documentation

### Backend API

Access interactive API docs when backend is running:
- Swagger UI: `http://127.0.0.1:8000/docs`
- ReDoc: `http://127.0.0.1:8000/redoc`

### Example API Requests

**Create Calendar Event**:
```bash
curl -X POST http://127.0.0.1:8000/calendar/event \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Team Meeting",
    "location": "Conference Room A",
    "start_date": "2025-11-23T10:00:00",
    "end_date": "2025-11-23T11:00:00",
    "notes": "Discuss Q4 goals",
    "all_day": false
  }'
```

**Create Reminder**:
```bash
curl -X POST http://127.0.0.1:8000/reminders/todo \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Complete project report",
    "notes": "Include Q4 metrics",
    "due_date": "2025-11-24T17:00:00",
    "priority": 1
  }'
```

## Troubleshooting

### Calendar/Reminder Access Denied

**Problem**: Events/reminders not being added

**Solution**:
1. Go to iOS Settings → Privacy & Security → Calendars/Reminders
2. Enable access for Calendar Tinder app
3. Restart the app

### Backend Connection Failed

**Problem**: "Invalid server response" or timeout errors

**Solution**:
1. Ensure backend is running: `python backend.py`
2. Check backend URL in `BackendAPIService.swift` (should be `http://127.0.0.1:8000`)
3. If running on physical device, update URL to your computer's IP address
4. Ensure firewall allows connections on port 8000

### Tests Failing

**Problem**: Tests fail with permission errors

**Solution**:
- Unit tests that require EventKit access will gracefully handle access denial in test environments
- For full testing, grant calendar/reminder permissions to the test runner
- Some tests are expected to show "access denied - expected in test environment"

## Future Enhancements

- [ ] Parse email content to extract event details (dates, times, locations)
- [ ] Support for recurring events
- [ ] Custom calendar selection (instead of default calendar)
- [ ] Custom reminder lists
- [ ] Event/reminder editing before creation
- [ ] Batch operations
- [ ] Offline queue for pending operations
- [ ] Sync status tracking

## File Structure

```
calendar_tinder/
├── backend.py                          # FastAPI backend with validation endpoints
├── test_backend.py                     # Backend unit tests
├── requirements.txt                    # Python dependencies
└── ios_app/
    └── calendar_tinder/
        ├── ContentView.swift           # Main UI with calendar/reminder buttons
        ├── Services/
        │   ├── CalendarService.swift           # Apple Calendar integration
        │   ├── ReminderService.swift           # Apple Reminders integration
        │   ├── BackendAPIService.swift         # Backend API client
        │   └── IntegratedEventService.swift    # Orchestration service
        ├── calendar_tinderTests/
        │   ├── CalendarServiceTests.swift
        │   ├── ReminderServiceTests.swift
        │   └── IntegratedEventServiceTests.swift
        └── calendar_tinderUITests/
            └── CalendarReminderUITests.swift
```

## Credits

Developed by: Evan Liu
Branch: `osmond-calendar_remind`
Date: November 2025
