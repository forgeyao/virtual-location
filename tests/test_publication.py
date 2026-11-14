"""Exercise publication boundaries with synthetic secrets, never real devices."""
import runpy
import subprocess
from pathlib import Path


checker = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/check-publication.py"))


def test_ignore_rules_exclude_local_files_before_git_init(tmp_path):
    rules = Path(__file__).resolve().parents[1] / ".gitignore"
    (tmp_path / ".gitignore").write_text(rules.read_text())
    local = [".state/session.json", ".state/favorites.json", ".build/diagnostic.txt", "dist/Test.app/Contents/Info.plist",
             ".venv/example", ".env", ".env.local", "private.pem", "phone.log", "docs/实现进度.md",
             "docs/坐标偏移原因复核-2026-11-08.md", "__pycache__/cache.pyc", "ios/pairing.plist",
             "ios/device.mobiledevicepairing", "ios/App.xcodeproj/xcuserdata/local.xcuserdatad/Settings.plist"]
    for name in local:
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("private fixture")
    (tmp_path / "README.md").write_text("Public source")
    (tmp_path / ".env.example").write_text("OPTION=")
    files, has_git = checker["candidate_files"](tmp_path)
    assert not has_git and not (tmp_path / ".git").exists()
    assert set(files) == {".gitignore", "README.md", ".env.example"}
    assert checker["check_files"](tmp_path, files) == []


def test_tracked_ignored_file_is_detected(tmp_path):
    env = checker["git_environment"]()
    subprocess.run(["git", "-c", "init.templateDir=", "init", "--quiet", str(tmp_path)], env=env, check=True)
    (tmp_path / ".gitignore").write_text(".env\n")
    (tmp_path / ".env").write_text("private fixture")
    subprocess.run(["git", "-C", str(tmp_path), "add", "-f", ".env"], env=env, check=True)
    files, has_git = checker["candidate_files"](tmp_path)
    assert has_git and ".env" in files
    assert (".env", 0, "local-file-in-publication") in checker["check_files"](tmp_path, files)


def test_findings_never_include_secret_values(tmp_path):
    token = "gh" + "p_" + "A" * 36
    private_key = "-----BEGIN " + "PRIVATE KEY-----"
    home_path = "/" + "Users/fixture/work/file"
    (tmp_path / "bad.txt").write_text(token + "\n" + private_key + "\n" + home_path)
    findings = checker["check_files"](tmp_path, ["bad.txt"])
    assert {finding[2] for finding in findings} == {"provider-token", "private-key", "personal-home-path"}
    assert token not in repr(findings) and private_key not in repr(findings) and home_path not in repr(findings)


def test_symlink_cannot_export_files(tmp_path):
    (tmp_path / "source.txt").write_text("public")
    (tmp_path / "link.txt").symlink_to(tmp_path / "source.txt")
    assert checker["check_files"](tmp_path, ["link.txt"]) == [("link.txt", 0, "symlink-or-outside-project")]


def test_archive_snapshot_uses_checked_content(tmp_path):
    path = tmp_path / "source.txt"
    path.write_text("public")
    snapshot = {}
    assert checker["check_files"](tmp_path, ["source.txt"], snapshot) == []
    path.write_text("changed after review")
    assert snapshot == {"source.txt": b"public"}
