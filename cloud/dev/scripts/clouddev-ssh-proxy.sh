#!/usr/bin/env bash
# SSH ProxyCommand for CloudDev dev servers (macOS / Linux). Starts the server
# if it is stopped (e.g. by the idle auto-stop), waits until Session Manager
# can reach it, then opens the SSH tunnel through Session Manager.
#
# Usage, in ~/.ssh/config (chmod +x the script first):
#
#   Host my-dev-server
#       HostName <instance-id>
#       ProxyCommand ~/.ssh/clouddev-ssh-proxy.sh %h %p <region> <profile>
#
# stdout carries the SSH connection, so every message goes to stderr (shown in
# VS Code's Remote-SSH log and by `ssh -v`). Needs the AWS CLI v2, the Session
# Manager plugin, and permission to describe and start the instance (the
# CloudDev permission set has both).
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <instance-id> <port> <region> [profile]" >&2
  exit 1
fi
INSTANCE_ID=$1 PORT=$2 REGION=$3 PROFILE=${4:-}
AWS=(aws --region "$REGION")
[ -z "$PROFILE" ] || AWS+=(--profile "$PROFILE")

log() { echo "[clouddev] $*" >&2; }

state() {
  local out
  if ! out=$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>&1); then
    log "Could not read $INSTANCE_ID ($out). If your sign-in expired, run: aws sso login${PROFILE:+ --profile $PROFILE}"
    exit 1
  fi
  echo "$out"
}

ping_status() {
  "${AWS[@]}" ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true
}

# Start the server if needed and wait (up to 5 minutes) until it is running.
DEADLINE=$((SECONDS + 300))
while :; do
  STATE=$(state)
  case "$STATE" in
    running) break ;;
    stopped)
      log "$INSTANCE_ID is stopped; starting it..."
      "${AWS[@]}" ec2 start-instances --instance-ids "$INSTANCE_ID" > /dev/null \
        || { log "Could not start $INSTANCE_ID (are you allowed to start it?)."; exit 1; }
      ;;
    pending|stopping) log "$INSTANCE_ID is $STATE; waiting..." ;;
    *) log "$INSTANCE_ID is '$STATE' and cannot be connected to."; exit 1 ;;
  esac
  [ "$SECONDS" -lt "$DEADLINE" ] || { log "Timed out waiting for $INSTANCE_ID to start."; exit 1; }
  sleep 5
done

# A freshly started server needs a moment before the SSM agent is online.
DEADLINE=$((SECONDS + 300))
until [ "$(ping_status)" = "Online" ]; do
  [ "$SECONDS" -lt "$DEADLINE" ] || { log "$INSTANCE_ID is running but Session Manager cannot reach it yet; try again shortly."; exit 1; }
  log "Waiting for Session Manager to reach $INSTANCE_ID..."
  sleep 5
done

exec "${AWS[@]}" ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartSSHSession --parameters "portNumber=$PORT"
