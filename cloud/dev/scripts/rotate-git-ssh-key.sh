#!/bin/bash
# Rotate the Git SSH key on a CloudDev dev server by running the environment
# stack's source control SSM document with Action=RotateSshKey, then print the
# new public key to add in GitHub or Azure DevOps.
#
# Usage: rotate-git-key [-P github|azuredevops] [-i instance-id] [-k keep]
#                       [-r region] [-p aws-profile] [-d document-name]
#
# Defaults: the server's own source provider (its SourceProvider choice; GitHub
# gets an ed25519 key, Azure DevOps a 4096-bit ssh-rsa key), the instance this
# script runs on (from instance metadata), keep 2 keys, the region from instance
# metadata or AWS_REGION, and the document found by name. -P rotates the other
# provider's key instead, for a server that uses both. Run it anywhere your AWS
# credentials allow ssm:SendCommand on the document and the instance: the
# CloudDev permission set does, and so does the shared dev server role (for
# servers of its own environment), so on a server no profile is needed.
set -euo pipefail

INSTANCE="" KEEP=2 PROVIDER=auto REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" DOC="${DOC:-}" PROFILE_ARGS=()

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts "P:i:k:r:p:d:h" opt; do
  case "$opt" in
    P) PROVIDER="$OPTARG" ;;
    i) INSTANCE="$OPTARG" ;;
    k) KEEP="$OPTARG" ;;
    r) REGION="$OPTARG" ;;
    p) PROFILE_ARGS=(--profile "$OPTARG") ;;
    d) DOC="$OPTARG" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

case "$(printf '%s' "$PROVIDER" | tr '[:upper:]' '[:lower:]')" in
  auto) PROVIDER=auto ;;
  github) PROVIDER=GitHub ;;
  azuredevops|azure|ado) PROVIDER=AzureDevOps ;;
  *) echo "Unknown provider: $PROVIDER (use github or azuredevops)." >&2; exit 1 ;;
esac

imds() {
  local token
  token=$(curl -sS -m 2 -X PUT http://169.254.169.254/latest/api/token \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || return 1
  curl -sS -m 2 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

if [ -z "$INSTANCE" ]; then
  INSTANCE=$(imds instance-id) || { echo "Not on an EC2 instance; pass -i <instance-id>." >&2; exit 1; }
fi
if [ -z "$REGION" ]; then
  REGION=$(imds placement/region) || { echo "Could not determine the region; pass -r <region>." >&2; exit 1; }
fi

aws_() { aws "${PROFILE_ARGS[@]}" --region "$REGION" "$@"; }

if [ -z "$DOC" ]; then
  # list-documents is paginated and --query runs per page, so pages with no
  # match print "None"; keep only the first real name.
  DOC=$(aws_ ssm list-documents --filters Key=Owner,Values=Self \
    --query "DocumentIdentifiers[?contains(Name,'AmazonLinuxSourceControlDocument')].Name" --output text \
    | tr '\t' '\n' | grep -v -E '^(None)?$' | head -n 1 || true)
  if [ -z "$DOC" ]; then
    echo "Could not find the source control SSM document; pass -d <document-name>." >&2
    exit 1
  fi
fi

echo "Rotating the $PROVIDER SSH key on $INSTANCE ($REGION) with $DOC (keep $KEEP)..."
CMD=$(aws_ ssm send-command --document-name "$DOC" --instance-ids "$INSTANCE" \
  --parameters "Action=RotateSshKey,Provider=$PROVIDER,KeepKeys=$KEEP" \
  --query Command.CommandId --output text)

# 'wait' exits non-zero if the command fails; still show the output then.
STATUS=0
aws_ ssm wait command-executed --command-id "$CMD" --instance-id "$INSTANCE" || STATUS=$?

aws_ ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
  --query StandardOutputContent --output text
if [ "$STATUS" -ne 0 ]; then
  echo "--- the command did not succeed; error output:" >&2
  aws_ ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
    --query StandardErrorContent --output text >&2
  exit "$STATUS"
fi

cat <<'EOF'

Next: add the public key above where the output says, delete the keys listed
under "Removed", then run the check command it printed.
EOF
