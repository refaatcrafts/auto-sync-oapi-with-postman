# OpenAPI to Postman sync

This project updates a Postman collection generated from an OpenAPI specification. The local `openapi.yml` file is uploaded to Postman, then the linked collection is synchronized from that specification.

## Configuration

The sync command reads these environment variables:

```text
POSTMAN_API_KEY
POSTMAN_SPEC_ID
POSTMAN_SPEC_FILE_PATH
POSTMAN_COLLECTION_UID
POSTMAN_API_BASE_URL              # optional; defaults to https://api.getpostman.com
POSTMAN_TASK_POLL_SECONDS         # optional; defaults to 2
POSTMAN_TASK_TIMEOUT_SECONDS      # optional; defaults to 120
```

For local use, copy `.env.example` to `.env`. The Bash launcher loads `.env` when it exists; CI should provide the variables as protected secrets and variables instead.

## Run locally

```bash
bash scripts/sync-postman.sh
```

The command waits for Postman’s asynchronous collection task and exits non-zero when the task fails or times out. Use `--no-wait` only when the CI job intentionally delegates task monitoring elsewhere.

## CI setup

Run `bash scripts/sync-postman.sh` after checking out the repository. Configure `POSTMAN_API_KEY` as a masked secret. Configure the specification ID, collection UID, and remote specification file path as protected CI variables.

The Postman API key must have permission to update the specification and collection. The collection must be generated from the configured specification. Enable **Remove orphan requests** in the Postman specification’s collection sync settings if deleted OpenAPI operations should also be removed from the collection.

The script uses Postman’s specification file update endpoint, then the specification-to-collection synchronization endpoint. It does not create or replace a separate collection.
