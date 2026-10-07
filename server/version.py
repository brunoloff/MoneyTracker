"""Fingerprint the backend source loaded by a newly started server."""
import hashlib
from pathlib import Path

def revision(root):
    root=Path(root)
    digest=hashlib.sha256()
    paths=sorted((root/'server').glob('*.py'))+[root/'scripts/bank_test.py']
    for path in paths:
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()
