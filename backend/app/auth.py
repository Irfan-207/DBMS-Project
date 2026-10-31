import base64
import hashlib
import hmac
import secrets


_PASSWORD_ITERATIONS = 390_000


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, _PASSWORD_ITERATIONS)
    encode = lambda value: base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")
    return f"pbkdf2_sha256${_PASSWORD_ITERATIONS}${encode(salt)}${encode(digest)}"


def verify_password(password: str, password_hash: str) -> bool:
    try:
        algorithm, iterations, encoded_salt, encoded_digest = password_hash.split("$")
        if algorithm != "pbkdf2_sha256":
            return False
        rounds = int(iterations)
        if not 100_000 <= rounds <= 1_000_000:
            return False
        decode = lambda value: base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        salt = decode(encoded_salt)
        expected = decode(encoded_digest)
    except (ValueError, TypeError):
        return False

    actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, rounds)
    return hmac.compare_digest(actual, expected)


def hash_session_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def new_session_token() -> str:
    return secrets.token_urlsafe(32)


def new_csrf_token() -> str:
    return secrets.token_urlsafe(32)


DUMMY_PASSWORD_HASH = hash_password(secrets.token_urlsafe(32))
