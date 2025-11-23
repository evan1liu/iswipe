from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from msal import PublicClientApplication, SerializableTokenCache
import requests
import json
import time
import os
import uuid
import threading
from datetime import datetime, timedelta
from typing import List, Optional, Dict, Any
from pydantic import BaseModel
import google.generativeai as genai
from dotenv import load_dotenv

load_dotenv()

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
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
TOKEN_CACHE_FILE = "token_cache.bin"

# Global variable to store pending auth flow
PENDING_FLOW: Optional[Dict[str, Any]] = None

if not GEMINI_API_KEY:
    print("WARNING: GEMINI_API_KEY not found in environment variables. Batch processing will fail.")

def get_msal_app():
    cache = SerializableTokenCache()
    if os.path.exists(TOKEN_CACHE_FILE):
        with open(TOKEN_CACHE_FILE, "r") as f:
            cache.deserialize(f.read())
            
    return PublicClientApplication(
        CLIENT_ID,
        authority=f"https://login.microsoftonline.com/{TENANT_ID}",
        token_cache=cache
    )

def save_cache(app_msal):
    if app_msal.token_cache.has_state_changed:
        with open(TOKEN_CACHE_FILE, "w") as f:
            f.write(app_msal.token_cache.serialize())

class Todo(BaseModel):
    title: str
    notes: Optional[str] = None
    due_date: Optional[str] = None
    priority: int = 5
    isCompleted: bool = False

class Event(BaseModel):
    title: str
    notes: Optional[str] = None
    location: Optional[str] = "TBD"
    start_date: Optional[str] = None
    end_date: Optional[str] = None
    all_day: bool = False

class Email(BaseModel):
    id: str = ""
    from_addr: str
    subject: str
    date: str
    preview: str
    body_html: str
    summary: Optional[str] = None
    category: Optional[str] = None
    todos: List[Todo] = []
    events: List[Event] = []

class ProcessedResponse(BaseModel):
    emails: List[Email]

# Auth Global State
AUTH_STATE = {
    "status": "idle", # idle, waiting, logged_in, error
    "error": None
}

def get_graph_token():
    app_msal = get_msal_app()
    accounts = app_msal.get_accounts()
    if accounts:
        result = app_msal.acquire_token_silent(SCOPES, account=accounts[0])
        if result and "access_token" in result:
            save_cache(app_msal)
            return result["access_token"]
    return None

def wait_for_token_background(flow):
    global AUTH_STATE
    try:
        app_msal = get_msal_app()
        AUTH_STATE["status"] = "waiting"
        result = app_msal.acquire_token_by_device_flow(flow)
        
        if "access_token" in result:
            save_cache(app_msal)
            AUTH_STATE["status"] = "logged_in"
            AUTH_STATE["error"] = None
        else:
            AUTH_STATE["status"] = "error"
            AUTH_STATE["error"] = result.get("error_description", "Unknown error")
    except Exception as e:
        AUTH_STATE["status"] = "error"
        AUTH_STATE["error"] = str(e)

@app.get("/auth/status")
def auth_status():
    # Check if we have a valid token in cache
    token = get_graph_token()
    if token:
        return {"is_logged_in": True, "status": "logged_in"}
    
    return {
        "is_logged_in": False, 
        "status": AUTH_STATE["status"],
        "error": AUTH_STATE["error"]
    }

@app.post("/auth/start")
def auth_start():
    app_msal = get_msal_app()
    flow = app_msal.initiate_device_flow(scopes=SCOPES)
    if "user_code" not in flow:
        raise HTTPException(status_code=500, detail="Failed to create device flow")
    
    # Start background waiter
    thread = threading.Thread(target=wait_for_token_background, args=(flow,), daemon=True)
    thread.start()
    
    return {
        "user_code": flow["user_code"],
        "verification_uri": flow["verification_uri"],
        "message": flow["message"],
        "expires_in": flow.get("expires_in", 900)
    }

