"""Build a local development app bundle, deliberately using the project's Python env."""
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
app = root / "dist" / "虚拟定位.app"
macos = app / "Contents" / "MacOS"
resources = app / "Contents" / "Resources"
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
for language, name in (("zh-Hans", "虚拟定位"), ("en", "Virtual Location")):
    localization = resources / f"{language}.lproj"
    localization.mkdir(parents=True, exist_ok=True)
    (localization / "InfoPlist.strings").write_text(
        f'"CFBundleName" = "{name}";\n"CFBundleDisplayName" = "{name}";\n', encoding="utf-16")
shutil.copy2(root / ".build/release/VirtualLocation", macos / "VirtualLocation")
shutil.copy2(root / "assets/brand/AppIcon.icns", resources / "AppIcon.icns")
for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
    shutil.copy2(root / notice, resources / notice)
info = {
    "CFBundleIdentifier": "local.virtual-location.app",
    "CFBundleName": "虚拟定位", "CFBundleDisplayName": "虚拟定位",
    "CFBundleExecutable": "VirtualLocation", "CFBundlePackageType": "APPL",
    "CFBundleIconFile": "AppIcon.icns",
    "CFBundleDevelopmentRegion": "zh-Hans", "CFBundleLocalizations": ["zh-Hans", "en"],
    "CFBundleShortVersionString": "0.2.3", "CFBundleVersion": "6",
    "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
    "VLProjectRoot": str(root), "NSPrincipalClass": "NSApplication",
}
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
print(app)
