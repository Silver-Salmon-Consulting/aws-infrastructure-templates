#!/usr/bin/env bash
# Runs exactly one GitHub Actions job, then exits (which stops the Fargate task).
#
# The scale-up Lambda registers a just-in-time (JIT) runner and passes its
# one-time config in RUNNER_JIT_CONFIG. A JIT runner accepts a single job and
# GitHub removes it automatically afterwards, so no PAT or deregistration step
# is needed in the container.
set -euo pipefail

: "${RUNNER_JIT_CONFIG:?RUNNER_JIT_CONFIG is required}"

cd /home/runner/actions-runner

# Hard ceiling so a runner that never receives a job cannot run (and bill) forever.
exec timeout --foreground --kill-after=30 "${RUNNER_MAX_SECONDS:-21600}" \
  ./run.sh --jitconfig "${RUNNER_JIT_CONFIG}"
