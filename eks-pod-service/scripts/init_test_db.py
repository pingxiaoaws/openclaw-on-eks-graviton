#!/usr/bin/env python3
"""
Initialize test database for local testing

Creates a test database with sample data for testing billing features.
"""

import sqlite3
import os
import sys

# Add parent directory to path to import app modules
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from app.database import init_db, create_user
from app.utils.session_auth import hash_password

DB_PATH = os.environ.get('DATABASE_PATH', './test_openclaw.db')

def main():
    print("=" * 60)
    print("Initializing test database")
    print(f"Database path: {DB_PATH}")
    print("=" * 60)

    # Remove existing test database
    if os.path.exists(DB_PATH):
        print(f"Removing existing database: {DB_PATH}")
        os.remove(DB_PATH)

    # Set environment variable for init_db
    os.environ['DATABASE_PATH'] = DB_PATH

    # Initialize database (creates tables)
    print("Creating database tables...")
    init_db()

    # Create test users
    print("\nCreating test users...")

    # User 1: Admin (first user)
    user1_hash = hash_password("Admin123!")
    user1_id = create_user("admin", "admin@example.com", user1_hash)
    print(f"✅ Created admin user: admin@example.com (id: {user1_id})")

    # User 2: Regular user
    user2_hash = hash_password("User123!")
    user2_id = create_user("user1", "user1@example.com", user2_hash)
    print(f"✅ Created regular user: user1@example.com (id: {user2_id})")

    # User 3: Pro user
    user3_hash = hash_password("User123!")
    user3_id = create_user("user2", "user2@example.com", user3_hash)
    print(f"✅ Created regular user: user2@example.com (id: {user3_id})")

    # Verify users were created
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute("SELECT email, is_admin, plan FROM users")
    users = cursor.fetchall()

    print("\n" + "=" * 60)
    print("Database initialized successfully!")
    print("=" * 60)
    print("\nUsers created:")
    for email, is_admin, plan in users:
        admin_flag = " (ADMIN)" if is_admin else ""
        print(f"  - {email}: plan={plan}{admin_flag}")

    conn.close()

    print("\nYou can now run:")
    print(f"  export DATABASE_PATH={DB_PATH}")
    print("  python -m app.main")
    print("\nTest credentials:")
    print("  Admin: admin@example.com / Admin123!")
    print("  User1: user1@example.com / User123!")
    print("  User2: user2@example.com / User123!")

if __name__ == '__main__':
    main()
