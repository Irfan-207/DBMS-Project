from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from app.auth import hash_password, hash_session_token, new_session_token, verify_password  # noqa: E402
from app.schemas import LoginRequest, PasswordChange, TeacherAccountCreate  # noqa: E402
from pydantic import ValidationError  # noqa: E402


def test_passwords_are_hashed_and_verified():
    encoded = hash_password("a-long-unique-password")
    assert encoded != "a-long-unique-password"
    assert verify_password("a-long-unique-password", encoded)
    assert not verify_password("wrong-password", encoded)


def test_malformed_password_hash_is_rejected():
    assert not verify_password("password", "not-a-password-hash")


def test_session_tokens_are_random_and_stored_as_hashes():
    first = new_session_token()
    second = new_session_token()
    assert first != second
    assert hash_session_token(first) != first
    assert len(hash_session_token(first)) == 64


def test_login_requires_email_and_password():
    with pytest.raises(ValidationError):
        LoginRequest(email="not-an-email", password="anything")


def test_teacher_account_password_requires_minimum_length():
    with pytest.raises(ValidationError):
        TeacherAccountCreate(password="short")


def test_password_change_requires_current_and_strong_new_password():
    with pytest.raises(ValidationError):
        PasswordChange(current_password="old", new_password="short")
