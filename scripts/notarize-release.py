#!/usr/bin/env python3
"""Notarize and staple an app before packaging, then its signed DMG before publishing."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent


class ReleaseError(Exception):
    pass


def run(command, output=None, required=True):
    # Do not use check=True: CalledProcessError would include the password in argv.
    result = subprocess.run(command, stdout=output)
    if required and result.returncode:
        raise ReleaseError(f"{Path(command[0]).name} failed (exit {result.returncode})")
    return result.returncode


def read_json(filename):
    try:
        with filename.open() as source:
            value = json.load(source)
        if not isinstance(value, dict):
            raise ValueError("expected an object")
        return value
    except (OSError, ValueError) as error:
        raise ReleaseError(f"Cannot read notarization response: {filename.name}") from error


def developer_id_requirement(team):
    return (
        "anchor apple generic and "
        "certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
        "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and "
        f'certificate leaf[subject.OU] = "{team}"'
    )


def notarize(kind, target, log_dir):
    required = ["APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_SPECIFIC_PASSWORD"]
    if kind == "dmg":
        required.append("CODE_SIGN_IDENTITY")
    for name in required:
        if not os.environ.get(name):
            raise ReleaseError(f"Missing environment variable: {name}")
    team = os.environ["APPLE_TEAM_ID"]
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ReleaseError("APPLE_TEAM_ID must contain 10 uppercase letters/digits")
    timeout = os.environ.get("NOTARIZATION_TIMEOUT", "20m")
    if not re.fullmatch(r"[1-9][0-9]*[smh]?", timeout):
        raise ReleaseError("Invalid NOTARIZATION_TIMEOUT (example: 20m)")
    if not target.exists() or (kind == "app" and not target.is_dir()) or (kind == "dmg" and not target.is_file()):
        raise ReleaseError(f"Missing {kind}: {target}")
    if target.suffix.lower() != f".{kind}":
        raise ReleaseError(f"Expected a .{kind} target")

    auth = ["--apple-id", os.environ["APPLE_ID"], "--team-id", team,
            "--password", os.environ["APPLE_APP_SPECIFIC_PASSWORD"]]
    requirement = developer_id_requirement(team)
    if kind == "dmg":
        signing = ["codesign", "--force", "--sign", os.environ["CODE_SIGN_IDENTITY"], "--timestamp"]
        if os.environ.get("CODE_SIGN_KEYCHAIN"):
            signing += ["--keychain", os.environ["CODE_SIGN_KEYCHAIN"]]
        run(signing + [str(target)])
    run(["codesign", "--verify", "--deep", "--strict", "-R", requirement, str(target)])

    log_dir.mkdir(parents=True, exist_ok=True)
    # Keep the temporary upload separate; truncate each response file before every command.
    with tempfile.TemporaryDirectory(prefix=f"{kind}-upload-", dir=log_dir) as scratch:
        upload = target
        if kind == "app":
            upload = Path(scratch) / "OpenPaste-notarization.zip"
            run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(target), str(upload)])
        submission_file = log_dir / f"{kind}-submission.json"
        with submission_file.open("w") as output:
            run(["xcrun", "notarytool", "submit", str(upload), *auth,
                 "--no-wait", "--output-format", "json"], output)
        submission = read_json(submission_file)
        try:
            submission_id = str(uuid.UUID(submission["id"]))
        except (KeyError, ValueError, TypeError, AttributeError) as error:
            raise ReleaseError("Notary service did not return a valid submission ID") from error
        print(f"{kind} notarization submission: {submission_id}", flush=True)

        result_file = log_dir / f"{kind}-result.json"
        with result_file.open("w") as output:
            wait_exit = run(["xcrun", "notarytool", "wait", submission_id, *auth,
                             "--timeout", timeout, "--output-format", "json"], output, required=False)
        result = read_json(result_file)
        status = result.get("status", "Unknown")
        print(f"{kind} notarization status: {status}", flush=True)
        log_file = log_dir / f"{kind}-log.json"
        if wait_exit or status != "Accepted":
            # Invalid submissions have a diagnostic log; pending submissions may not have one yet.
            with log_file.open("w") as output:
                log_exit = run(["xcrun", "notarytool", "log", submission_id, *auth], output, required=False)
            if log_exit == 0:
                print(log_file.read_text(), flush=True)
            raise ReleaseError(f"Notarization not accepted ({status}); submission {submission_id}. Nothing will be published.")
        with log_file.open("w") as output:
            run(["xcrun", "notarytool", "log", submission_id, *auth], output)
        log = read_json(log_file)
        print(json.dumps(log, ensure_ascii=False, indent=2), flush=True)
        if log.get("status") != "Accepted" or any(issue.get("severity") == "error" for issue in (log.get("issues") or [])):
            raise ReleaseError("Notarization log is not Accepted or contains errors")

    run(["xcrun", "stapler", "staple", str(target)])
    run(["xcrun", "stapler", "validate", str(target)])
    run(["codesign", "--verify", "--deep", "--strict", "-R", requirement, str(target)])
    if kind == "app":
        run(["spctl", "--assess", "--type", "execute", "--verbose=4", str(target)])
    else:
        run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", str(target)])
    print(f"Notarization, stapled ticket, signature and Gatekeeper checks passed: {target.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["app", "dmg"])
    parser.add_argument("target", type=Path)
    args = parser.parse_args()
    log_dir = Path(os.environ.get("NOTARIZATION_LOG_DIR", str(ROOT / "build/notarization"))).resolve()
    try:
        notarize(args.kind, args.target.resolve(), log_dir)
    except (ReleaseError, OSError) as error:
        print(f"Notarization failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
