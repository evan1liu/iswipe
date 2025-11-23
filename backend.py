from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from msal import PublicClientApplication
import requests
import webbrowser
import json
from typing import List, Optional
from pydantic import BaseModel
from datetime import datetime

app = FastAPI()

# Add CORS middleware to allow iOS app to call backend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, specify your iOS app's origin
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Using "Microsoft Graph PowerShell" Client ID
CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
TENANT_ID = "common"
SCOPES = ["User.Read", "Mail.Read"]

class Email(BaseModel):
    from_addr: str
    subject: str
    date: str
    preview: str

class CalendarEventRequest(BaseModel):
    title: str
    location: Optional[str] = None
    start_date: str  # ISO 8601 format
    end_date: str    # ISO 8601 format
    notes: Optional[str] = None
    all_day: bool = False

class CalendarEventResponse(BaseModel):
    success: bool
    message: str
    event_data: Optional[dict] = None

class ReminderRequest(BaseModel):
    title: str
    notes: Optional[str] = None
    due_date: Optional[str] = None  # ISO 8601 format
    priority: int = 0  # 0-9, where 0 is no priority

class ReminderResponse(BaseModel):
    success: bool
    message: str
    reminder_data: Optional[dict] = None

def get_graph_token():
    app_msal = PublicClientApplication(
        CLIENT_ID,
        authority=f"https://login.microsoftonline.com/{TENANT_ID}"
    )

    # 1. Check cache
    accounts = app_msal.get_accounts()
    result = None
    if accounts:
        result = app_msal.acquire_token_silent(SCOPES, account=accounts[0])

    # 2. Interactive login
    if not result:
        # We cannot do console interaction in a background API request easily.
        # BUT for a local tool, we can trigger the browser opening on the server side.
        flow = app_msal.initiate_device_flow(scopes=SCOPES)
        if "user_code" not in flow:
            raise ValueError("Fail to create device flow")

        print("\n" + "="*60)
        print(f"USER ACTION REQUIRED: {flow['message']}")
        print("="*60 + "\n")
        
        webbrowser.open(flow["verification_uri"])
        result = app_msal.acquire_token_by_device_flow(flow)

    if "access_token" in result:
        return result["access_token"]
    else:
        return None

@app.get("/test-emails", response_model=List[Email])
def get_test_emails():
    """
    Returns test emails for development/testing purposes.
    5 emails with event dates/times (for Calendar)
    5 emails without dates (for Reminders)
    """
    test_emails = [
        # Emails with dates/times (for Calendar)
        Email(
            from_addr="team@company.com",
            subject="Team Meeting - Q4 Planning",
            date="2024-11-25T09:00:00Z",
            preview="Join us for our quarterly planning session.\n\nEvent Time: November 25, 2024 at 2:00 PM - 3:30 PM\nLocation: Conference Room A\n\nAgenda: Review Q3 results and plan Q4 objectives."
        ),
        Email(
            from_addr="hr@company.com",
            subject="Annual Review Schedule",
            date="2024-11-23T08:30:00Z",
            preview="Your annual performance review has been scheduled.\n\nEvent Time: November 26, 2024 at 10:00 AM - 11:00 AM\nLocation: HR Office, Building 2\n\nPlease prepare your self-assessment before the meeting."
        ),
        Email(
            from_addr="dentist@healthclinic.com",
            subject="Dental Appointment Confirmation",
            date="2024-11-22T14:00:00Z",
            preview="This is a confirmation for your upcoming dental appointment.\n\nEvent Time: November 27, 2024 at 9:30 AM - 10:30 AM\nLocation: HealthClinic Dental, 123 Main St\n\nPlease arrive 10 minutes early."
        ),
        Email(
            from_addr="events@university.edu",
            subject="Guest Lecture: AI and the Future",
            date="2024-11-24T11:00:00Z",
            preview="Distinguished Professor Jane Smith will be speaking about artificial intelligence.\n\nEvent Time: November 28, 2024 at 4:00 PM - 5:30 PM\nLocation: Science Building, Auditorium 101\n\nRefreshments will be served."
        ),
        Email(
            from_addr="fitness@gym.com",
            subject="Personal Training Session",
            date="2024-11-23T07:00:00Z",
            preview="Your personal training session is confirmed!\n\nEvent Time: November 29, 2024 at 6:00 AM - 7:00 AM\nLocation: Downtown Fitness Center\n\nBring water and a towel. See you there!"
        ),

        # Emails without dates (for Reminders)
        Email(
            from_addr="boss@company.com",
            subject="Action Required: Complete Expense Report",
            date="2024-11-22T16:30:00Z",
            preview="Please submit your October expense report by end of week. Include all receipts and categorize expenses properly. Let me know if you have any questions."
        ),
        Email(
            from_addr="library@university.edu",
            subject="Book Due Soon",
            date="2024-11-23T10:00:00Z",
            preview="The following books are due soon:\n- 'Introduction to Algorithms'\n- 'Clean Code'\n\nRenew online or return to avoid late fees."
        ),
        Email(
            from_addr="netflix@streaming.com",
            subject="New Episodes Available",
            date="2024-11-24T12:00:00Z",
            preview="Season 2 of your favorite show is now available! Continue watching where you left off. Don't forget to finish the series before it leaves our platform next month."
        ),
        Email(
            from_addr="mom@family.com",
            subject="Don't Forget",
            date="2024-11-22T18:00:00Z",
            preview="Remember to call Grandma this weekend for her birthday! Also, we need to plan the family Thanksgiving dinner. Let me know your availability."
        ),
        Email(
            from_addr="store@shopping.com",
            subject="Your Order Needs Action",
            date="2024-11-23T13:45:00Z",
            preview="We need your confirmation to proceed with your recent order. Please review the items in your cart and confirm your shipping address. Order #12345"
        )
    ]

    return test_emails

