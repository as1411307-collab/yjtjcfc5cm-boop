"""Encrypted, authenticated SQLite backup for a single-user deployment."""
import argparse
from contextlib import closing
import getpass
import os
import sqlite3
import sys
import tempfile
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

MAGIC = b"UAIBACKUP1"
SALT_BYTES = 16
NONCE_BYTES = 12
MAX_BACKUP_BYTES = 1024 * 1024 * 1024


def _key(password: str, salt: bytes) -> bytes:
    if len(password) < 12:
        raise ValueError("Backup password must be at least 12 characters")
    return Scrypt(salt=salt, length=32, n=2**15, r=8, p=1).derive(password.encode("utf-8"))


def _read_bounded(path: Path, limit: int, description: str) -> bytes:
    """Bound an opened file descriptor; reject pathname-swap and growth races."""
    with path.open("rb") as stream:
        size = os.fstat(stream.fileno()).st_size
        if size > limit:
            suffix = "maximum backup size" if description == "Database" else "maximum size"
            raise ValueError(f"{description} exceeds {suffix}")
        result = stream.read(size + 1)
        if len(result) != size:
            raise ValueError(f"{description} changed size during reading")
        return result


def create_backup(database: Path, destination: Path, password: str) -> None:
    if not database.is_file():
        raise FileNotFoundError(database)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise FileExistsError(f"Refusing to overwrite: {destination}")
    with tempfile.TemporaryDirectory() as folder:
        snapshot = Path(folder) / "snapshot.sqlite3"
        with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as source, closing(sqlite3.connect(snapshot)) as target:
            source.backup(target)
        plaintext = _read_bounded(snapshot, MAX_BACKUP_BYTES, "Database")
    salt, nonce = os.urandom(SALT_BYTES), os.urandom(NONCE_BYTES)
    header = MAGIC + salt + nonce
    encrypted = AESGCM(_key(password, salt)).encrypt(nonce, plaintext, header)
    # O_EXCL with mode 0o600: no permission window and no silent overwrite.
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(header + encrypted)


def restore_backup(source: Path, destination: Path, password: str) -> None:
    header_size = len(MAGIC) + SALT_BYTES + NONCE_BYTES
    payload = _read_bounded(source, MAX_BACKUP_BYTES + header_size + 16, "Backup")
    if not payload.startswith(MAGIC) or len(payload) <= header_size + 16:
        raise ValueError("Not a valid Unified AI encrypted backup")
    salt = payload[len(MAGIC):len(MAGIC) + SALT_BYTES]
    nonce = payload[len(MAGIC) + SALT_BYTES:header_size]
    plaintext = AESGCM(_key(password, salt)).decrypt(nonce, payload[header_size:], payload[:header_size])
    if not plaintext.startswith(b"SQLite format 3\x00"):
        raise ValueError("Decrypted backup is not SQLite")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise FileExistsError(f"Refusing to overwrite: {destination}")
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".restore-", delete=False) as tmp:
        temp_path = Path(tmp.name)
        tmp.write(plaintext)
    try:
        with closing(sqlite3.connect(temp_path)) as db:
            check = db.execute("PRAGMA integrity_check").fetchone()
            if check is None or check[0] != "ok":
                raise ValueError("SQLite integrity check failed")
        # Publish without overwriting a file created by another process since the guard.
        os.link(temp_path, destination)
        try:
            destination.chmod(0o600)
        except OSError:
            pass
    finally:
        temp_path.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Unified AI encrypted backups")
    parser.add_argument("action", choices=("backup", "restore"))
    parser.add_argument("--database", type=Path, default=Path(os.getenv("DB_PATH", "./data/core.sqlite3")))
    parser.add_argument("--file", type=Path, required=True)
    args = parser.parse_args()
    password = getpass.getpass("Backup password (12+ characters): ")
    try:
        if args.action == "backup":
            create_backup(args.database, args.file, password)
            print(f"Encrypted backup saved: {args.file}")
        else:
            print("Stop the API server before restoring. Restoration refuses to overwrite existing files.")
            restore_backup(args.file, args.database, password)
            print(f"Database restored: {args.database}")
    except InvalidTag:
        print("Restore failed: wrong password or corrupted backup file", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
