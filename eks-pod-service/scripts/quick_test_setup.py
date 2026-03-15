#!/usr/bin/env python3
"""
Quick test database setup (no dependencies)

Creates a minimal test database with users and billing tables.
"""

import sqlite3
import os
from datetime import datetime

DB_PATH = os.environ.get('DATABASE_PATH', './test_openclaw.db')

def main():
    print("=" * 60)
    print("Quick Test Database Setup")
    print(f"Database path: {DB_PATH}")
    print("=" * 60)

    # Remove existing database
    if os.path.exists(DB_PATH):
        print(f"✅ Removing existing database")
        os.remove(DB_PATH)

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    # Create users table with plan field
    print("📋 Creating users table...")
    cursor.execute('''
        CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            email TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            is_admin BOOLEAN DEFAULT 0,
            plan TEXT DEFAULT 'free',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')

    cursor.execute('CREATE INDEX idx_users_email ON users(email)')

    # Insert test users (using dummy password hash)
    print("👤 Creating test users...")
    test_users = [
        ('admin', 'admin@example.com', '$2b$12$dummy_hash_admin', 1, 'free'),
        ('user1', 'user1@example.com', '$2b$12$dummy_hash_user1', 0, 'free'),
        ('user2', 'user2@example.com', '$2b$12$dummy_hash_user2', 0, 'pro'),
    ]

    for username, email, password_hash, is_admin, plan in test_users:
        cursor.execute('''
            INSERT INTO users (username, email, password_hash, is_admin, plan)
            VALUES (?, ?, ?, ?, ?)
        ''', (username, email, password_hash, is_admin, plan))
        admin_flag = " (ADMIN)" if is_admin else ""
        print(f"  ✅ {email} - plan={plan}{admin_flag}")

    # Create billing tables
    print("📋 Creating usage_events table...")
    cursor.execute('''
        CREATE TABLE usage_events (
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

    cursor.execute('''
        CREATE INDEX idx_usage_events_user_timestamp
        ON usage_events(user_id, timestamp)
    ''')

    cursor.execute('''
        CREATE INDEX idx_usage_events_created
        ON usage_events(created_at)
    ''')

    print("📋 Creating hourly_usage table...")
    cursor.execute('''
        CREATE TABLE hourly_usage (
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

    cursor.execute('''
        CREATE INDEX idx_hourly_usage_user_hour
        ON hourly_usage(user_id, hour)
    ''')

    print("📋 Creating daily_usage table...")
    cursor.execute('''
        CREATE TABLE daily_usage (
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

    cursor.execute('''
        CREATE INDEX idx_daily_usage_user_date
        ON daily_usage(user_id, date)
    ''')

    # Insert some sample usage data for user2 (pro user)
    print("📊 Inserting sample usage data...")
    from datetime import datetime, timedelta
    import hashlib

    user2_id = hashlib.sha256('user2@example.com'.encode()).hexdigest()[:8]

    # Add daily usage for last 10 days
    for i in range(10):
        date = (datetime.utcnow() - timedelta(days=i)).strftime('%Y-%m-%d')
        tokens = 50000 + (i * 10000)  # Varying usage
        cursor.execute('''
            INSERT INTO daily_usage (
                user_id, user_email, model, provider, date,
                input_tokens, output_tokens, total_tokens,
                call_count, estimated_cost
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', (
            user2_id, 'user2@example.com', 'claude-opus-4-6', 'bedrock', date,
            tokens // 2, tokens // 2, tokens,
            50 + i * 5, (tokens / 1_000_000) * 45.0  # Approximate cost
        ))

    print(f"  ✅ Added 10 days of sample usage for user2@example.com")

    conn.commit()
    conn.close()

    print("\n" + "=" * 60)
    print("✅ Test database created successfully!")
    print("=" * 60)

    # Verify
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = [row[0] for row in cursor.fetchall()]

    print(f"\n📋 Tables created: {', '.join(tables)}")

    cursor.execute("SELECT COUNT(*) FROM users")
    user_count = cursor.fetchone()[0]
    print(f"👤 Users: {user_count}")

    cursor.execute("SELECT COUNT(*) FROM daily_usage")
    usage_count = cursor.fetchone()[0]
    print(f"📊 Daily usage records: {usage_count}")

    conn.close()

    print("\n" + "=" * 60)
    print("🚀 Ready for testing!")
    print("=" * 60)
    print("\nTo start the Flask app:")
    print(f"  export DATABASE_PATH={os.path.abspath(DB_PATH)}")
    print("  export DEBUG=true")
    print("  python3 -m app.main")
    print("\nTest users:")
    print("  admin@example.com (admin, free plan)")
    print("  user1@example.com (user, free plan)")
    print("  user2@example.com (user, pro plan, with usage data)")

if __name__ == '__main__':
    main()
