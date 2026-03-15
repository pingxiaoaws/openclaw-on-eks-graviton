"""Database initialization and connection - PostgreSQL version"""
import psycopg2
import psycopg2.extras
import os
import logging
from typing import Optional

logger = logging.getLogger(__name__)

# PostgreSQL connection configuration from environment
DB_CONFIG = {
    'host': os.environ.get('POSTGRES_HOST', 'postgres'),
    'port': int(os.environ.get('POSTGRES_PORT', '5432')),
    'database': os.environ.get('POSTGRES_DB', 'openclaw'),
    'user': os.environ.get('POSTGRES_USER', 'openclaw'),
    'password': os.environ.get('POSTGRES_PASSWORD', 'OpenClaw2026!SecureDB')
}

def get_db_connection():
    """Get a PostgreSQL database connection"""
    conn = psycopg2.connect(**DB_CONFIG)
    return conn

def init_db():
    """Initialize the database with tables"""
    conn = get_db_connection()
    cursor = conn.cursor()

    # Create users table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS users (
            id SERIAL PRIMARY KEY,
            username TEXT UNIQUE NOT NULL,
            email TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            is_admin BOOLEAN DEFAULT FALSE,
            plan TEXT DEFAULT 'free',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')

    # Create index on email for faster lookups
    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)
    ''')

    # Create usage_events table (for Phase 1 billing - future use)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS usage_events (
            id SERIAL PRIMARY KEY,
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
        CREATE INDEX IF NOT EXISTS idx_usage_events_user_timestamp
        ON usage_events(user_id, timestamp)
    ''')

    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_usage_events_created
        ON usage_events(created_at)
    ''')

    # Create hourly_usage table (aggregated by hour)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS hourly_usage (
            id SERIAL PRIMARY KEY,
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
        CREATE INDEX IF NOT EXISTS idx_hourly_usage_user_hour
        ON hourly_usage(user_id, hour)
    ''')

    # Create daily_usage table (aggregated by day)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS daily_usage (
            id SERIAL PRIMARY KEY,
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
        CREATE INDEX IF NOT EXISTS idx_daily_usage_user_date
        ON daily_usage(user_id, date)
    ''')

    # Create sessions table for Flask-Session
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS sessions (
            id SERIAL PRIMARY KEY,
            session_id VARCHAR(255) UNIQUE NOT NULL,
            data BYTEA,
            expiry TIMESTAMP
        )
    ''')

    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_sessions_session_id
        ON sessions(session_id)
    ''')

    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_sessions_expiry
        ON sessions(expiry)
    ''')

    conn.commit()
    cursor.close()
    conn.close()

    logger.info(f"✅ Database initialized at {DB_CONFIG['host']}:{DB_CONFIG['port']}/{DB_CONFIG['database']}")

def get_user_by_email(email: str) -> Optional[dict]:
    """Get user by email"""
    conn = get_db_connection()
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    cursor.execute('SELECT * FROM users WHERE email = %s', (email,))
    row = cursor.fetchone()

    cursor.close()
    conn.close()

    if row:
        return dict(row)
    return None

def get_user_by_username(username: str) -> Optional[dict]:
    """Get user by username"""
    conn = get_db_connection()
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    cursor.execute('SELECT * FROM users WHERE username = %s', (username,))
    row = cursor.fetchone()

    cursor.close()
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
    is_admin = True if user_count == 0 else False

    cursor.execute('''
        INSERT INTO users (username, email, password_hash, is_admin)
        VALUES (%s, %s, %s, %s)
        RETURNING id
    ''', (username, email, password_hash, is_admin))

    user_id = cursor.fetchone()[0]
    conn.commit()
    cursor.close()
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
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        RETURNING id
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

    event_id = cursor.fetchone()[0]
    conn.commit()
    cursor.close()
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
            COALESCE(SUM(total_tokens), 0) as total_tokens,
            COALESCE(SUM(input_tokens), 0) as input_tokens,
            COALESCE(SUM(output_tokens), 0) as output_tokens,
            COALESCE(SUM(call_count), 0) as total_calls,
            COALESCE(SUM(estimated_cost), 0.0) as estimated_cost
        FROM daily_usage
        WHERE user_id = %s AND date >= CURRENT_DATE - INTERVAL '%s days'
    ''', (user_id, days))

    summary_row = cursor.fetchone()
    summary = {
        'total_tokens': int(summary_row[0]),
        'input_tokens': int(summary_row[1]),
        'output_tokens': int(summary_row[2]),
        'total_calls': int(summary_row[3]),
        'estimated_cost': float(summary_row[4])
    }

    # By model breakdown
    cursor.execute('''
        SELECT
            provider,
            model,
            SUM(total_tokens) as total_tokens,
            SUM(estimated_cost) as estimated_cost
        FROM daily_usage
        WHERE user_id = %s AND date >= CURRENT_DATE - INTERVAL '%s days'
        GROUP BY provider, model
        ORDER BY total_tokens DESC
    ''', (user_id, days))

    by_model = [
        {
            'provider': row[0],
            'model': row[1],
            'total_tokens': int(row[2]),
            'estimated_cost': float(row[3])
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
        WHERE user_id = %s AND date >= CURRENT_DATE - INTERVAL '%s days'
        GROUP BY date
        ORDER BY date ASC
    ''', (user_id, days))

    daily = [
        {
            'date': str(row[0]),
            'total_tokens': int(row[1]),
            'estimated_cost': float(row[2])
        }
        for row in cursor.fetchall()
    ]

    cursor.close()
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
            AND d.date >= CURRENT_DATE - INTERVAL '%s days'
        GROUP BY u.email, u.username, u.created_at
        ORDER BY u.created_at DESC
    ''', (days,))

    users = [
        {
            'email': row[0],
            'username': row[1],
            'created_at': str(row[2]),
            'usage_30d': {
                'total_tokens': int(row[3]),
                'estimated_cost': float(row[4])
            }
        }
        for row in cursor.fetchall()
    ]

    cursor.close()
    conn.close()
    return users

def cleanup_old_usage_events(days: int = 7):
    """Delete usage_events older than N days"""
    conn = get_db_connection()
    cursor = conn.cursor()

    cursor.execute('''
        DELETE FROM usage_events
        WHERE created_at < CURRENT_TIMESTAMP - INTERVAL '%s days'
    ''', (days,))

    deleted_count = cursor.rowcount
    conn.commit()
    cursor.close()
    conn.close()

    logger.info(f"✅ Cleaned up {deleted_count} old usage events (>{days} days)")
    return deleted_count
