#!/usr/bin/env python3
"""Install only ControlTapIME and one Karabiner rule; keep all other data intact."""
import argparse
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
LABEL = "io.github.tario-you.controltap-ime"
DESCRIPTION = "ControlTapIME: tap Control to switch language; hold/chords remain Control"
DECODER = json.JSONDecoder()


def skip_space(text, start):
    while start < len(text) and text[start].isspace():
        start += 1
    return start


def members(text, start):
    """Read object value spans without reformatting the surrounding JSON."""
    if text[start] != "{":
        raise ValueError("Expected JSON object")
    index = skip_space(text, start + 1)
    while text[index] != "}":
        key, end = DECODER.raw_decode(text, index)
        index = skip_space(text, end)
        if text[index] != ":":
            raise ValueError("Expected JSON colon")
        begin = skip_space(text, index + 1)
        value, end = DECODER.raw_decode(text, begin)
        yield key, value, begin, end
        index = skip_space(text, end)
        if text[index] == ",":
            index = skip_space(text, index + 1)


def elements(text, start):
    if text[start] != "[":
        raise ValueError("Expected JSON array")
    index = skip_space(text, start + 1)
    while text[index] != "]":
        value, end = DECODER.raw_decode(text, index)
        yield value, index, end
        index = skip_space(text, end)
        if text[index] == ",":
            index = skip_space(text, index + 1)


def member(text, start, name):
    for key, value, begin, end in members(text, start):
        if key == name:
            return value, begin, end
    raise ValueError(f"Karabiner configuration is missing {name}")


def patch_rule(text, rule, remove=False):
    parsed = json.loads(text)
    _, profiles_start, _ = member(text, skip_space(text, 0), "profiles")
    selected = [(p, start) for p, start, _ in elements(text, profiles_start) if p.get("selected")]
    if len(selected) != 1:
        raise ValueError("Expected exactly one selected Karabiner profile")
    profile, profile_start = selected[0]
    _, complex_start, _ = member(text, profile_start, "complex_modifications")
    rules, rules_start, _ = member(text, complex_start, "rules")
    spans = list(elements(text, rules_start))
    own = [(i, start, end) for i, (r, start, end) in enumerate(spans) if r.get("description") == DESCRIPTION]
    if len(own) > 1:
        raise ValueError("Duplicate ControlTapIME rules; refusing an ambiguous edit")
    if own:
        index, start, end = own[0]
        if not remove and rules[index] == rule:
            return text
        if remove:
            if index < len(spans) - 1:
                result = text[:start] + text[spans[index + 1][1]:]
            elif index > 0:
                result = text[:spans[index - 1][2]] + text[end:]
            else:
                result = text[:start] + text[end:]
        else:
            indentation = re.match(r"[ \t]*", text[text.rfind("\n", 0, start) + 1:start]).group()
            replacement = json.dumps(rule, ensure_ascii=False, indent=4).replace("\n", "\n" + indentation)
            result = text[:start] + replacement + text[end:]
    elif remove:
        return text
    else:
        for existing in rules:
            if existing.get("enabled", True) is False:
                continue
            for manipulator in existing.get("manipulators", []):
                if manipulator.get("from", {}).get("key_code") in {"left_control", "right_control"}:
                    raise ValueError("An existing Control mapping needs manual reconciliation; no changes made")
        prefix = text[text.rfind("\n", 0, rules_start) + 1:rules_start]
        indentation = re.match(r"[ \t]*", prefix).group() + "    "
        rendered = json.dumps(rule, ensure_ascii=False, indent=4).replace("\n", "\n" + indentation)
        insertion = "\n" + indentation + rendered + ("," if rules else "")
        result = text[:rules_start + 1] + insertion + text[rules_start + 1:]
    changed = json.loads(result)
    # Enforce preservation of every unrelated profile, preference, and rule.
    before = copy.deepcopy(parsed)
    after = copy.deepcopy(changed)
    for data in [before, after]:
        selected_profile = next(p for p in data["profiles"] if p.get("selected"))
        selected_profile["complex_modifications"]["rules"] = [
            r for r in selected_profile["complex_modifications"]["rules"] if r.get("description") != DESCRIPTION]
    if before != after:
        raise AssertionError("Edit unexpectedly changed unrelated Karabiner data")
    return result