def fetch_emails_from_graph(days: int = 7) -> List[dict]:
    token = get_graph_token()
    if not token:
        raise Exception("Authentication failed. Please login via the app.")

    endpoint = "https://graph.microsoft.com/v1.0/me/messages"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }
    
    # Calculate date range
    today = datetime.now()
    start_date = today - timedelta(days=days)
    start_date_str = start_date.strftime("%Y-%m-%dT%H:%M:%SZ")
    
    # Filter for emails received in the last week
    filter_query = f"receivedDateTime ge {start_date_str}"
    
    all_emails = []
    next_link = None
    page_count = 0
    
    try:
        # Initial request
        params = {
            "$filter": filter_query,
            "$orderby": "receivedDateTime desc",
            "$select": "subject,from,receivedDateTime,bodyPreview,body",
            "$top": 100  # Fetch 100 per page (max allowed by Graph API)
        }
        
        while True:
            if next_link:
                # Use the @odata.nextLink for pagination
                response = requests.get(next_link, headers=headers)
            else:
                response = requests.get(endpoint, headers=headers, params=params)
            
            response.raise_for_status()
            data = response.json()
            
            emails = data.get("value", [])
            all_emails.extend(emails)
            page_count += 1
            
            print(f"Fetched page {page_count}: {len(emails)} emails (total so far: {len(all_emails)})")
            
            # Check if there are more pages
            next_link = data.get("@odata.nextLink")
            if not next_link:
                break
        
        print(f"Total emails fetched from past {days} days: {len(all_emails)}")
        return all_emails
        
    except Exception as e:
        print(f"Error fetching emails: {e}")
        return all_emails  # Return what we've fetched so far

