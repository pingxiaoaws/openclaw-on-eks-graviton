#!/usr/bin/env python3
"""
Add plan field to users table

This migration adds the 'plan' column to the users table to support
different subscription tiers (free/pro/enterprise).

Usage:
    python scripts/add_plan_field.py
"""

import sqlite3
import os
import sys
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Database path
DB_PATH = os.environ.get('DATABASE_PATH', '/app/data/openclaw.db')


def migrate():
    """Add plan field to users table"""
    logger.info("=" * 60)
    logger.info("Starting migration: Add plan field to users table")
    logger.info(f"Database path: {DB_PATH}")
    logger.info("=" * 60)

    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()

        # Check if plan column exists
        cursor.execute("PRAGMA table_info(users)")
        columns = [col[1] for col in cursor.fetchall()]

        if 'plan' not in columns:
            logger.info("Adding plan column to users table...")
            cursor.execute("ALTER TABLE users ADD COLUMN plan TEXT DEFAULT 'free'")
            conn.commit()
            logger.info("✅ Added plan column to users table")

            # Set all existing users to 'free' plan (already done by DEFAULT)
            cursor.execute("SELECT COUNT(*) FROM users")
            user_count = cursor.fetchone()[0]
            logger.info(f"✅ Set plan='free' for {user_count} existing users")
        else:
            logger.info("✓ plan column already exists")

        conn.close()

        logger.info("=" * 60)
        logger.info("✅ Migration completed successfully")
        logger.info("=" * 60)
        return 0

    except Exception as e:
        logger.error(f"❌ Migration failed: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    sys.exit(migrate())
