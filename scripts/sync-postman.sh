#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load .env file
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -a
  source "$PROJECT_ROOT/.env"
  set +a
else
  echo "ERROR: .env file not found at $PROJECT_ROOT/.env"
  exit 1
fi

# Validate required vars
for var in POSTMAN_API_KEY POSTMAN_WORKSPACE_ID POSTMAN_COLLECTION_UID; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set in .env"
    exit 1
  fi
done

OPENAPI_FILE="$PROJECT_ROOT/openapi.yml"
export OPENAPI_FILE

if [ ! -f "$OPENAPI_FILE" ]; then
  echo "ERROR: openapi.yml not found at $OPENAPI_FILE"
  exit 1
fi

echo "Syncing openapi.yml to Postman collection..."

python3 << 'PYTHON_SCRIPT'
import json
import urllib.request
import sys
import os

api_key = os.environ["POSTMAN_API_KEY"]
collection_uid = os.environ["POSTMAN_COLLECTION_UID"]
openapi_file = os.environ["OPENAPI_FILE"]
api_base_url = os.environ.get("POSTMAN_API_BASE_URL", "https://api.getpostman.com").rstrip("/")

# Read the OpenAPI file
with open(openapi_file, "r") as f:
    openapi_content = f.read()

def api_call(method, url, data=None):
    headers = {"X-API-Key": api_key, "Content-Type": "application/json"}
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode()
            return resp.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            result = json.loads(body) if body else {}
        except json.JSONDecodeError:
            result = {"error": body}
        return e.code, result
    except urllib.error.URLError as e:
        return 599, {"error": str(e.reason)}

print("Importing openapi.yml to generate the updated collection...")
import_payload = json.dumps({
    "type": "string",
    "input": openapi_content
}).encode("utf-8")

import_url = f"{api_base_url}/import/openapi?workspace={os.environ['POSTMAN_WORKSPACE_ID']}"
status, result = api_call("POST", import_url, import_payload)

if status != 200 or not result.get("collections"):
    print(f"ERROR: Import returned HTTP {status}")
    print(json.dumps(result, indent=2))
    sys.exit(1)

generated_collection = result["collections"][0]
generated_uid = generated_collection.get("uid")
print(f"  Generated collection: {generated_collection.get('name', '<unnamed>')}")

print("Reading the existing Postman collection...")
status, result = api_call("GET", f"{api_base_url}/collections/{collection_uid}")
if status != 200 or not result.get("collection"):
    print(f"ERROR: Collection read returned HTTP {status}")
    print(json.dumps(result, indent=2))
    sys.exit(1)

existing_collection = result["collection"]

def request_key(item):
    request = item.get("request")
    if not isinstance(request, dict):
        return None
    url = request.get("url")
    if isinstance(url, dict):
        url = url.get("raw")
    if not url:
        return None
    return request.get("method", "GET").upper() + " " + url

def merge_items(generated_items, existing_items):
    existing_by_name = {
        item.get("name"): item
        for item in existing_items
        if "item" in item and item.get("name")
    }
    existing_by_request = {
        request_key(item): item
        for item in existing_items
        if request_key(item)
    }
    merged = []
    for generated_item in generated_items:
        if "item" in generated_item:
            existing_item = existing_by_name.get(generated_item.get("name"), {})
            generated_item["item"] = merge_items(
                generated_item.get("item", []),
                existing_item.get("item", []),
            )
            merged.append(generated_item)
            continue

        existing_item = existing_by_request.get(request_key(generated_item))
        if existing_item:
            if "response" in existing_item:
                generated_item["response"] = existing_item["response"]
            if "event" in existing_item:
                generated_item["event"] = existing_item["event"]
        merged.append(generated_item)
    return merged

generated_collection["item"] = merge_items(
    generated_collection.get("item", []),
    existing_collection.get("item", []),
)

def remove_postman_ids(value):
    if isinstance(value, dict):
        return {
            key: remove_postman_ids(item)
            for key, item in value.items()
            if key not in {"id", "uid", "postman_id"}
        }
    if isinstance(value, list):
        return [remove_postman_ids(item) for item in value]
    return value

generated_collection = remove_postman_ids(generated_collection)
print("Updating the configured Postman collection in place...")
update_payload = json.dumps({"collection": generated_collection}).encode("utf-8")
update_url = f"{api_base_url}/collections/{collection_uid}"
status, result = api_call("PUT", update_url, update_payload)

if status in (200, 202):
    if generated_uid:
        cleanup_status, _ = api_call("DELETE", f"{api_base_url}/collections/{generated_uid}")
        if cleanup_status not in (200, 204):
            print(f"Warning: could not remove temporary collection (HTTP {cleanup_status})")
    print(f"Successfully synced openapi.yml to collection {collection_uid} (HTTP {status})")
else:
    print(f"ERROR: Collection update returned HTTP {status}")
    print(json.dumps(result, indent=2))
    sys.exit(1)
PYTHON_SCRIPT
