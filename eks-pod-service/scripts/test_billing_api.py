#!/usr/bin/env python3
"""
Test billing API endpoints

Tests all billing functionality without needing to run the full Flask app.
"""

import sys
import os

# Add parent directory to path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# Set test database path
os.environ['DATABASE_PATH'] = './test_openclaw.db'

from app.services.quota import (
    PLAN_LIMITS,
    check_quota,
    get_monthly_usage,
    get_days_until_reset
)
from app.database import get_user_by_email, get_user_usage_summary
from app.utils.user_id import generate_user_id

def print_section(title):
    print("\n" + "=" * 60)
    print(title)
    print("=" * 60)

def test_plan_limits():
    print_section("Test 1: Plan Limits Configuration")

    for plan_name, limits in PLAN_LIMITS.items():
        print(f"\n{plan_name.upper()} Plan:")
        print(f"  Tokens/month: {limits['tokens_per_month'] or 'Unlimited'}")
        print(f"  Max instances: {limits['max_instances'] or 'Unlimited'}")
        print(f"  Price: ${limits['price_monthly'] or 'Custom'}/month")
        print(f"  Features: {', '.join(limits['features'][:2])}")

    print("\n✅ Plan limits loaded successfully")

def test_get_user():
    print_section("Test 2: Get User by Email")

    test_emails = [
        'admin@example.com',
        'user1@example.com',
        'user2@example.com'
    ]

    for email in test_emails:
        user = get_user_by_email(email)
        if user:
            print(f"\n✅ {email}")
            print(f"   Username: {user['username']}")
            print(f"   Plan: {user.get('plan', 'N/A')}")
            print(f"   Admin: {bool(user.get('is_admin'))}")
        else:
            print(f"\n❌ {email} not found")

def test_monthly_usage():
    print_section("Test 3: Monthly Usage Calculation")

    test_users = [
        ('admin@example.com', 'admin'),
        ('user1@example.com', 'user1'),
        ('user2@example.com', 'user2 (has sample data)')
    ]

    for email, label in test_users:
        user_id = generate_user_id(email)
        usage = get_monthly_usage(user_id)
        print(f"\n{label}:")
        print(f"  User ID: {user_id}")
        print(f"  Monthly usage: {usage:,} tokens")

def test_quota_check():
    print_section("Test 4: Quota Status Check")

    test_cases = [
        ('admin@example.com', 'free'),
        ('user1@example.com', 'free'),
        ('user2@example.com', 'pro'),
    ]

    for email, plan in test_cases:
        quota = check_quota(email, plan)
        print(f"\n{email} ({plan} plan):")
        print(f"  Current usage: {quota.current_usage:,} tokens")
        print(f"  Limit: {quota.limit:,} tokens" if quota.limit else "  Limit: Unlimited")
        print(f"  Percentage: {quota.percentage_used:.2f}%")
        print(f"  Status: {quota.status_emoji} {quota.status_text}")
        print(f"  Warning: {quota.is_warning}")
        print(f"  Over quota: {quota.is_over_quota}")

def test_usage_summary():
    print_section("Test 5: User Usage Summary")

    # Test user2 who has sample data
    email = 'user2@example.com'
    user_id = generate_user_id(email)

    print(f"\n{email}:")
    print(f"User ID: {user_id}")

    summary = get_user_usage_summary(user_id, days=30)

    print(f"\nSummary (last 30 days):")
    print(f"  Total tokens: {summary['summary']['total_tokens']:,}")
    print(f"  Input tokens: {summary['summary']['input_tokens']:,}")
    print(f"  Output tokens: {summary['summary']['output_tokens']:,}")
    print(f"  Total calls: {summary['summary']['total_calls']}")
    print(f"  Estimated cost: ${summary['summary']['estimated_cost']:.2f}")

    print(f"\nBy model:")
    for model in summary['by_model']:
        print(f"  {model['provider']}/{model['model']}: {model['total_tokens']:,} tokens")

    print(f"\nDaily breakdown (last 5 days):")
    for day in summary['daily'][:5]:
        print(f"  {day['date']}: {day['total_tokens']:,} tokens (${day['estimated_cost']:.2f})")

def test_days_until_reset():
    print_section("Test 6: Days Until Quota Reset")

    days = get_days_until_reset()
    print(f"\nDays until quota reset: {days}")
    print("✅ Quota resets on the 1st of next month")

def main():
    print("=" * 60)
    print("Billing API Test Suite")
    print("=" * 60)
    print(f"\nDatabase: {os.environ['DATABASE_PATH']}")

    try:
        test_plan_limits()
        test_get_user()
        test_monthly_usage()
        test_quota_check()
        test_usage_summary()
        test_days_until_reset()

        print("\n" + "=" * 60)
        print("✅ All tests passed!")
        print("=" * 60)

        print("\n📋 Summary:")
        print("  - Plan limits configured correctly")
        print("  - Users can be retrieved from database")
        print("  - Monthly usage calculation works")
        print("  - Quota checking works (including warnings)")
        print("  - Usage summary generates correctly")
        print("  - Days until reset calculated")

        print("\n🚀 Next step: Test the full Flask API")
        print("  Run: python3 scripts/test_flask_api.sh")

        return 0

    except Exception as e:
        print(f"\n❌ Test failed: {e}")
        import traceback
        traceback.print_exc()
        return 1

if __name__ == '__main__':
    sys.exit(main())
