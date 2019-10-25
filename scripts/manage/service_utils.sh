#!/usr/bin/env bash

bold() {
  if [ "$CI_MODE" != true ]; then
    echo ". $(tput bold)" "$*" "$(tput sgr0)";
  else
    echo "$*"
  fi
}

has_service_enabled() {
  gcloud services list --project $1 \
    --filter="config.name:$2" \
    --format="value(config.name)"
}

check_for_command() {
  COMMAND_PRESENT=$(command -v $1)
  echo $COMMAND_PRESENT
}
