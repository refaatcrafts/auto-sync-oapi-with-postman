#!/usr/bin/env python3
"""Update a Postman OpenAPI spec and its linked collection."""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class PostmanError(RuntimeError):
    """Raised when the Postman API rejects an operation."""


def api_call(api_key, method, url, payload=None):
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
            result = json.loads(response_body) if response_body else {}
            return response.status, result
    except urllib.error.HTTPError as error:
        response_body = error.read().decode()
        try:
            result = json.loads(response_body) if response_body else {}
        except json.JSONDecodeError:
            result = {"error": response_body}
        return error.code, result
    except urllib.error.URLError as error:
        raise PostmanError(f"Network request failed: {error.reason}") from error


def require_environment(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise PostmanError(f"{name} is not set")
    return value


def request_url(api_base_url, spec_id, file_path):
    encoded_path = urllib.parse.quote(file_path, safe="/")
    return f"{api_base_url}/specs/{spec_id}/files/{encoded_path}"


def sync_specification(openapi_file, wait_for_completion=True):
    api_key = require_environment("POSTMAN_API_KEY")
    api_base_url = os.environ.get("POSTMAN_API_BASE_URL", "https://api.getpostman.com").rstrip("/")
    spec_id = require_environment("POSTMAN_SPEC_ID")
    file_path = require_environment("POSTMAN_SPEC_FILE_PATH")
    collection_uid = require_environment("POSTMAN_COLLECTION_UID")

    openapi_content = Path(openapi_file).read_text(encoding="utf-8")
    status, result = api_call(
        api_key,
        "PATCH",
        request_url(api_base_url, spec_id, file_path),
        {"content": openapi_content},
    )
    if status != 200:
        raise PostmanError(
            f"Specification update returned HTTP {status}: {json.dumps(result)}"
        )

    encoded_collection_uid = urllib.parse.quote(collection_uid, safe="")
    encoded_spec_id = urllib.parse.quote(spec_id, safe="")
    sync_url = (
        f"{api_base_url}/collections/{encoded_collection_uid}/synchronizations"
        f"?specId={encoded_spec_id}"
    )
    status, result = api_call(api_key, "PUT", sync_url)
    if status != 202 or not result.get("taskId"):
        raise PostmanError(
            f"Collection synchronization returned HTTP {status}: {json.dumps(result)}"
        )

    task_id = result["taskId"]
    print(f"Specification updated: {spec_id}")
    print(f"Collection synchronization started: {collection_uid}")
    print(f"Task ID: {task_id}")

    if wait_for_completion:
        wait_for_task(api_key, api_base_url, collection_uid, task_id)


def wait_for_task(api_key, api_base_url, collection_uid, task_id):
    poll_seconds = float(os.environ.get("POSTMAN_TASK_POLL_SECONDS", "2"))
    timeout_seconds = float(os.environ.get("POSTMAN_TASK_TIMEOUT_SECONDS", "120"))
    task_url = f"{api_base_url}/collections/{collection_uid}/tasks/{task_id}"
    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline:
        status, result = api_call(api_key, "GET", task_url)
        if status != 200:
            raise PostmanError(
                f"Task status returned HTTP {status}: {json.dumps(result)}"
            )

        task_status = result.get("status")
        if task_status == "completed":
            print("Collection synchronization completed.")
            return
        if task_status in {"failed", "error"}:
            raise PostmanError(f"Collection synchronization failed: {json.dumps(result)}")

        time.sleep(poll_seconds)

    raise PostmanError(f"Collection synchronization timed out after {timeout_seconds:g}s")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openapi-file", required=True, type=Path)
    parser.add_argument(
        "--no-wait",
        action="store_true",
        help="Exit after Postman accepts the asynchronous synchronization task.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    if not args.openapi_file.is_file():
        print(f"ERROR: OpenAPI file not found: {args.openapi_file}", file=sys.stderr)
        return 1

    try:
        sync_specification(args.openapi_file, wait_for_completion=not args.no_wait)
    except (OSError, PostmanError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
