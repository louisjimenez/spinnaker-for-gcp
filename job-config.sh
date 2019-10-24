#!/usr/bin/env bash

set -e
set +x

gcloud info --format='value(config.project)'
check_for_command() {
  COMMAND_PRESENT=$(command -v $1)
  echo $COMMAND_PRESENT
}

GIT_PATH=$(check_for_command git)

if [ -z "$GIT_PATH" ]; then
  echo "git command not supported"
  exit 1
fi

git clone https://github.com/louisjimenez/spinnaker-for-gcp.git
git config --global user.name "CI"
git config --global user.email "ci@example.com"

cd spinnaker-for-gcp
git checkout louis/iac

REPO_PATH=$WORKSPACE PROPERTIES_FILE=$PROPERTIES $WORKSPACE/spinnaker-for-gcp/scripts/install/setup.sh