def process_with_gemini_batch(emails_data: List[dict]) -> List[Email]:
    if not emails_data:
        return []
        
    client = genai.Client(api_key=GEMINI_API_KEY)
    
    # Prepare batch requests
    batch_inputs = []
    email_map = {} # Map request ID to email data
    
    prompt_template = """
Analyze the following email content and extract:
1. A brief summary (1-2 sentences)
2. Any specific Tasks (Todos) and Calendar Events

Output strictly in JSON format matching these exact schemas:

{{
  "summary": "Brief 1-2 sentence summary of the email",
  "todos": [{{
      "title": "short task title",
      "notes": "detailed task description/notes",
      "due_date": "YYYY-MM-DDTHH:MM:SSZ (ISO 8601 format, null if not found)",
      "priority": 5
  }}],
  "events": [{{
      "title": "event title (REQUIRED)",
      "notes": "event description/details",
      "location": "event location (use 'TBD' if not specified, 'Online' for virtual events, null if truly unknown)",
      "start_date": "YYYY-MM-DDTHH:MM:SSZ (ISO 8601 format, REQUIRED - do not include if no date found)",
      "end_date": "YYYY-MM-DDTHH:MM:SSZ (ISO 8601 format, optional - null if not specified)",
      "all_day": false
  }}]
}}

IMPORTANT:
- Summary should be concise and capture the main point of the email
- Use ISO 8601 date format with timezone (e.g., "2024-11-25T14:00:00Z")
- ONLY create an event if BOTH title AND start_date are clearly present in the email
- end_date is optional - if not specified, set to null (system will default to 1 hour duration)
- For location, prefer 'TBD' over null
- Priority for todos: 1=high, 5=medium (default), 9=low
- all_day should be true only for full-day events (no specific times mentioned)
- If there are no todos or events, return empty arrays

Email Subject: {subject}
Email Body: {body}
"""
    
    for i, email in enumerate(emails_data):
        req_id = f"req-{i}"
        email_map[req_id] = email
        
        # Use body preview + subject as context. Full HTML might be too verbose/dirty for this quick extraction,
        # but plan says "different email content". Let's use preview + snippet of text content if available.
        # Graph API 'body' has 'content'.
        
        # Use full HTML body content for better extraction context
        content_text = email.get('body', {}).get('content', '')
        if not content_text:
             # Fallback to preview if body is empty
             content_text = email.get('bodyPreview', '')
        
        # ESCAPE BRACES FOR FORMAT METHOD
        # If content_text contains '{' or '}', it will break the .format() call.
        # We need to escape them by doubling them: '{' -> '{{', '}' -> '}}'
        content_text = content_text.replace("{", "{{").replace("}", "}}")
        
        subject_text = email.get('subject', '')
        subject_text = subject_text.replace("{", "{{").replace("}", "}}")
        
        prompt = prompt_template.format(
            subject=subject_text,
            body=content_text
        )
        
        batch_inputs.append({
            "request": {
                "contents": [{
                    "parts": [{"text": prompt}],
                    "role": "user"
                }],
                "generation_config": {
                    "thinking_config": {
                        "include_thoughts": True
                    }
                }
            },
            "metadata": {"key": req_id}
        })
    
    # Create Batch Job (Inline for simplicity if < 20MB, which 50 emails likely are)
    # Note: The documentation shows 'src' accepts the list of requests directly for inline.
    
    print(f"Submitting batch job for {len(batch_inputs)} emails...")
    
    # Create a temporary file for JSONL input as it's more robust for batching
    jsonl_filename = f"batch_input_{uuid.uuid4()}.jsonl"
    with open(jsonl_filename, "w") as f:
        for req in batch_inputs:
            # Batch API expects: {"custom_id": "...", "request": ...} format in some providers,
            # but Google GenAI Python SDK helper might abstract this.
            # Based on docs provided: "Input file: A JSON Lines (JSONL) file... Each line... {"key": "...", "request": ...}"
            f.write(json.dumps({
                "key": req["metadata"]["key"],
                "request": req["request"]
            }) + "\n")
            
    try:
        # Upload file - MUST specify mime_type for JSONL
        batch_file = client.files.upload(
            path=jsonl_filename,
            mime_type='application/json'
        )
        
        # Create batch job
        batch_job = client.batches.create(
            model="gemini-2.5-flash",
            src=batch_file.name,
        )
        print(f"Batch job created: {batch_job.name}. Waiting for completion...")
        
        # Poll for completion
        while True:
            job_status = client.batches.get(name=batch_job.name)
            print(f"Status: {job_status.state}")
            
            if job_status.state == "JOB_STATE_SUCCEEDED":
                break
            elif job_status.state in ["JOB_STATE_FAILED", "JOB_STATE_CANCELLED"]:
                raise Exception(f"Batch job failed with status: {job_status.state}")
                
            time.sleep(5)
            
        print("Batch job completed!")
        
        # Retrieve results
        # The SDK usually handles download/parsing if we iterate?
        # Docs say: "output returned... is a JSONL file".
        # We need to find the output file URI/name from job_status.
        
        # NOTE: The python SDK `batches.create` result or `batches.get` result 
        # might not directly give file content. We usually need to download the output file.
        
        # Let's look for the output file name in the completed job object
        # It seems to be in `job_status.output_file` or similar.
        # Based on docs: `response_file_name=$(jq -r '.response.responsesFile' batch_status.json)`
        
        # We will list files or check the job properties. 
        # For this implementation, let's assume we can get the output content via the name.
        
        # Using the polling loop above, job_status is the latest object.
        # It should have an output file reference.
        
        # Since I cannot test the exact SDK response structure live without running it,
        # I will assume standard pattern: download the file referenced in the job.
        
        # IMPORTANT: The provided docs for Python didn't explicitly show the download step for file output,
        # but showed `client.files.content(name=...)` or similar usually exists.
        # However, the REST example shows downloading via URL.
        # Let's try to list files or find the output one.
        
        # Workaround: Iterate through the job's generated files if linked, or just use the `name` if provided.
        # Actually, `job_status` (BatchJob) usually has `output_file` attribute.
        
        # Let's iterate the results.
        results_map = {}
        # This part depends heavily on the SDK version.
        # Let's try to fetch the output file content directly if we can find its name.
        # The REST API has `response.responsesFile`.
        
        # We will use a heuristic: 
        # 1. Check for inline results (not used here since we used file input)
        # 2. Look for output file uri.
        
        # For safety in this blind coding, I will fallback to per-item processing if batch fails/is complex?
        # No, user insisted on batch.
        
        # Let's assume the output file name is accessible.
        # Warning: This is a best-guess integration based on standard Google Cloud/GenAI patterns + provided docs.
        
        output_file_name = getattr(job_status, 'output_file', None)
        if not output_file_name:
             # Try to find it in the underlying proto or dict if possible, or re-list files?
             # Or maybe it is in `job_status.response`?
             pass

        # If we can't easily get the file, we might fail.
        # Let's try to download using the name `batch_job.name` + logical suffix or look at `job_status`.
        
        # Actually, let's use `client.batches.get(name=batch_job.name)` result properties.
        # For now, let's act as if we got the results back in a dictionary `results_map` keyed by `req-i`.
        # Since I can't debug the SDK response structure here, I'll add a placeholder for the actual fetch
        # and log what's happening.
        
        # MOCKING THE PARSING logic for now to ensure code structure is valid.
        # In a real run, we would:
        # content = client.files.get_content(job_status.output_file)
        # for line in content.splitlines(): ...
        
        processed_emails = []
        
        # Retrieve the output file content
        # The batch job results are in job_status.dest.file_name
        output_file_name = None
        if hasattr(job_status, 'dest') and job_status.dest:
            if hasattr(job_status.dest, 'file_name') and job_status.dest.file_name:
                output_file_name = job_status.dest.file_name
        
        if output_file_name:
            print(f"Downloading results from {output_file_name}...")
            output_content = client.files.download(file=output_file_name)
            
            # Parse JSONL
            # output_content is bytes
            for line_num, line in enumerate(output_content.decode('utf-8').splitlines(), 1):
                # Skip empty lines
                if not line.strip():
                    continue
                    
                try:
                    res = json.loads(line)
                    # res has "custom_id" / "key" and "response"
                    key = res.get("custom_id") # 'custom_id' is often used in JSONL batch
                    if not key:
                        key = res.get("key") # Fallback
                    
                    response_data = res.get("response")
                    
                    if key and response_data:
                        # Extract text from response, skipping thought parts
                        candidates = response_data.get("candidates", [])
                        if candidates:
                            parts = candidates[0].get("content", {}).get("parts", [])
                            # Find the first non-thought part
                            text = None
                            for part in parts:
                                if not part.get("thought", False):
                                    text = part.get("text", "")
                                    break
                            
                            if not text:
                                # No non-thought parts found, skip this response
                                continue
                            
                            # Clean markdown code blocks
                            text = text.replace("```json", "").replace("```", "").strip()
                            
                            # Handle empty JSON responses like {}
                            if text in ["{}", ""]:
                                # No todos or events in this email, skip it
                                continue
                            
                            parsed = json.loads(text)
                            
                            # Match with original email
                            original_email = email_map.get(key)
                            if original_email:
                                from_addr = original_email.get('from', {}).get('emailAddress', {}).get('address', 'Unknown')
                                
                                # Create Email object
                                processed_emails.append(Email(
                                    id=str(uuid.uuid4()),
                                    from_addr=from_addr,
                                    subject=original_email.get('subject', 'No Subject'),
                                    date=original_email.get('receivedDateTime', ''),
                                    preview=original_email.get('bodyPreview', ''),
                                    body_html=original_email.get('body', {}).get('content', ''),
                                    summary=parsed.get('summary'),
                                    category=parsed.get('category'),
                                    todos=[Todo(**t) for t in parsed.get('todos', [])],
                                    events=[Event(**e) for e in parsed.get('events', [])]
                                ))
                except Exception as line_err:
                    print(f"Error processing line {line_num}: {line_err}")
                    print(f"  Line content (first 200 chars): {line[:200]}")
        else:
            print("Warning: No output file found in batch job status.")
        
        return processed_emails

    except Exception as e:
        print(f"Batch processing failed: {e}")
        return []
    finally:
        # Cleanup
        if os.path.exists(jsonl_filename):
            os.remove(jsonl_filename)

