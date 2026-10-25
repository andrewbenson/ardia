import hashlib
import os
import stat
import sys

root = sys.argv[1]
skipped_at_top = set(sys.argv[2:])
digest = hashlib.sha256()


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def record(kind, rel, payload):
    digest.update(f"{kind}\0{rel}\0{payload}\n".encode("utf-8", "surrogateescape"))


def walk(rel):
    here = os.path.join(root, rel) if rel else root
    for name in sorted(os.listdir(here)):
        if not rel and name in skipped_at_top:
            continue
        child = os.path.join(rel, name) if rel else name
        path = os.path.join(root, child)
        mode = os.lstat(path).st_mode
        if stat.S_ISLNK(mode):
            record("l", child, os.readlink(path))
        elif stat.S_ISDIR(mode):
            record("d", child, "")
            walk(child)
        elif stat.S_ISREG(mode):
            record("x" if mode & 0o111 else "f", child, file_sha256(path))
        else:
            sys.exit(f"tree-digest: {path} is neither a file, a directory nor a symlink")


if not os.path.isdir(root):
    sys.exit(f"tree-digest: no directory {root}")
walk("")
print(digest.hexdigest())
