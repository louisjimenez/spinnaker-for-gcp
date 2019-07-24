#!/usr/bin/env bash

bold() {
  echo ". $(tput bold)" "$*" "$(tput sgr0)";
}

~/spinnaker-for-gcp/scripts/manage/check_git_config.sh || exit 1

# Sync cloudshell config with cluster.
~/spinnaker-for-gcp/scripts/manage/pull_config.sh

source ~/spinnaker-for-gcp/scripts/install/properties &> /dev/null

deleteExistingCloudFunc() {
  gcloud functions delete $CLOUD_FUNCTION_NAME --project $PROJECT_ID -q
}

if [ -z "$1" ]; then
  bold "Project id is required"
  exit 1
fi

if [ -z "$2" ]; then
  bold "Repository name is required"
  exit 1
fi

PROJECT_ID=$1
CONFIG_CSR_REPO=$2
GIT_HASH=$3

TEMP_DIR=$(mktemp -d -t halyard.XXXXX)
pushd $TEMP_DIR

EXISTING_CSR_REPO=$(gcloud source repos list --format="value(name)" --filter="name=projects/$PROJECT_ID/repos/$CONFIG_CSR_REPO" --project=$PROJECT_ID)

if [ -z "$EXISTING_CSR_REPO" ]; then
  gcloud source repos clone $CONFIG_CSR_REPO --project=$PROJECT_ID
else
  popd
  rm -rf $TEMP_DIR
fi

if [ -n "$GIT_HASH" ]; then
    bold "Compare $GIT_HASH to the most recent backup:"
    bold "https://source.cloud.google.com/restore-test-249019/spinnaker-1-config/+/$GIT_HASH...master"
fi

read -p ". $(tput bold)You are about to restore a backup configuration. This step is not reversible. Do you wish to continue (Y/n)? $(tput sgr0)" yn
case $yn in
  [Yy]* ) ;;
  "" ) ;;
  * ) 
    popd
    rm -rf $TEMP_DIR
    exit
  ;;
esac

EXISTING_CLOUD_FUNCTION=$(gcloud functions list --project $PROJECT_ID \
  --format="value(name)" --filter="entryPoint=$CLOUD_FUNCTION_NAME")

if [ -n "$EXISTING_CLOUD_FUNCTION" ]; then
  deleteExistingCloudFunc 
fi

cd $CONFIG_CSR_REPO
if [ -n "$GIT_HASH" ]; then
 git checkout $GIT_HASH &> /dev/null
fi

# Remove local hal config so persistent config from backup can be copied into place.
bold "Removing $HOME/.hal..."
rm -rf ~/.hal

# Copy persistent config into place.
bold "Copying $CONFIG_CSR_REPO/.hal into $HOME/.hal..."

REWRITABLE_KEYS=(kubeconfigFile jsonPath jsonKey)
for k in "${REWRITABLE_KEYS[@]}"; do
  grep $k .hal/config &> /dev/null
  FOUND_TOKEN=$?

  if [ "$FOUND_TOKEN" == "0" ]; then
    bold "Rewriting $k path to reflect local user '$USER' on Cloud Shell VM..."
    sed -i "s/$k: \/home\/spinnaker/$k: \/home\/$USER/" .hal/config
  fi
done

# We want just these subdirs from the backup to be copied into place in ~/.hal.
DIRS=(credentials profiles service-settings)

for p in "${DIRS[@]}"; do
  for f in $(find .hal/*/$p -prune 2> /dev/null); do
    SUB_PATH=$(echo $f | rev | cut -d '/' -f 1,2 | rev)
    mkdir -p ~/.hal/$SUB_PATH
    cp -RT .hal/$SUB_PATH ~/.hal/$SUB_PATH
  done
done

cp .hal/config ~/.hal

remove_and_copy() {
  if [ -e $1 ]; then
    cp $1 $2
  elif [ -e $2 ]; then
    rm $2
  fi
}

cd deployment_config_files
bold "Restoring deployment config..."
remove_and_copy properties ~/spinnaker-for-gcp/scripts/install/properties 
remove_and_copy config.json ~/spinnaker-for-gcp/scripts/install/spinnakerAuditLog/config.json
remove_and_copy index.js ~/spinnaker-for-gcp/scripts/install/spinnakerAuditLog/index.js
remove_and_copy landing_page_expanded.md ~/spinnaker-for-gcp/scripts/manage/landing_page_expanded.md

remove_and_copy configure_iap_expanded ~/spinnaker-for-gcp/scripts/expose/configure_iap_expanded.md
remove_and_copy openapi_expanded.yml ~/spinnaker-for-gcp/scripts/expose/openapi_expanded.yml
remove_and_copy config ~/.spin/config
remove_and_copy key.json ~/.spin/key.json

HALYARD_POD=spin-halyard-0
EXISTING_HAL_POD_NAME=$(kubectl get pods -n halyard --field-selector metadata.name="$HALYARD_POD" -o json | jq -r  .items[0].metadata.name)

if [ $EXISTING_HAL_POD_NAME != 'null' ]; then
  # Remove old persistent config so new config can be copied into place.
  bold "Removing halyard/$HALYARD_POD:/home/spinnaker/.hal..."
  kubectl -n halyard exec -it $HALYARD_POD -- bash -c "rm -rf ~/.hal/*"

  # Copy new config into place.
  bold "Copying $HOME/.hal into halyard/$HALYARD_POD:/home/spinnaker/.hal..."

  kubectl -n halyard cp $TEMP_DIR/$CONFIG_CSR_REPO/.hal spin-halyard-0:/home/spinnaker
fi

popd
rm -rf $TEMP_DIR

~/spinnaker-for-gcp/scripts/install/setup.sh -r
~/spinnaker-for-gcp/scripts/manage/update_console.sh