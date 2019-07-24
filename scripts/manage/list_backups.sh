#!/usr/bin/env bash

bold() {
  echo ". $(tput bold)" "$*" "$(tput sgr0)";
}

PROPERTIES_FILE="$HOME/spinnaker-for-gcp/scripts/install/properties"

if [ -z "$PROPERTIES_FILE" ]; then
  bold "Properties file not found. A properties file is required to list backups."
  exit 1
fi

source "$PROPERTIES_FILE"

~/spinnaker-for-gcp/scripts/manage/check_project_mismatch.sh

gsutil ls -l $BUCKET_URI/backups