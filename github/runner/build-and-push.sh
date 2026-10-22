#!/usr/bin/env bash
# Builds the runner image and pushes it to the ECR repository created by the
# github-actions-fargate-runner stack.
#
# Usage: ./build-and-push.sh <stack-name> [region] [tag]
#   Architecture is read from the stack's CpuArchitecture parameter.
#   Set RUNNER_VERSION=x.y.z to pin the actions/runner version (default: latest).
set -euo pipefail

STACK="${1:?Usage: $0 <stack-name> [region] [tag]}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
TAG="${3:-latest}"
: "${REGION:?Region not set: pass it as the 2nd argument or set AWS_REGION}"

cd "$(dirname "${BASH_SOURCE[0]}")/image"

stack_query() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" --query "$1" --output text
}

REPO_URI="$(stack_query "Stacks[0].Outputs[?OutputKey=='RunnerRepositoryUri'].OutputValue")"
if [ -z "$REPO_URI" ] || [ "$REPO_URI" = "None" ]; then
  echo "Stack has no RunnerRepositoryUri output (ContainerImage was set); push to your own registry instead." >&2
  exit 1
fi

ARCH="$(stack_query "Stacks[0].Parameters[?ParameterKey=='CpuArchitecture'].ParameterValue")"
case "$ARCH" in
  ARM64) PLATFORM=linux/arm64 ;;
  *)     PLATFORM=linux/amd64 ;;
esac

echo "Building $REPO_URI:$TAG for $PLATFORM"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO_URI%%/*}"

docker buildx build \
  --platform "$PLATFORM" \
  --build-arg "RUNNER_VERSION=${RUNNER_VERSION:-}" \
  -t "$REPO_URI:$TAG" \
  --push .

echo "Pushed $REPO_URI:$TAG"
