#!/usr/bin/env bash

set -e

bold() {
  # tput: No value for $TERM and no -T specified
  echo ". $(tput bold)" "$*" "$(tput sgr0)";
}

check_for_command() {
  COMMAND_PRESENT=$(command -v $1)
  echo $COMMAND_PRESENT
}

GIT_PATH=$(check_for_command git)

if [ -z "$GIT_PATH" ]; then
  bold "git command not supported"
  exit 1
fi

cd ~
git clone https://github.com/GoogleCloudPlatform/spinnaker-for-gcp.git
git config --global user.name "CI"
git config --global user.email "ci@example.com"
cd spinnaker-for-gcp
exec scripts/install/setup_properties.sh
