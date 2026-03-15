#!/usr/bin/env python3
"""
Database migration script for billing features

This script:
1. Adds is_admin column to users table
2. Creates usage_events table (raw events, 7-day retention)
3. Creates hourly_usage table (aggregated by hour)
4. Creates daily_usage table (aggregated by day)
5. Creates indexes for query performance

Usage:
    python scripts/migrate_billing.py
"""

import sqlite3
import os
import sys
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Database path
DB_PATH = os.environ.get('DATABASE_PATH', '/app/data/openclaw.db')

def get_db_connection():
    """Get database connection"""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def migrate_users_table(conn):
    """Add is_admin column to users table"""
    cursor = conn.cursor()

    # Check if is_admin column exists
    cursor.execute("PRAGMA table_info(users)")
    columns = [column[1] for column in cursor.fetchall()]

    if 'is_admin' not in columns:
        logger.info("Adding is_admin column to users table...")
        cursor.execute('ALTER TABLE users ADD COLUMN is_admin BOOLEAN DEFAULT 0')
        conn.commit()
        logger.info("✅ Added is_admin column")
    else:
        logger.info("✓ is_admin column already exists")

def create_usage_events_table(conn):
    """Create usage_events table for raw event data"""
    cursor = conn.cursor()

    logger.info("Creating usage_events table...")
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS usage_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            user_email TEXT NOT NULL,
            model TEXT NOT NULL,
            provider TEXT NOT NULL,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read INTEGER DEFAULT 0,
            cache_write INTEGER DEFAULT 0,
            total_tokens INTEGER DEFAULT 0,
            timestamp BIGINT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

            FOREIGN KEY (user_email) REFERENCES users(email)
        )
    ''')

    # Create indexes
    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_usage_events_user_timestamp
        ON usage_events(user_id, timestamp)
    ''')

    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_usage_events_created
        ON usage_events(created_at)
    ''')

    conn.commit()
    logger.info("✅ Created usage_events table")

def create_hourly_usage_table(conn):
    """Create hourly_usage table for aggregated data"""
    cursor = conn.cursor()

    logger.info("Creating hourly_usage table...")
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS hourly_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            user_email TEXT NOT NULL,
            model TEXT NOT NULL,
            provider TEXT NOT NULL,
            hour TIMESTAMP NOT NULL,
            input_tokens BIGINT DEFAULT 0,
            output_tokens BIGINT DEFAULT 0,
            cache_read BIGINT DEFAULT 0,
            cache_write BIGINT DEFAULT 0,
            total_tokens BIGINT DEFAULT 0,
            call_count INTEGER DEFAULT 0,
            estimated_cost REAL DEFAULT 0.0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

            UNIQUE(user_id, model, provider, hour),
            FOREIGN KEY (user_email) REFERENCES users(email)
        )
    ''')

    # Create index
    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_hourly_usage_user_hour
        ON hourly_usage(user_id, hour)
    ''')

    conn.commit()
    logger.info("✅ Created hourly_usage table")

def create_daily_usage_table(conn):
    """Create daily_usage table for aggregated data"""
    cursor = conn.cursor()

    logger.info("Creating daily_usage table...")
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS daily_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            user_email TEXT NOT NULL,
            model TEXT NOT NULL,
            provider TEXT NOT NULL,
            date DATE NOT NULL,
            input_tokens BIGINT DEFAULT 0,
            output_tokens BIGINT DEFAULT 0,
            cache_read BIGINT DEFAULT 0,
            cache_write BIGINT DEFAULT 0,
            total_tokens BIGINT DEFAULT 0,
            call_count INTEGER DEFAULT 0,
            estimated_cost REAL DEFAULT 0.0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

            UNIQUE(user_id, model, provider, date),
            FOREIGN KEY (user_email) REFERENCES users(email)
        )
    ''')

    # Create index
    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_daily_usage_user_date
        ON daily_usage(user_id, date)
    ''')

    conn.commit()
    logger.info("✅ Created daily_usage table")

def verify_migration(conn):
    """Verify all tables were created successfully"""
    cursor = conn.cursor()

    # Check tables
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = [row[0] for row in cursor.fetchall()]

    required_tables = ['users', 'usage_events', 'hourly_usage', 'daily_usage']
    missing_tables = [t for t in required_tables if t not in tables]

    if missing_tables:
        logger.error(f"❌ Missing tables: {missing_tables}")
        return False

    # Check is_admin column
    cursor.execute("PRAGMA table_info(users)")
    columns = [column[1] for column in cursor.fetchall()]
    if 'is_admin' not in columns:
        logger.error("❌ is_admin column not found in users table")
        return False

    logger.info("✅ Migration verification passed")
    return True

def main():
    """Run database migration"""
    logger.info("=" * 60)
    logger.info("Starting billing database migration")
    logger.info(f"Database path: {DB_PATH}")
    logger.info("=" * 60)

    try:
        conn = get_db_connection()

        # Run migrations
        migrate_users_table(conn)
        create_usage_events_table(conn)
        create_hourly_usage_table(conn)
        create_daily_usage_table(conn)

        # Verify migration
        if verify_migration(conn):
            logger.info("=" * 60)
            logger.info("✅ Billing database migration completed successfully")
            logger.info("=" * 60)
            conn.close()
            return 0
        else:
            logger.error("❌ Migration verification failed")
            conn.close()
            return 1

    except Exception as e:
        logger.error(f"❌ Migration failed: {e}")
        import traceback
        traceback.print_exc()
        return 1

if __name__ == '__main__':
    sys.exit(main())