@app.get("/emails", response_model=List[Email])
def get_emails():
    token = get_graph_token()
    if not token:
        raise HTTPException(status_code=401, detail="Authentication failed. Check server console.")

    endpoint = "https://graph.microsoft.com/v1.0/me/messages"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }
    params = {
        "$top": 5,
        "$orderby": "receivedDateTime desc",
        "$select": "subject,from,receivedDateTime,bodyPreview"
    }

    try:
        response = requests.get(endpoint, headers=headers, params=params)
        response.raise_for_status()
        emails_data = response.json().get("value", [])
        
        result = []
        for email in emails_data:
            from_addr = email.get('from', {}).get('emailAddress', {}).get('address', 'Unknown')
            result.append(Email(
                from_addr=from_addr,
                subject=email.get('subject', 'No Subject'),
                date=email.get('receivedDateTime', ''),
                preview=email.get('bodyPreview', '')
            ))
        return result
            
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/calendar/event", response_model=CalendarEventResponse)
def create_calendar_event(event: CalendarEventRequest):
    """
    Validates and processes calendar event data.
    The iOS app will call this endpoint to validate data before adding to EventKit.
    """
    try:
        # Validate date formats
        start_dt = datetime.fromisoformat(event.start_date.replace('Z', '+00:00'))
        end_dt = datetime.fromisoformat(event.end_date.replace('Z', '+00:00'))

        # Validate that end date is after start date
        if end_dt <= start_dt:
            return CalendarEventResponse(
                success=False,
                message="End date must be after start date"
            )

        # Process and return validated event data
        event_data = {
            "title": event.title,
            "location": event.location,
            "start_date": event.start_date,
            "end_date": event.end_date,
            "notes": event.notes,
            "all_day": event.all_day,
            "validated_at": datetime.now().isoformat()
        }

        return CalendarEventResponse(
            success=True,
            message="Event validated successfully. Ready to add to calendar.",
            event_data=event_data
        )

    except ValueError as e:
        return CalendarEventResponse(
            success=False,
            message=f"Invalid date format: {str(e)}"
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/reminders/todo", response_model=ReminderResponse)
def create_reminder(reminder: ReminderRequest):
    """
    Validates and processes reminder/to-do data.
    The iOS app will call this endpoint to validate data before adding to EventKit Reminders.
    """
    try:
        # Validate due date if provided
        if reminder.due_date:
            due_dt = datetime.fromisoformat(reminder.due_date.replace('Z', '+00:00'))

        # Validate priority (0-9)
        if reminder.priority < 0 or reminder.priority > 9:
            return ReminderResponse(
                success=False,
                message="Priority must be between 0 and 9"
            )

        # Process and return validated reminder data
        reminder_data = {
            "title": reminder.title,
            "notes": reminder.notes,
            "due_date": reminder.due_date,
            "priority": reminder.priority,
            "validated_at": datetime.now().isoformat()
        }

        return ReminderResponse(
            success=True,
            message="Reminder validated successfully. Ready to add to reminders.",
            reminder_data=reminder_data
        )

    except ValueError as e:
        return ReminderResponse(
            success=False,
            message=f"Invalid date format: {str(e)}"
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)

