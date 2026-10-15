#!/usr/bin/env bash
#
# The documentation describes this code, not an older one:
#   - every relative link in a Markdown file resolves;
#   - every `runnerslice <command>` the documents use exists;
#   - the configuration reference lists exactly the keys the code accepts,
#     in each file, in both directions;
#   - the example inventory validates.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -I - "$ROOT" <<'PY'
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
passed = failed = 0

def result(ok, text):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS  {text}")
    else:
        failed += 1
        print(f"FAIL  {text}", file=sys.stderr)

docs = sorted(p for p in root.rglob("*.md") if ".git" not in p.parts)

# Links.
link = re.compile(r"\]\(([^)#\s]+)(#[^)]*)?\)")
broken = []
for doc in docs:
    for target, _ in link.findall(doc.read_text()):
        if re.match(r"^[a-z]+://", target) or target.startswith("mailto:"):
            continue
        if not (doc.parent / target).exists():
            broken.append(f"{doc.relative_to(root)} -> {target}")
result(not broken, f"every relative link in {len(docs)} documents resolves" + (f": {broken}" if broken else ""))

# Commands.
cli = (root / "bin/runnerslice").read_text()
known = set(re.findall(r"^    ([a-z]+)(?:\|[a-z-]+)*\)", cli, re.M))
used = set()
for doc in docs:
    used |= set(re.findall(r"runnerslice(?: \[?--config [A-Z]+\]?)? ([a-z]+)\b", doc.read_text()))
unknown = sorted(used - known - {"is", "was", "has", "and", "or", "the", "on", "in", "inventory"})
result(not unknown, f"every runnerslice command the documents use exists ({len(used & known)} used)" + (f": unknown {unknown}" if unknown else ""))

# Configuration keys.
lib = (root / "fabric/fabric-lib.sh").read_text()
def accepted(function):
    body = lib[lib.index(f"{function}() {{"):]
    body = body[:body.index("\n}\n")]
    keys = set()
    for line in re.findall(r"^\s+([a-z0-9|-]+)\)\s*$", body, re.M):
        keys |= {k for k in line.split("|") if k}
    return keys
policy = accepted("fabric_validate_policy")
release = accepted("fabric_validate_release")
profile = accepted("fabric_validate_profile")
forbidden_in_profile = {"runner-version", "runner-platform", "runner-archive", "runner-bytes", "runner-sha256", "runner-url", "apt-dependency"}
profile -= forbidden_in_profile

ref = (root / "docs/configuration.md").read_text()
def documented(heading):
    part = ref[ref.index(heading):]
    nxt = part.find("\n## ", 3)
    part = part if nxt < 0 else part[:nxt]
    return set(re.findall(r"^\| `([a-z0-9-]+)` \|", part, re.M))
for name, heading, code in [
    ("fabric.conf", "## `fabric.conf`", policy),
    ("runner-release.conf", "## `runner-release.conf`", release),
    ("profiles", "## `profiles/", profile),
]:
    doc = documented(heading)
    result(doc == code, f"{name}: the reference lists exactly the {len(code)} keys the code accepts"
           + ("" if doc == code else f" (undocumented {sorted(code - doc)}, not in code {sorted(doc - code)})"))

# Example inventory.
r = subprocess.run(["bash", str(root / "bin/runnerslice"), "--config", str(root / "examples/basic"), "validate"],
                   capture_output=True, text=True)
result(r.returncode == 0, "the example inventory validates")

print()
print(f"result: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
