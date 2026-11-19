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
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

MAGIC = b"UAIBACKUP1"
SALT_BYTES = 16
NONCE_BYTES = 12
CHUNK_BYTES = 1024 * 1024
TAG_BYTES = 16
MAX_BACKUP_BYTES = 1024 * 1024 * 1024


def _key(password: str, salt: bytes) -> bytes:
    if len(password) < 12:
        raise ValueError("Backup password must be at least 12 characters")
    return Scrypt(salt=salt, length=32, n=2**15, r=8, p=1).derive(password.encode("utf-8"))


def _transform(source, destination, cipher, size: int) -> None:
    while size:
        block = source.read(min(size, CHUNK_BYTES))
        if not block:
            raise ValueError("File changed size during reading")
        destination.write(cipher.update(block))
        size -= len(block)


def _prepare_destination(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(f"Refusing to overwrite: {path}")


def create_backup(database: Path, destination: Path, password: str) -> None:
    if not database.is_file():
        raise FileNotFoundError(database)
    _prepare_destination(destination)
    salt, nonce = os.urandom(SALT_BYTES), os.urandom(NONCE_BYTES)
    header = MAGIC + salt + nonce
    encryptor = Cipher(algorithms.AES(_key(password, salt)), modes.GCM(nonce)).encryptor()
    encryptor.authenticate_additional_data(header)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".backup-") as folder:
        snapshot = Path(folder) / "snapshot.sqlite3"
        uri = database.resolve().as_uri() + "?mode=ro"
        with closing(sqlite3.connect(uri, uri=True)) as source, closing(sqlite3.connect(snapshot)) as target:
            source.backup(target)
        with snapshot.open("rb") as source, tempfile.NamedTemporaryFile(dir=folder, delete=False) as output:
            size = os.fstat(source.fileno()).st_size
            if size > MAX_BACKUP_BYTES:
                raise ValueError("Database exceeds maximum backup size")
            output.write(header)
            _transform(source, output, encryptor, size)
            if source.read(1):
                raise ValueError("Database changed size during reading")
            output.write(encryptor.finalize())
            output.write(encryptor.tag)
        os.link(output.name, destination)


def restore_backup(source: Path, destination: Path, password: str) -> None:
    header_size = len(MAGIC) + SALT_BYTES + NONCE_BYTES
    with source.open("rb") as stream:
        size = os.fstat(stream.fileno()).st_size
        if size > MAX_BACKUP_BYTES + header_size + TAG_BYTES:
            raise ValueError("Backup exceeds maximum size")
        header = stream.read(header_size)
        if not header.startswith(MAGIC) or size <= header_size + TAG_BYTES:
            raise ValueError("Not a valid Unified AI encrypted backup")
        salt, nonce = header[len(MAGIC):-NONCE_BYTES], header[-NONCE_BYTES:]
        decryptor = Cipher(algorithms.AES(_key(password, salt)), modes.GCM(nonce)).decryptor()
        decryptor.authenticate_additional_data(header)
        _prepare_destination(destination)
        # The temporary directory and file are owner-only. The candidate is never
        # opened by SQLite or published until the complete GCM tag is verified.
        with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".restore-") as folder:
            with tempfile.NamedTemporaryFile(dir=folder, delete=False) as output:
                _transform(stream, output, decryptor, size - header_size - TAG_BYTES)
                tag = stream.read(TAG_BYTES)
                if len(tag) != TAG_BYTES or stream.read(1):
                    raise ValueError("Backup changed size during reading")
                output.write(decryptor.finalize_with_tag(tag))
                output.seek(0)
                if output.read(16) != b"SQLite format 3\x00":
                    raise ValueError("Decrypted backup is not SQLite")
            with closing(sqlite3.connect(output.name)) as db:
                result = db.execute("PRAGMA integrity_check").fetchone()
                if result is None or result[0] != "ok":
                    raise ValueError("SQLite integrity check failed")
            os.link(output.name, destination)


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
