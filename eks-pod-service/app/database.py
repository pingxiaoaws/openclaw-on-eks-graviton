"""Database initialization and connection"""
import sqlite3
import os
import logging
from typing import Optional

logger = logging.getLogger(__name__)

# Database file location
DB_PATH = os.environ.get('DATABASE_PATH', '/app/data/openclaw.db')

def get_db_connection():
    """Get a database connection"""
    # Ensure the data directory exists
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row  # Enable dict-like access
    return conn

def init_db():
    """Initialize the database with tables"""
    conn = get_db_connection()
    cursor = conn.cursor()

    # Create users table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS users (
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

    # Create index on email for faster lookups
    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)
    ''')

    conn.commit()
    conn.close()

    logger.info(f"✅ Database initialized at {DB_PATH}")

def get_user_by_email(email: str) -> Optional[dict]:
    """Get user by email"""
    conn = get_db_connection()
    cursor = conn.cursor()

    cursor.execute('SELECT * FROM users WHERE email = ?', (email,))
    row = cursor.fetchone()

    conn.close()

    if row:
        return dict(row)
    return None

def get_user_by_username(username: str) -> Optional[dict]:
    """Get user by username"""
    conn = get_db_connection()
    cursor = conn.cursor()

    cursor.execute('SELECT * FROM users WHERE username = ?', (username,))
    row = cursor.fetchone()

    conn.close()

    if row:
        return dict(row)
    return None

def create_user(username: str, email: str, password_hash: str) -> int:
    """Create a new user"""
    conn = get_db_connection()
    cursor = conn.cursor()

    # Check if this is the first user - make them admin
    cursor.execute('SELECT COUNT(*) FROM users')
    user_count = cursor.fetchone()[0]
    is_admin = 1 if user_count == 0 else 0

    cursor.execute('''
        INSERT INTO users (username, email, password_hash, is_admin)
        VALUES (?, ?, ?, ?)
    ''', (username, email, password_hash, is_admin))

    user_id = cursor.lastrowid
    conn.commit()
    conn.close()

    admin_msg = " (ADMIN)" if is_admin else ""
    logger.info(f"✅ Created user: {username} ({email}){admin_msg}")
    return user_id

def insert_usage_event(event: dict) -> int:
    """Insert a usage event into the database"""
    conn = get_db_connection()
    cursor = conn.cursor()

    cursor.execute('''
        INSERT INTO usage_events (
            user_id, user_email, model, provider,
            input_tokens, output_tokens, cache_read, cache_write, total_tokens,
            timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', (
        event['user_id'],
        event['user_email'],
        event['model'],
        event['provider'],
        event['input_tokens'],
        event['output_tokens'],
        event['cache_read'],
        event['cache_write'],
        event['total_tokens'],
        event['timestamp']
    ))

    event_id = cursor.lastrowid
    conn.commit()
    conn.close()

    return event_id

def get_user_usage_summary(user_id: str, days: int = 30) -> dict:
    """
    Get usage summary for a user over the last N days

    Returns:
        {
            'total_tokens': int,
            'input_tokens': int,
            'output_tokens': int,
            'total_calls': int,
            'estimated_cost': float,
            'by_model': [{'provider': str, 'model': str, 'total_tokens': int, 'estimated_cost': float}, ...],
            'daily': [{'date': str, 'total_tokens': int, 'estimated_cost': float}, ...]
        }
    """
    conn = get_db_connection()
    cursor = conn.cursor()

    # Overall summary
    cursor.execute('''
        SELECT
            SUM(total_tokens) as total_tokens,
            SUM(input_tokens) as input_tokens,
            SUM(output_tokens) as output_tokens,
            SUM(call_count) as total_calls,
            SUM(estimated_cost) as estimated_cost
        FROM daily_usage
        WHERE user_id = ? AND date >= date('now', ? || ' days')
    ''', (user_id, -days))

    summary_row = cursor.fetchone()
    summary = {
        'total_tokens': summary_row[0] or 0,
        'input_tokens': summary_row[1] or 0,
        'output_tokens': summary_row[2] or 0,
        'total_calls': summary_row[3] or 0,
        'estimated_cost': summary_row[4] or 0.0
    }

    # By model breakdown
    cursor.execute('''
        SELECT
            provider,
            model,
            SUM(total_tokens) as total_tokens,
            SUM(estimated_cost) as estimated_cost
        FROM daily_usage
        WHERE user_id = ? AND date >= date('now', ? || ' days')
        GROUP BY provider, model
        ORDER BY total_tokens DESC
    ''', (user_id, -days))

    by_model = [
        {
            'provider': row[0],
            'model': row[1],
            'total_tokens': row[2],
            'estimated_cost': row[3]
        }
        for row in cursor.fetchall()
    ]

    # Daily breakdown
    cursor.execute('''
        SELECT
            date,
            SUM(total_tokens) as total_tokens,
            SUM(estimated_cost) as estimated_cost
        FROM daily_usage
        WHERE user_id = ? AND date >= date('now', ? || ' days')
        GROUP BY date
        ORDER BY date ASC
    ''', (user_id, -days))

    daily = [
        {
            'date': row[0],
            'total_tokens': row[1],
            'estimated_cost': row[2]
        }
        for row in cursor.fetchall()
    ]

    conn.close()

    return {
        'summary': summary,
        'by_model': by_model,
        'daily': daily
    }

def get_all_users_with_usage(days: int = 30) -> list:
    """
    Get all users with their usage stats (admin only)

    Returns:
        [{'user_id': str, 'email': str, 'username': str, 'created_at': str,
          'usage_30d': {'total_tokens': int, 'estimated_cost': float}}, ...]
    """
    conn = get_db_connection()
    cursor = conn.cursor()

    # Get all users with their usage
    cursor.execute('''
        SELECT
            u.email,
            u.username,
            u.created_at,
            COALESCE(SUM(d.total_tokens), 0) as total_tokens,
            COALESCE(SUM(d.estimated_cost), 0.0) as estimated_cost
        FROM users u
        LEFT JOIN daily_usage d ON u.email = d.user_email
            AND d.date >= date('now', ? || ' days')
        GROUP BY u.email, u.username, u.created_at
        ORDER BY u.created_at DESC
    ''', (-days,))

    users = [
        {
            'email': row[0],
            'username': row[1],
            'created_at': row[2],
            'usage_30d': {
                'total_tokens': row[3],
                'estimated_cost': row[4]
            }
        }
        for row in cursor.fetchall()
    ]

    conn.close()
    return users

def cleanup_old_usage_events(days: int = 7):
    """Delete usage_events older than N days"""
    conn = get_db_connection()
    cursor = conn.cursor()

    cursor.execute('''
        DELETE FROM usage_events
        WHERE created_at < datetime('now', ? || ' days')
    ''', (-days,))

    deleted_count = cursor.rowcount
    conn.commit()
    conn.close()

    logger.info(f"✅ Cleaned up {deleted_count} old usage events (>{days} days)")
    return deleted_count
