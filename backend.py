from fastapi import FastAPI, HTTPException
from msal import PublicClientApplication
import requests
import webbrowser
import json
from typing import List, Optional
from pydantic import BaseModel

app = FastAPI()

# Using "Microsoft Graph PowerShell" Client ID
CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
TENANT_ID = "common"
SCOPES = ["User.Read", "Mail.Read"]

class Email(BaseModel):
    from_addr: str
    subject: str
    date: str
    preview: str

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

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)

