"""Bump the pinned tool versions on the CloudDev environment stack.

For each exact-version parameter in cloud/dev/cloud-dev-environment.yaml,
look up the latest release within its major (or release line), and when it
is newer than the parameter's Default, rewrite the version in that
parameter's block and in the README lines that name the parameter. The
"(as of <Month> <Year>)" notes on changed parameters are refreshed too.

Prints a Markdown summary of the changes (for the PR body) on stdout. Uses
only the standard library plus the gh CLI (for GitHub release lookups).
"""

import datetime
import json
import os
import re
import subprocess
import sys
import urllib.request

TEMPLATE = "cloud/dev/cloud-dev-environment.yaml"
README = "README.md"


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "clouddev-version-bump"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode()


def npm_latest(package):
    return json.loads(http_get(f"https://registry.npmjs.org/{package}/latest"))["version"]


def dotnet_latest_sdk(channel):
    url = f"https://builds.dotnet.microsoft.com/dotnet/release-metadata/{channel}/releases.json"
    return json.loads(http_get(url))["latest-sdk"]


def github_releases(repo):
    """Tag names of the repo's published, non-prerelease releases."""
    out = subprocess.run(
        ["gh", "api", "--paginate", f"repos/{repo}/releases",
         "--jq", ".[] | select(.draft | not) | select(.prerelease | not) | .tag_name"],
        check=True, capture_output=True, text=True,
    ).stdout
    return out.split()


def github_tags(repo):
    """Tag names via git ls-remote (for repos that publish no releases)."""
    out = subprocess.run(
        ["git", "ls-remote", "--tags", "--refs", f"https://github.com/{repo}.git"],
        check=True, capture_output=True, text=True,
    ).stdout
    return [line.split("refs/tags/", 1)[1] for line in out.splitlines()]


def azure_cli_rpms():
    """azure-cli versions published as el9 RPMs, which is what the document installs."""
    index = http_get("https://packages.microsoft.com/rhel/9.0/prod/Packages/a/")
    return re.findall(r"azure-cli-(\d+\.\d+\.\d+)-1\.el9\.x86_64\.rpm", index)


def highest(candidates, pattern):
    """Highest version among candidates whose full text matches pattern (group 1 = version)."""
    versions = set()
    for candidate in candidates:
        m = re.fullmatch(pattern, candidate)
        if m:
            versions.add(m.group(1))
    if not versions:
        raise RuntimeError(f"no versions matched {pattern}")
    return max(versions, key=lambda v: tuple(int(p) for p in v.split(".")))


# Parameter name -> function returning the latest version for it.
SOURCES = {
    "DefaultNpmVersion": lambda: npm_latest("npm"),
    "PowerShell74Version": lambda: highest(github_releases("PowerShell/PowerShell"), r"v(7\.4\.\d+)"),
    "PowerShell76Version": lambda: highest(github_releases("PowerShell/PowerShell"), r"v(7\.6\.\d+)"),
    "DotNet8Version": lambda: dotnet_latest_sdk("8.0"),
    "DotNet10Version": lambda: dotnet_latest_sdk("10.0"),
    "PlaywrightVersion": lambda: npm_latest("playwright"),
    "K6V0Version": lambda: highest(github_releases("grafana/k6"), r"v(0\.\d+\.\d+)"),
    "K6V1Version": lambda: highest(github_releases("grafana/k6"), r"v(1\.\d+\.\d+)"),
    "AwsCliV2Version": lambda: highest(github_tags("aws/aws-cli"), r"(2\.\d+\.\d+)"),
    "GhCliV2Version": lambda: highest(github_releases("cli/cli"), r"v(2\.\d+\.\d+)"),
    "AzCliV2Version": lambda: highest(azure_cli_rpms(), r"(2\.\d+\.\d+)"),
}


def version_re(version):
    # Match the exact version, not a prefix of a longer one (7.6.8 vs 7.6.80).
    return re.compile(r"(?<![\d.])" + re.escape(version) + r"(?![\d])(?!\.\d)")


def as_of_now():
    return datetime.date.today().strftime("%B %Y")


def parse_version(v):
    return tuple(int(p) for p in v.split("."))


def main():
    with open(TEMPLATE, encoding="utf-8") as f:
        template = f.read()
    with open(README, encoding="utf-8") as f:
        readme_lines = f.read().splitlines(keepends=True)

    as_of = as_of_now()
    changes = []
    failures = []

    for name, source in SOURCES.items():
        # The parameter block: from "  Name:" to the next blank line.
        block_re = re.compile(rf"^  {name}:\n(?:.+\n)+", re.M)
        block_match = block_re.search(template)
        if not block_match:
            failures.append(f"{name}: parameter not found in {TEMPLATE}")
            continue
        block = block_match.group(0)
        current = re.search(r'^    Default: "([^"]+)"', block, re.M).group(1)

        try:
            latest = source()
        except Exception as e:  # keep going; report at the end
            failures.append(f"{name}: lookup failed ({e})")
            continue

        allowed = re.search(r"^    AllowedPattern: (.+)$", block, re.M).group(1)
        if not re.fullmatch(allowed, latest):
            failures.append(f"{name}: latest {latest} does not match {allowed}")
            continue
        if parse_version(latest) <= parse_version(current):
            print(f"{name}: {current} is current", file=sys.stderr)
            continue

        new_block = version_re(current).sub(latest, block)
        # Keep the original whitespace, which may be a folded line break.
        month, year = as_of.split()
        new_block = re.sub(r"\(as of(\s+)[A-Z][a-z]+(\s+)\d{4}\)",
                           lambda m: f"(as of{m.group(1)}{month}{m.group(2)}{year})", new_block)
        template = template.replace(block, new_block)

        for i, line in enumerate(readme_lines):
            if f"`{name}`" in line:
                readme_lines[i] = version_re(current).sub(latest, line)

        changes.append((name, current, latest))
        print(f"{name}: {current} -> {latest}", file=sys.stderr)

    if changes:
        readme = "".join(readme_lines)
        readme = re.sub(r"\(current as of [A-Z][a-z]+ \d{4}\)", f"(current as of {as_of})", readme)
        with open(TEMPLATE, "w", encoding="utf-8", newline="\n") as f:
            f.write(template)
        with open(README, "w", encoding="utf-8", newline="\n") as f:
            f.write(readme)

    summary = []
    if changes:
        summary.append("| Parameter | From | To |")
        summary.append("| --- | --- | --- |")
        summary += [f"| `{n}` | `{old}` | `{new}` |" for n, old, new in changes]
    else:
        summary.append("All pinned versions are already the latest.")
    if failures:
        summary.append("")
        summary.append("**Not checked:**")
        summary += [f"- {f}" for f in failures]
    print("\n".join(summary))

    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a", encoding="utf-8") as f:
            f.write("\n".join(summary) + "\n")


if __name__ == "__main__":
    main()
