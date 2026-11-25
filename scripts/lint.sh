#!/usr/bin/env bash
# Lint every CloudFormation template in the repo with cfn-lint.
# Used locally and by CI (.github/workflows/validate-templates.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

# Every YAML file that looks like a CloudFormation template (has the
# AWSTemplateFormatVersion or a Resources section).
mapfile -t templates < <(grep -rlE '^(AWSTemplateFormatVersion|Resources):' \
  --include='*.yaml' --include='*.yml' --exclude-dir=.git --exclude-dir=.venv --exclude-dir=node_modules . || true)

if [ ${#templates[@]} -eq 0 ]; then
  echo "No CloudFormation templates found."
  exit 0
fi

echo "Linting the following templates:"
printf '  %s\n' "${templates[@]}"
cfn-lint "${templates[@]}"
