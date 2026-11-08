#!/usr/bin/env python3
"""Check Git publication candidates without printing matched secret values.

No third-party services or device access. Before git init, an isolated temporary
repository evaluates the real working tree's .gitignore. Tracked ignored files
are still checked. This is a narrow disclosure check, not a security audit.
"""
import argparse
import fnmatch
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


LOCAL_DIRECTORIES = {".state", ".build", ".venv", "dist", ".pytest_cache", ".swiftpm", "__pycache__", ".git", ".aws", ".ssh"}
LOCAL_DOCUMENTS = {
    "docs/实现进度.md", "docs/虚拟定位-实现方案-v1.1.md",
    "docs/坐标偏移修复验证-2026-11-08.md", "docs/坐标偏移原因复核-2026-11-08.md",
}
PRIVATE_NAMES = ("*.pem", "*.key", "*.p12", "*.pfx", "*.mobileprovision", "*.shsh", "*.shsh2", "*.log", "*.crash", "*.ips",
                 ".netrc", ".pypirc", ".npmrc", "id_rsa", "id_ed25519")
ENV_EXAMPLES = {".env.example", ".env.sample", ".env.template"}
PATTERNS = {
    "private-key": re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
    "provider-token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{30,})\b"),
    "credential-in-url": re.compile(r"https?://[^\s/:@]+:[^\s/@]+@"),
    "personal-home-path": re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+/"),
    "device-udid": re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"),
    "device-identifier-value": re.compile(r'''(?i)(?:UDID|UniqueDeviceID|SerialNumber|ApECID|ECID|ApNonce|BootNonce|SEPNonce)["']?\s*[:=]\s*["']?(?:[0-9a-f]{12,}|[0-9]{8,})\b'''),
    "credential-literal": re.compile(r'''(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password|passwd)\s*[:=]\s*["'][^"'\n]{8,}["']'''),
}


def git_environment():
    env = dict(os.environ)
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS="0")
    # Do not let a caller's Git overrides redirect the inspected repository.
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
        env.pop(key, None)
    return env


def candidate_files(root):
    root = Path(root).resolve()
    env = git_environment()
    existing = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"],
                              env=env, capture_output=True, text=True)
    def listing(command):
        result = subprocess.run(command + ["-c", "core.excludesFile=" + os.devnull,
                                "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                                env=env, check=True, capture_output=True)
        return sorted(set(os.fsdecode(p) for p in result.stdout.split(b"\0") if p))
    if existing.returncode == 0 and Path(existing.stdout.strip()).resolve() == root:
        return listing(["git", "-C", str(root)]), True
    with tempfile.TemporaryDirectory(prefix="virtual-location-publication-") as temporary:
        subprocess.run(["git", "-c", "init.templateDir=", "init", "--quiet", temporary],
                       env=env, check=True, capture_output=True)
        return listing(["git", "--git-dir=" + str(Path(temporary) / ".git"), "--work-tree=" + str(root)]), False


def private_path(name):
    path = Path(name)
    return (bool(set(path.parts) & LOCAL_DIRECTORIES) or name in LOCAL_DOCUMENTS
            or any(fnmatch.fnmatch(path.name, pattern) for pattern in PRIVATE_NAMES)
            or (path.name.startswith(".env") and path.name not in ENV_EXAMPLES))


def check_files(root, names, snapshot=None):
    findings = []
    for name in names:
        path = root / name
        if private_path(name):
            findings.append((name, 0, "local-file-in-publication"))
            continue
        if path.is_symlink() or root not in path.resolve().parents:
            findings.append((name, 0, "symlink-or-outside-project"))
            continue
        if not path.exists():  # A tracked file deleted in the working tree.
            continue
        if not path.is_file():
            findings.append((name, 0, "unsupported-file-type"))
            continue
        if path.stat().st_size > 10 * 1024 * 1024:
            findings.append((name, 0, "large-file-needs-manual-review"))
            continue
        data = path.read_bytes()
        if snapshot is not None:
            snapshot[name] = data
        if path.suffix.lower() in {".png", ".pdf", ".icns"}:
            # Generated brand assets still must not embed personal home paths.
            content = data.decode("latin-1")
            patterns = {"personal-home-path": PATTERNS["personal-home-path"]}
        else:
            try:
                content = data.decode("utf-8")
            except UnicodeDecodeError:
                findings.append((name, 0, "unreviewed-binary"))
                continue
            patterns = PATTERNS
        for kind, pattern in patterns.items():
            for match in pattern.finditer(content):
                findings.append((name, content.count("\n", 0, match.start()) + 1, kind))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Write a clean source ZIP only if checks pass")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    names, has_git = candidate_files(root)
    snapshot = {}
    findings = check_files(root, names, snapshot)
    print(f"Checked {len(names)} Git publication candidates; Git history {'not inspected' if has_git else 'absent (directory has no Git repository)' }.")
    for name, line, kind in findings:
        print(f"REVIEW {name}:{line}: {kind}")
    if findings:
        print("No archive written. Matched values are intentionally omitted.")
        return 1
    print("No matching disclosure patterns found. Ignored local data is excluded; this is not a guarantee of no secrets.")
    if args.archive:
        output = args.archive.resolve()
        if output == root or root not in output.parents or output.suffix.lower() != ".zip":
            parser.error("archive must be a .zip inside this project")
        if output.relative_to(root).parts[0] != "dist":
            parser.error("put archives in ignored dist/ to avoid later publishing generated bundles")
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in snapshot.items():
                archive.writestr("virtual-location/" + name, data)
        print("Clean source archive:", output.relative_to(root))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
