"""Verify a learning ZIP on a Mac without a server, API key, or dependencies."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

MAX_EVENT_BYTES = 5_000_000


def verify(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        if sorted(archive.namelist()) != ["events.jsonl", "manifest.json"]:
            raise ValueError("Expected exactly one manifest and one event stream")
        if archive.getinfo("manifest.json").file_size > 16_384:
            raise ValueError("Manifest too large")
        if archive.getinfo("events.jsonl").file_size > MAX_EVENT_BYTES:
            raise ValueError("Event stream too large")
        manifest = json.loads(archive.read("manifest.json"))
        if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
            raise ValueError("Unsupported manifest")
        previous = manifest.get("after_id")
        if type(previous) is not int or previous < 0:
            raise ValueError("Invalid starting cursor")
        checksum = hashlib.sha256()
        count = 0
        category = manifest.get("category")
        with archive.open("events.jsonl") as stream:
            for line in stream:
                checksum.update(line)
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise ValueError("Invalid event")
                identifier = event.get("id")
                if type(identifier) is not int or identifier <= previous:
                    raise ValueError("Invalid event order")
                if category is not None and event.get("category") != category:
                    raise ValueError("Event outside the selected category")
                if not manifest.get("include_content") and ("input_text" in event or "output_text" in event):
                    raise ValueError("Transcript fields in a metadata-only export")
                previous = identifier
                count += 1
        if count != manifest.get("record_count") or previous != manifest.get("next_after_id"):
            raise ValueError("Manifest and event page disagree")
        expected = manifest.get("events_sha256")
        if "events_sha256" in manifest and checksum.hexdigest() != expected:
            raise ValueError("Event checksum mismatch")
    return {"events": count, "next_after_id": previous, "category": category,
            "checksum": "matched" if expected else "absent in legacy manifest"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.archive), ensure_ascii=False))
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        parser.exit(1, f"Invalid export: {exc}\n")


if __name__ == "__main__":
    main()