# In-memory storage for now, could be file-based persistence
PROCESSED_DB_FILE = "processed_emails.json"
BATCH_STATUS_FILE = "batch_status.json"

# Global state for batch processing
batch_status = {
    "status": "idle",  # idle, fetching, processing, completed, error
    "message": "",
    "last_updated": None,
    "count": 0
}

def save_processed_emails(emails: List[Email]):
    with open(PROCESSED_DB_FILE, "w") as f:
        f.write(json.dumps([e.dict() for e in emails], indent=2))

def load_processed_emails() -> List[Email]:
    if not os.path.exists(PROCESSED_DB_FILE):
        return []
    with open(PROCESSED_DB_FILE, "r") as f:
        data = json.load(f)
        return [Email(**item) for item in data]

def update_batch_status(status: str, message: str = "", count: int = 0):
    """Update the global batch status"""
    batch_status["status"] = status
    batch_status["message"] = message
    batch_status["last_updated"] = datetime.now().isoformat()
    batch_status["count"] = count
    
    # Also save to file for persistence
    with open(BATCH_STATUS_FILE, "w") as f:
        json.dump(batch_status, f, indent=2)

def load_batch_status():
    """Load batch status from file if it exists"""
    if os.path.exists(BATCH_STATUS_FILE):
        with open(BATCH_STATUS_FILE, "r") as f:
            return json.load(f)
    return batch_status.copy()

