#!/bin/bash
# Rotate the GitHub SSH key on a CloudDev dev server by running the
# environment stack's GitHub SSM document with Action=RotateSshKey, then print
# the new public key to add in GitHub.
#
# Usage: rotate-github-ssh-key.sh [-i instance-id] [-k keep] [-r region]
#                                 [-p aws-profile] [-d document-name]
#
# Defaults: the instance this script runs on (from instance metadata), keep 2
# keys, the region from instance metadata or AWS_REGION, and the document found
# by name. Run it anywhere your AWS credentials allow ssm:SendCommand on the
# document and the instance (the CloudDev permission set does). A server's own
# role does not, so on a server use a profile (-p) from ~/.aws/credentials.
set -euo pipefail

INSTANCE="" KEEP=2 REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" DOC="${DOC:-}" PROFILE_ARGS=()

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts "i:k:r:p:d:h" opt; do
  case "$opt" in
    i) INSTANCE="$OPTARG" ;;
    k) KEEP="$OPTARG" ;;
    r) REGION="$OPTARG" ;;
    p) PROFILE_ARGS=(--profile "$OPTARG") ;;
    d) DOC="$OPTARG" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

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
  DOC=$(aws_ ssm list-documents --filters Key=Owner,Values=Self \
    --query "DocumentIdentifiers[?contains(Name,'AmazonLinuxGhCliV2Document')].Name | [0]" --output text)
  if [ -z "$DOC" ] || [ "$DOC" = "None" ]; then
    echo "Could not find the GitHub SSM document; pass -d <document-name>." >&2
    exit 1
  fi
fi

echo "Rotating the GitHub SSH key on $INSTANCE ($REGION) with $DOC (keep $KEEP)..."
CMD=$(aws_ ssm send-command --document-name "$DOC" --instance-ids "$INSTANCE" \
  --parameters "Action=RotateSshKey,KeepKeys=$KEEP" \
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

Next: add the public key above in GitHub (Settings > SSH keys > New SSH key, or
as a deploy key on one repo), delete the keys listed under "Removed", then check:
  ssh -T git@github.com
EOF
