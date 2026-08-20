#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_ROOT/.env" ]; then
  set -a
  source "$PROJECT_ROOT/.env"
  set +a
else
  echo "ERROR: .env file not found at $PROJECT_ROOT/.env"
  exit 1
fi

for var in POSTMAN_API_KEY POSTMAN_SPEC_ID POSTMAN_SPEC_FILE_PATH POSTMAN_COLLECTION_UID; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set in .env"
    exit 1
  fi
done

OPENAPI_FILE="$PROJECT_ROOT/openapi.yml"
if [ ! -f "$OPENAPI_FILE" ]; then
  echo "ERROR: openapi.yml not found at $OPENAPI_FILE"
  exit 1
fi

export OPENAPI_FILE
echo "Updating Postman specification from openapi.yml..."

python3 << 'PYTHON_SCRIPT'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

api_key = os.environ["POSTMAN_API_KEY"]
api_base_url = os.environ.get("POSTMAN_API_BASE_URL", "https://api.getpostman.com").rstrip("/")
spec_id = os.environ["POSTMAN_SPEC_ID"]
file_path = os.environ["POSTMAN_SPEC_FILE_PATH"]
collection_uid = os.environ["POSTMAN_COLLECTION_UID"]

with open(os.environ["OPENAPI_FILE"], "r", encoding="utf-8") as openapi_file:
    openapi_content = openapi_file.read()

def api_call(method, url, payload=None):
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={"X-API-Key": api_key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            response_body = response.read().decode()
            return response.status, json.loads(response_body) if response_body else {}
    except urllib.error.HTTPError as error:
        response_body = error.read().decode()
        try:
            result = json.loads(response_body) if response_body else {}
        except json.JSONDecodeError:
            result = {"error": response_body}
        return error.code, result
    except urllib.error.URLError as error:
        return 599, {"error": str(error.reason)}

encoded_file_path = urllib.parse.quote(file_path, safe="/")
file_url = f"{api_base_url}/specs/{spec_id}/files/{encoded_file_path}"
status, result = api_call("PATCH", file_url, {"content": openapi_content})
if status != 200:
    print(f"ERROR: Specification update returned HTTP {status}")
    print(json.dumps(result, indent=2))
    sys.exit(1)

encoded_collection_uid = urllib.parse.quote(collection_uid, safe="")
sync_url = f"{api_base_url}/collections/{encoded_collection_uid}/synchronizations?specId={urllib.parse.quote(spec_id, safe='')}"
status, result = api_call("PUT", sync_url)
if status != 202:
    print(f"ERROR: Collection synchronization returned HTTP {status}")
    print(json.dumps(result, indent=2))
    sys.exit(1)

print(f"Specification updated: {spec_id}")
print(f"Collection synchronization started: {collection_uid}")
if result.get("taskId"):
    print(f"Task ID: {result['taskId']}")
PYTHON_SCRIPT
