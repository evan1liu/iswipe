"""
Test cases for backend calendar and reminder API routes
Run with: pytest test_backend.py -v
"""

import pytest
from fastapi.testclient import TestClient
from datetime import datetime, timedelta
from backend import app

client = TestClient(app)


class TestCalendarEventAPI:
    """Test suite for /calendar/event endpoint"""

    def test_create_valid_calendar_event(self):
        """Test creating a valid calendar event"""
        start_date = datetime.now()
        end_date = start_date + timedelta(hours=1)

        event_data = {
            "title": "Test Meeting",
            "location": "Conference Room A",
            "start_date": start_date.isoformat(),
            "end_date": end_date.isoformat(),
            "notes": "Important meeting",
            "all_day": False
        }

        response = client.post("/calendar/event", json=event_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert "Event validated successfully" in data["message"]
        assert data["event_data"] is not None
        assert data["event_data"]["title"] == "Test Meeting"
        assert data["event_data"]["location"] == "Conference Room A"

    def test_create_all_day_event(self):
        """Test creating an all-day calendar event"""
        start_date = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
        end_date = start_date + timedelta(days=1)

        event_data = {
            "title": "All Day Conference",
            "location": None,
            "start_date": start_date.isoformat(),
            "end_date": end_date.isoformat(),
            "notes": None,
            "all_day": True
        }

        response = client.post("/calendar/event", json=event_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert data["event_data"]["all_day"] is True

    def test_invalid_date_order(self):
        """Test that end date must be after start date"""
        start_date = datetime.now()
        end_date = start_date - timedelta(hours=1)  # End before start

        event_data = {
            "title": "Invalid Event",
            "location": None,
            "start_date": start_date.isoformat(),
            "end_date": end_date.isoformat(),
            "notes": None,
            "all_day": False
        }

        response = client.post("/calendar/event", json=event_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is False
        assert "End date must be after start date" in data["message"]

    def test_invalid_date_format(self):
        """Test handling of invalid date format"""
        event_data = {
            "title": "Test Event",
            "location": None,
            "start_date": "invalid-date",
            "end_date": "also-invalid",
            "notes": None,
            "all_day": False
        }

        response = client.post("/calendar/event", json=event_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is False
        assert "Invalid date format" in data["message"]

    def test_minimal_event_data(self):
        """Test creating event with minimal required fields"""
        start_date = datetime.now()
        end_date = start_date + timedelta(hours=1)

        event_data = {
            "title": "Minimal Event",
            "start_date": start_date.isoformat(),
            "end_date": end_date.isoformat()
        }

        response = client.post("/calendar/event", json=event_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True


class TestReminderAPI:
    """Test suite for /reminders/todo endpoint"""

    def test_create_valid_reminder(self):
        """Test creating a valid reminder"""
        due_date = datetime.now() + timedelta(days=1)

        reminder_data = {
            "title": "Complete project report",
            "notes": "Include Q4 metrics",
            "due_date": due_date.isoformat(),
            "priority": 1
        }

        response = client.post("/reminders/todo", json=reminder_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert "Reminder validated successfully" in data["message"]
        assert data["reminder_data"] is not None
        assert data["reminder_data"]["title"] == "Complete project report"
        assert data["reminder_data"]["priority"] == 1

    def test_create_reminder_without_due_date(self):
        """Test creating a reminder without a due date"""
        reminder_data = {
            "title": "Review documentation",
            "notes": None,
            "due_date": None,
            "priority": 5
        }

        response = client.post("/reminders/todo", json=reminder_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert data["reminder_data"]["due_date"] is None

    def test_reminder_priority_validation(self):
        """Test that priority must be between 0 and 9"""
        reminder_data = {
            "title": "Invalid Priority",
            "notes": None,
            "due_date": None,
            "priority": 10  # Invalid: too high
        }

        response = client.post("/reminders/todo", json=reminder_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is False
        assert "Priority must be between 0 and 9" in data["message"]

    def test_reminder_negative_priority(self):
        """Test that negative priority is rejected"""
        reminder_data = {
            "title": "Negative Priority",
            "notes": None,
            "due_date": None,
            "priority": -1
        }

        response = client.post("/reminders/todo", json=reminder_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is False
        assert "Priority must be between 0 and 9" in data["message"]

    def test_reminder_invalid_date_format(self):
        """Test handling of invalid date format in reminder"""
        reminder_data = {
            "title": "Test Reminder",
            "notes": None,
            "due_date": "not-a-date",
            "priority": 0
        }

        response = client.post("/reminders/todo", json=reminder_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is False
        assert "Invalid date format" in data["message"]

    def test_minimal_reminder_data(self):
        """Test creating reminder with minimal required fields"""
        reminder_data = {
            "title": "Simple reminder"
        }

        response = client.post("/reminders/todo", json=reminder_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True

    def test_high_priority_reminder(self):
        """Test creating a high priority reminder"""
        due_date = datetime.now() + timedelta(hours=2)

        reminder_data = {
            "title": "Urgent Task",
            "notes": "Must complete ASAP",
            "due_date": due_date.isoformat(),
            "priority": 1  # High priority
        }

        response = client.post("/reminders/todo", json=reminder_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert data["reminder_data"]["priority"] == 1

    def test_low_priority_reminder(self):
        """Test creating a low priority reminder"""
        reminder_data = {
            "title": "Low Priority Task",
            "notes": "Can do later",
            "due_date": None,
            "priority": 9  # Low priority
        }

        response = client.post("/reminders/todo", json=reminder_data)

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert data["reminder_data"]["priority"] == 9


class TestIntegration:
    """Integration tests for calendar and reminder workflows"""

    def test_create_event_and_reminder_for_same_meeting(self):
        """Test creating both a calendar event and reminder for the same meeting"""
        meeting_time = datetime.now() + timedelta(days=1, hours=10)
        meeting_end = meeting_time + timedelta(hours=1)

        # Create calendar event
        event_data = {
            "title": "Team Standup",
            "location": "Zoom",
            "start_date": meeting_time.isoformat(),
            "end_date": meeting_end.isoformat(),
            "notes": "Daily sync",
            "all_day": False
        }

        event_response = client.post("/calendar/event", json=event_data)
        assert event_response.status_code == 200
        assert event_response.json()["success"] is True

        # Create reminder for the same meeting
        reminder_data = {
            "title": "Prepare for Team Standup",
            "notes": "Review yesterday's progress",
            "due_date": (meeting_time - timedelta(hours=1)).isoformat(),
            "priority": 2
        }

        reminder_response = client.post("/reminders/todo", json=reminder_data)
        assert reminder_response.status_code == 200
        assert reminder_response.json()["success"] is True


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
