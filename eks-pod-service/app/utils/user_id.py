"""User ID generation utilities"""
import hashlib

def generate_user_id(email: str) -> str:
    """
    Generate a user ID from email address

    Args:
        email: User email address

    Returns:
        8-character user ID (MD5 hash prefix)
    """
    return hashlib.md5(email.encode()).hexdigest()[:8]