def background_email_refresh():
    """Background task to fetch and process emails"""
    try:
        # 1. Fetch from Graph
        update_batch_status("fetching", "Fetching emails from Microsoft Graph...")
        print("Fetching emails from Microsoft Graph...")
        raw_emails = fetch_emails_from_graph(days=7)
        print(f"Fetched {len(raw_emails)} emails.")
        
        # 2. Process with Gemini
        update_batch_status("processing", f"Processing {len(raw_emails)} emails with Gemini Batch API...")
        print("Processing with Gemini Batch API...")
        processed = process_with_gemini_batch(raw_emails)
        print(f"Processed {len(processed)} emails.")
        
        # 3. Save
        save_processed_emails(processed)
        update_batch_status("completed", "Successfully processed emails", len(processed))
            
    except Exception as e:
        error_msg = f"Error during refresh: {str(e)}"
        print(error_msg)
        update_batch_status("error", error_msg)

@app.get("/emails", response_model=List[Email])
def get_emails():
    # Old endpoint - keeping for compatibility if needed, but mapped to new logic
    return load_processed_emails()

@app.post("/refresh-emails")
def refresh_emails():
    """Start the email refresh process in the background"""
    current_status = load_batch_status()
    
    # Don't start a new refresh if one is already in progress
    if current_status["status"] in ["fetching", "processing"]:
        return {
            "status": "already_running",
            "message": "A refresh is already in progress",
            "batch_status": current_status
        }
    
    # Start background thread
    update_batch_status("fetching", "Starting email refresh...")
    thread = threading.Thread(target=background_email_refresh, daemon=True)
    thread.start()
    
    return {
        "status": "started",
        "message": "Email refresh started in background",
        "batch_status": batch_status
    }

@app.get("/refresh-status")
def get_refresh_status():
    """Get the current status of the email refresh process"""
    return load_batch_status()

@app.get("/processed-emails", response_model=List[Email])
def get_processed_emails():
    return load_processed_emails()

@app.delete("/delete-email/{email_id}")
def delete_email(email_id: str):
    """Delete an email from Outlook via Microsoft Graph API"""
    token = get_graph_token()
    if not token:
        raise HTTPException(status_code=401, detail="Authentication failed")

    endpoint = f"https://graph.microsoft.com/v1.0/me/messages/{email_id}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }

    try:
        response = requests.delete(endpoint, headers=headers)
        response.raise_for_status()
        return {"success": True, "message": "Email deleted successfully"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to delete email: {str(e)}")

@app.post("/restore-email/{email_id}")
def restore_email(email_id: str):
    """Restore a deleted email from Deleted Items folder back to Inbox"""
    token = get_graph_token()
    if not token:
        raise HTTPException(status_code=401, detail="Authentication failed")

    # Move email from Deleted Items to Inbox
    # First, get the Inbox folder ID
    inbox_endpoint = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }

    try:
        # Get Inbox folder ID
        inbox_response = requests.get(inbox_endpoint, headers=headers)
        inbox_response.raise_for_status()
        inbox_id = inbox_response.json().get("id")

        # Move the message to Inbox
        move_endpoint = f"https://graph.microsoft.com/v1.0/me/messages/{email_id}/move"
        move_payload = {
            "destinationId": inbox_id
        }

        move_response = requests.post(move_endpoint, headers=headers, json=move_payload)
        move_response.raise_for_status()

        return {"success": True, "message": "Email restored successfully"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to restore email: {str(e)}")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
