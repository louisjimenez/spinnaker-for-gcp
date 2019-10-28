#!/bin/bash

set -e

cd spinnaker-for-gcp
git checkout louis/ci

REPO_PATH=/workspace PROPERTIES_FILE=/workspace/properties CI=true /workspace/spinnaker-for-gcp/scripts/install/setup.sh