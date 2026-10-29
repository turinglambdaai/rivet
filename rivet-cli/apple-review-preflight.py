#!/usr/bin/env python3
"""Read-only Apple release preflight. Not an App Review or notarization approval."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys

SCHEMA = "rivet.apple-review-preflight.v1"
CHANNELS = ("developer-id", "mac-app-store", "ios-app-store")
PRIVACY_KEYS = {"NSPrivacyTracking", "NSPrivacyTrackingDomains",
                "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"}
RUNTIME_EXCEPTIONS = ("com.apple.security.cs.allow-unsigned-executable-memory",
                      "com.apple.security.cs.disable-executable-page-protection",
                      "com.apple.security.cs.disable-library-validation",
                      "com.apple.security.cs.allow-dyld-environment-variables")


def inspect(app_path, channel, *, host=None, run=None):
    """Inspect only the built artifact; report missing evidence explicitly."""
    app = Path(app_path)
    host = platform.system() if host is None else host
    run = subprocess.run if run is None else run
    report = {"schema": SCHEMA, "app": str(app), "channel": channel,
              "blockers": [], "warnings": [], "unverified": [], "manual_review": []}

    def add(section, code, message):
        report[section].append({"code": code, "message": message})

    if channel == "ios-app-store":
        add("blockers", "standalone-ios-not-shipped",
            "Rivet's portable/companion iOS foundations are not a generated, "
            "packaged, device-qualified standalone iOS App Store application.")
    elif not app.is_dir() or app.suffix != ".app":
        add("blockers", "bundle-not-found", "Expected a built macOS .app directory.")
    else:
        try:
            with (app / "Contents" / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            if not isinstance(info, dict):
                raise ValueError("Info.plist root is not a dictionary")
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
            add("blockers", "invalid-info-plist",
                "Contents/Info.plist is missing or malformed.")
            info = {}

        identifier = info.get("CFBundleIdentifier")
        if not isinstance(identifier, str) or not re.fullmatch(
            r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", identifier
        ):
            add("blockers", "bundle-id", "CFBundleIdentifier needs a reverse-DNS ID.")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or (
            Path(executable).name != executable
        ) or executable in (".", ".."):
            add("blockers", "executable-name",
                "CFBundleExecutable must be a single safe file name.")
        elif not (app / "Contents" / "MacOS" / executable).is_file():
            add("blockers", "executable-missing",
                "The declared Contents/MacOS executable is absent.")
        if info.get("CFBundlePackageType") != "APPL":
            add("blockers", "bundle-type", "CFBundlePackageType must be APPL.")

        manifest = app / "Contents" / "Resources" / "PrivacyInfo.xcprivacy"
        if manifest.exists():
            try:
                with manifest.open("rb") as stream:
                    privacy = plistlib.load(stream)
                if not isinstance(privacy, dict) or not set(privacy).issubset(PRIVACY_KEYS):
                    raise ValueError("invalid root")
                if "NSPrivacyTracking" in privacy and not isinstance(
                    privacy["NSPrivacyTracking"], bool
                ):
                    raise ValueError("tracking flag must be boolean")
                for key in ("NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes",
                            "NSPrivacyAccessedAPITypes"):
                    if key in privacy and not isinstance(privacy[key], list):
                        raise ValueError("expected array for " + key)
            except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
                add("blockers", "privacy-manifest-invalid",
                    "PrivacyInfo.xcprivacy is malformed or has invalid root fields.")
        else:
            add("unverified", "privacy-applicability",
                "No macOS Resources/PrivacyInfo.xcprivacy; audit the app and SDKs "
                "to determine whether a manifest is required.")

        if host != "Darwin":
            add("unverified", "macos-host-needed",
                "Apple codesign, entitlements and notarization cannot be verified "
                "on this non-macOS host.")
        else:
            try:
                checked = run(["codesign", "--verify", "--deep", "--strict", str(app)],
                              capture_output=True, check=False)
                if checked.returncode:
                    add("blockers", "codesign-invalid",
                        "codesign --verify --deep --strict failed.")
                entitlement_result = run(
                    ["codesign", "-d", "--entitlements", "-", str(app)],
                    capture_output=True, check=False)
                entitlements = None
                if entitlement_result.returncode == 0:
                    try:
                        entitlements = plistlib.loads(entitlement_result.stdout)
                        if not isinstance(entitlements, dict):
                            entitlements = None
                    except (ValueError, TypeError, plistlib.InvalidFileException):
                        pass
                if entitlements is None:
                    add("unverified", "signed-entitlements-unreadable",
                        "Could not parse effective signed application entitlements.")
                else:
                    if entitlements.get("com.apple.security.get-task-allow") is True:
                        add("blockers", "debug-entitlement",
                            "Production bundles may not grant get-task-allow.")
                    if channel == "mac-app-store" and entitlements.get(
                        "com.apple.security.app-sandbox"
                    ) is not True:
                        add("blockers", "sandbox-missing",
                            "Mac App Store bundles require App Sandbox.")
                    for key in RUNTIME_EXCEPTIONS:
                        if entitlements.get(key) is True:
                            add("warnings", "hardened-runtime-exception",
                                key + " requires explicit justification and runtime evidence.")
                    if entitlements.get("com.apple.security.cs.allow-jit") is True:
                        add("warnings", "jit-exception",
                            "A JIT entitlement is not proof that Racket qualifies "
                            "for this App Store channel.")
            except (FileNotFoundError, OSError):
                add("unverified", "codesign-unavailable",
                    "codesign executable or Apple signing inspection is unavailable.")

        if channel == "developer-id":
            add("manual_review", "notarization",
                "Run raco rivet verify --production on the final signed .app "
                "to verify stapling and Gatekeeper acceptance.")
        else:
            add("unverified", "mac-app-store-delivery",
                "Rivet currently has no Mac App Store Xcode Archive, "
                "Store-signing, upload and approval acceptance evidence.")
            add("manual_review", "store-payments-and-updates",
                "Audit StoreKit/IAP, Store-managed updates, sandbox file access "
                "and the Mac App Store license-screen/key restrictions.")
        add("manual_review", "privacy-and-submission",
            "Audit required-reason APIs, bundled SDK signatures, data labels, "
            "review notes, demo accounts, screenshots and on-device behavior.")

    report["status"] = ("blocked" if report["blockers"] else
                        "needs-evidence" if report["unverified"] else
                        "automated-checks-passed")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--channel", choices=CHANNELS, required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    result = inspect(args.app, args.channel)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print("Apple release preflight:", result["status"])
        for kind in ("blockers", "warnings", "unverified", "manual_review"):
            for item in result[kind]:
                print("  {}: {}: {}".format(kind, item["code"], item["message"]))
    return 1 if result["blockers"] else 2 if result["unverified"] else 0


if __name__ == "__main__":
    sys.exit(main())