def atomic_write(path, data, mode=0o600, expected=None):
    path = Path(path)
    if path.is_symlink():
        raise ValueError(f"Refusing to replace a symlink: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        if expected is not None and path.read_bytes() != expected:
            raise RuntimeError("Configuration changed during installation; refusing to overwrite newer work")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uninstall", action="store_true")
    parser.add_argument("--source-id", action="append", default=[])
    args = parser.parse_args()
    home = Path.home()
    support = home / "Library/Application Support/ControlTapIME"
    app = home / "Applications/ControlTapIME.app"
    binary = app / "Contents/MacOS/controltap-ime"
    agent = home / "Library/LaunchAgents" / (LABEL + ".plist")
    target = home / ".config/karabiner/karabiner.json"
    asset = home / ".config/karabiner/assets/complex_modifications/control-tap-ime.json"
    domain = f"gui/{os.getuid()}"
    rule = json.loads((ROOT / "karabiner/control-tap-ime.json").read_text())["rules"][0]
    config = support / "config.json"
    if support.is_symlink() or app.is_symlink() or config.is_symlink():
        raise RuntimeError("Refusing a symlink installation target")
    if not args.uninstall and config.exists() and args.source_id:
        raise RuntimeError("Existing local configuration retained; edit config.json to change sources")
    if len(set(args.source_id)) != len(args.source_id) or len(args.source_id) == 1:
        raise RuntimeError("Provide zero or at least two distinct --source-id values")
    if agent.exists() and plistlib.loads(agent.read_bytes()).get("Label") != LABEL:
        raise RuntimeError("Refusing to replace an unrelated LaunchAgent")
    if asset.exists() and json.loads(asset.read_text()).get("rules") != [rule]:
        raise RuntimeError("Existing Karabiner asset has custom changes; reconcile it manually")
    original = target.read_bytes()
    patched = patch_rule(original.decode(), rule, remove=args.uninstall).encode()
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    backups = support / "backups"
    backups.mkdir(exist_ok=True, mode=0o700)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    if patched != original:
        atomic_write(backups / ("karabiner-" + stamp + ".json"), original)
    if args.uninstall:
        subprocess.run(["launchctl", "bootout", domain + "/" + LABEL], capture_output=True)
        atomic_write(target, patched, target.stat().st_mode & 0o777, expected=original)
        if agent.exists():
            agent.unlink()
        if asset.exists() and json.loads(asset.read_text()).get("rules") == [rule]:
            asset.unlink()
        print("ControlTapIME disabled. App, local configuration, and backups retained.")
        return
    built_app = ROOT / "dist/ControlTapIME.app"
    if not built_app.exists():
        raise RuntimeError("Run bash scripts/build.sh first")
    if app.exists():
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != LABEL:
            raise RuntimeError("Install target is an unrelated app; refusing to replace it")
        subprocess.run(["launchctl", "bootout", domain + "/" + LABEL], capture_output=True)
        shutil.copytree(app, backups / ("ControlTapIME-" + stamp + ".app"))
    app.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(built_app, app, dirs_exist_ok=True)
    if not config.exists():
        atomic_write(config, (json.dumps({"sourceIDs": args.source_id, "refreshMilliseconds": 80}, indent=2) + "\n").encode())
    launch_agent = {"Label": LABEL, "ProgramArguments": [str(binary), "serve"], "RunAtLoad": True,
                    "KeepAlive": True, "ThrottleInterval": 5,
                    "StandardErrorPath": str(support / "error.log")}
    atomic_write(agent, plistlib.dumps(launch_agent))
    subprocess.run(["launchctl", "bootout", domain + "/" + LABEL], capture_output=True)
    run("launchctl", "bootstrap", domain, str(agent))
    ready = False
    for _ in range(30):
        result = subprocess.run([str(binary), "status"], capture_output=True, text=True)
        if result.returncode == 0:
            ready = True
            break
        time.sleep(0.1)
    if not ready:
        raise RuntimeError("Helper did not become ready; Karabiner has not been changed. See local error.log")
    atomic_write(asset, (ROOT / "karabiner/control-tap-ime.json").read_bytes())
    atomic_write(target, patched, target.stat().st_mode & 0o777, expected=original)
    print("Installed ControlTapIME. Tap either Control within 250 ms to switch languages.")
    print("Control combinations and longer holds retain their normal behavior.")
    print("Original Karabiner configuration saved in the local application-support backups directory.")


if __name__ == "__main__":
    main()
