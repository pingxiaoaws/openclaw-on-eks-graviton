#!/usr/bin/env python3
"""
Billing Sidecar - reads OpenClaw session JSONL files and writes usage events to PostgreSQL.

Runs as a sidecar container alongside each OpenClaw user pod.
Tails *.jsonl files under OPENCLAW_SESSIONS_DIR, parses usage records,
and batch-inserts them into the usage_events table with idempotent upserts.

Config via env vars:
  TENANT_ID            - User/tenant identifier
  DATABASE_URL         - PostgreSQL connection string
  OPENCLAW_SESSIONS_DIR - Path to session files (default: /home/openclaw/.openclaw/agents)
  POLL_INTERVAL        - Seconds between polls (default: 5)
  BATCH_SIZE           - Max events per batch insert (default: 50)
"""

import glob
import json
import logging
import os
import signal
import sys
import time

import psycopg2

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [billing-sidecar] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logger = logging.getLogger("billing-sidecar")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TENANT_ID = os.environ.get("TENANT_ID", "unknown")
DATABASE_URL = os.environ.get("DATABASE_URL", "")
SESSIONS_DIR = os.environ.get("OPENCLAW_SESSIONS_DIR", "/home/openclaw/.openclaw/agents")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "5"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "50"))
OFFSETS_FILE = "/tmp/sidecar-offsets.json"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
offsets: dict[str, int] = {}  # filepath -> byte offset
buffer: list[tuple] = []
running = True


def load_offsets():
    global offsets
    try:
        with open(OFFSETS_FILE, "r") as f:
            offsets = json.load(f)
        logger.info("Loaded offsets for %d files", len(offsets))
    except (FileNotFoundError, json.JSONDecodeError):
        offsets = {}


def save_offsets():
    try:
        with open(OFFSETS_FILE, "w") as f:
            json.dump(offsets, f)
    except Exception as e:
        logger.warning("Failed to save offsets: %s", e)


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
_conn = None


def get_conn():
    global _conn
    if _conn is None or _conn.closed:
        _conn = psycopg2.connect(DATABASE_URL)
        _conn.autocommit = False
    return _conn


def close_conn():
    global _conn
    if _conn and not _conn.closed:
        try:
            _conn.close()
        except Exception:
            pass
    _conn = None


def flush_buffer():
    """Batch insert buffered events into usage_events table."""
    global buffer
    if not buffer:
        return

    batch = buffer[:BATCH_SIZE]
    buffer = buffer[BATCH_SIZE:]

    try:
        conn = get_conn()
        cur = conn.cursor()
        args_str = ",".join(
            cur.mogrify(
                "(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                row,
            ).decode()
            for row in batch
        )
        cur.execute(
            "INSERT INTO usage_events "
            "(tenant_id, message_id, session_id, timestamp, provider, model, "
            "input_tokens, output_tokens, cache_read, cache_write, total_tokens, cost_usd) "
            f"VALUES {args_str} "
            "ON CONFLICT (tenant_id, message_id) DO NOTHING"
        )
        conn.commit()
        logger.info("Inserted %d events (%d buffered)", len(batch), len(buffer))
    except Exception as e:
        logger.error("DB insert failed: %s", e)
        close_conn()
        # Re-queue failed batch
        buffer = batch + buffer


# ---------------------------------------------------------------------------
# JSONL parsing
# ---------------------------------------------------------------------------

def parse_line(line: str) -> tuple | None:
    """Parse a single JSONL line and return a row tuple, or None if not a usage record."""
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        return None

    if entry.get("type") != "message":
        return None

    msg = entry.get("message", {})
    usage = msg.get("usage")
    if not usage:
        return None

    cost = usage.get("cost")
    if not cost:
        return None

    message_id = entry.get("id", "")
    if not message_id:
        return None

    # Extract session_id from parentId or id
    session_id = entry.get("parentId", "")
    timestamp = entry.get("timestamp", "")
    provider = msg.get("provider", "unknown")
    model = msg.get("model", "unknown")
    input_tokens = usage.get("input", 0)
    output_tokens = usage.get("output", 0)
    cache_read = usage.get("cacheRead", 0)
    cache_write = usage.get("cacheWrite", 0)
    total_tokens = usage.get("totalTokens", 0)
    cost_usd = cost.get("total", 0)

    return (
        TENANT_ID,
        message_id,
        session_id,
        timestamp,
        provider,
        model,
        input_tokens,
        output_tokens,
        cache_read,
        cache_write,
        total_tokens,
        cost_usd,
    )


# ---------------------------------------------------------------------------
# File tailing
# ---------------------------------------------------------------------------

def scan_files():
    """Scan JSONL files, read new lines from last offset, buffer events."""
    pattern = os.path.join(SESSIONS_DIR, "**", "*.jsonl")
    files = glob.glob(pattern, recursive=True)

    for filepath in files:
        # Skip deleted session files
        if ".deleted." in filepath:
            continue

        offset = offsets.get(filepath, 0)

        try:
            size = os.path.getsize(filepath)
        except OSError:
            continue

        if size < offset:
            # File was truncated/rotated - reset
            offset = 0

        if size == offset:
            continue

        try:
            with open(filepath, "r") as f:
                f.seek(offset)
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    row = parse_line(line)
                    if row:
                        buffer.append(row)
                offsets[filepath] = f.tell()
        except Exception as e:
            logger.warning("Error reading %s: %s", filepath, e)


# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------

def shutdown(signum, frame):
    global running
    logger.info("Received signal %d, shutting down...", signum)
    running = False


signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main():
    if not DATABASE_URL:
        logger.error("DATABASE_URL is required")
        sys.exit(1)

    logger.info("Starting billing sidecar for tenant=%s dir=%s poll=%ds",
                TENANT_ID, SESSIONS_DIR, POLL_INTERVAL)

    load_offsets()

    # Wait for sessions dir to exist
    while running and not os.path.isdir(SESSIONS_DIR):
        logger.info("Waiting for sessions dir: %s", SESSIONS_DIR)
        time.sleep(POLL_INTERVAL)

    while running:
        scan_files()

        while buffer:
            flush_buffer()

        save_offsets()
        time.sleep(POLL_INTERVAL)

    # Graceful shutdown: flush remaining
    logger.info("Flushing remaining buffer (%d events)...", len(buffer))
    while buffer:
        flush_buffer()
    save_offsets()
    close_conn()
    logger.info("Billing sidecar stopped.")


if __name__ == "__main__":
    main()
