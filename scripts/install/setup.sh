#!/usr/bin/env bash

bold() {
  echo ". $(tput bold)" "$*" "$(tput sgr0)";
}

err() {
  echo "$*" >&2;
}

[ -z "$REPO_PATH" ] && REPO_PATH="$HOME"

$REPO_PATH/spinnaker-for-gcp/scripts/manage/check_git_config.sh || exit 1

[ -z "$PROPERTIES_FILE" ] && PROPERTIES_FILE="$REPO_PATH/spinnaker-for-gcp/scripts/install/properties"

source "$PROPERTIES_FILE"

REPO_PATH=$REPO_PATH PROPERTIES_FILE=$PROPERTIES $REPO_PATH/spinnaker-for-gcp/scripts/manage/check_project_mismatch.sh

OPERATOR_SA_EMAIL=$(gcloud config list account --format "value(core.account)")

SETUP_REQUIRED_ROLES=(compute.networkViewer container.developer iam.serviceAccountCreator redis.viewer serviceusage.serviceUsageViewer storage.admin pubsub.editor)
SETUP_EXISTING_ROLES=$(gcloud projects get-iam-policy --filter bindings.members:$OPERATOR_SA_EMAIL $PROJECT_ID \
  --flatten bindings[].members --format="value(bindings.role)")

if [ -z "$SETUP_EXISTING_ROLES" ]; then
  bold "Unable to verify the service account $OPERATOR_SA_EMAIL has the required IAM roles."
  bold "$OPERATOR_SA_EMAIL requires the IAM role \"Project IAM Admin\" to proceed with the script."
  exit 1
fi

MISSING_ROLES=""
for r in "${SETUP_REQUIRED_ROLES[@]}"; do
  if [ -z "$(echo $SETUP_EXISTING_ROLES | grep $r)" ]; then
    if [ -z $MISSING_ROLES ]; then
      MISSING_ROLES="$r"
    else 
      MISSING_ROLES="$MISSING_ROLES, $r"
    fi
  fi
done

if [ -n "$MISSING_ROLES" ]; then 
  bold "The service account being used for setup, $OPERATOR_SA_EMAIL, is missing the following required role(s): $MISSING_ROLES."
  bold "Add the required role(s) and try rerunning the script."
  exit 1
fi

REQUIRED_APIS="cloudbuild.googleapis.com cloudfunctions.googleapis.com container.googleapis.com endpoints.googleapis.com iap.googleapis.com monitoring.googleapis.com redis.googleapis.com sourcerepo.googleapis.com"
NUM_REQUIRED_APIS=$(wc -w <<< "$REQUIRED_APIS")
NUM_ENABLED_APIS=$(gcloud services list --project $PROJECT_ID \
  --filter="config.name:($REQUIRED_APIS)" \
  --format="value(config.name)" | wc -l)

if [ $NUM_ENABLED_APIS != $NUM_REQUIRED_APIS ]; then
  bold "Enabling required APIs ($REQUIRED_APIS) in $PROJECT_ID..."
  bold "This phase will take a few minutes (progress will not be reported during this operation)."
  bold
  bold "Once the required APIs are enabled, the remaining components will be installed and configured. The entire installation may take 10 minutes or more."

  gcloud services --project $PROJECT_ID enable $REQUIRED_APIS
fi

source $REPO_PATH/spinnaker-for-gcp/scripts/manage/service_utils.sh

if [ "$PROJECT_ID" != "$NETWORK_PROJECT" ]; then
  # Cloud Memorystore for Redis requires the Redis instance to be deployed in the Shared VPC
  # host project: https://cloud.google.com/memorystore/docs/redis/networking#limited_and_unsupported_networks
  if [ ! $(has_service_enabled $NETWORK_PROJECT redis.googleapis.com) ]; then
    bold "Enabling redis.googleapis.com in $NETWORK_PROJECT..."

    gcloud services --project $NETWORK_PROJECT enable redis.googleapis.com
  fi
fi

source $REPO_PATH/spinnaker-for-gcp/scripts/manage/cluster_utils.sh

CLUSTER_EXISTS=$(check_for_existing_cluster)

if [ -n "$CLUSTER_EXISTS" ]; then
  bold "Retrieving credentials for GKE cluster $GKE_CLUSTER..."
  gcloud container clusters get-credentials $GKE_CLUSTER --zone $ZONE --project $PROJECT_ID

  bold "Checking for Spinnaker application in cluster $GKE_CLUSTER..."
  SPINNAKER_APPLICATION_LIST_JSON=$(kubectl get applications -n spinnaker -l app.kubernetes.io/name=spinnaker --output json)
  SPINNAKER_APPLICATION_COUNT=$(echo $SPINNAKER_APPLICATION_LIST_JSON | jq '.items | length')

  if [ -n "$SPINNAKER_APPLICATION_COUNT" ] && [ "$SPINNAKER_APPLICATION_COUNT" != "0" ]; then
    bold "The GKE cluster $GKE_CLUSTER already contains an installed Spinnaker application."

    if [ "$SPINNAKER_APPLICATION_COUNT" == "1" ]; then
      EXISTING_SPINNAKER_APPLICATION_NAME=$(echo $SPINNAKER_APPLICATION_LIST_JSON | jq -r '.items[0].metadata.name')

      if [ "$EXISTING_SPINNAKER_APPLICATION_NAME" == "$DEPLOYMENT_NAME" ]; then
        bold "Name of existing Spinnaker application matches name specified in properties file; carrying on with installation..."
      else
        bold "Please choose another cluster."
        exit 1
      fi
    else
      # Should never be more than 1 deployment in a cluster, but protect against it just in case.
      bold "Please choose another cluster."
      exit 1
    fi
  fi
fi

NETWORK_SUBNET_MODE=$(gcloud compute networks list --project $NETWORK_PROJECT \
  --filter "name=$NETWORK" \
  --format "value(x_gcloud_subnet_mode)")

if [ -z "$NETWORK_SUBNET_MODE" ]; then
  bold "Network $NETWORK was not found in project $NETWORK_PROJECT."
  exit 1
elif [ "$NETWORK_SUBNET_MODE" = "LEGACY" ]; then
  bold "Network $NETWORK is a legacy network. This installation requires a" \
       "non-legacy network. Please specify a non-legacy network in" \
       "$PROPERTIES_FILE and re-run this script."
  exit 1
fi

# Verify that the subnet exists in the network.
SUBNET_CHECK=$(gcloud compute networks subnets list --project=$NETWORK_PROJECT \
  --network=$NETWORK --filter "region: ($REGION) AND name: ($SUBNET)" \
  --format "value(name)")

if [ -z "$SUBNET_CHECK" ]; then
  bold "Subnet $SUBNET was not found in network $NETWORK" \
       "in project $NETWORK_PROJECT. Please specify an existing subnet in" \
       "$PROPERTIES_FILE and re-run this script. You can verify" \
       "what subnetworks exist in this network by running:"
  bold "  gcloud compute networks subnets list --project $NETWORK_PROJECT --network=$NETWORK --filter \"region: ($REGION)\""
  exit 1
fi

SA_EMAIL=$(gcloud iam service-accounts --project $PROJECT_ID list \
  --filter="displayName:$SERVICE_ACCOUNT_NAME" \
  --format='value(email)')

if [ -z "$SA_EMAIL" ]; then
  bold "Creating service account $SERVICE_ACCOUNT_NAME..."

  gcloud iam service-accounts --project $PROJECT_ID create \
    $SERVICE_ACCOUNT_NAME \
    --display-name $SERVICE_ACCOUNT_NAME

  while [ -z "$SA_EMAIL" ]; do
    SA_EMAIL=$(gcloud iam service-accounts --project $PROJECT_ID list \
      --filter="displayName:$SERVICE_ACCOUNT_NAME" \
      --format='value(email)' 2>&1)
    sleep 5
  done
else
  bold "Using existing service account $SERVICE_ACCOUNT_NAME..."
fi

bold "Assigning required roles to $SERVICE_ACCOUNT_NAME..."

K8S_REQUIRED_ROLES=(cloudbuild.builds.editor container.admin logging.logWriter monitoring.admin pubsub.admin storage.admin)
EXISTING_ROLES=$(gcloud projects get-iam-policy --filter bindings.members:$SA_EMAIL $PROJECT_ID \
  --flatten bindings[].members --format="value(bindings.role)")

for r in "${K8S_REQUIRED_ROLES[@]}"; do
  if [ -z "$(echo $EXISTING_ROLES | grep $r)" ]; then
    bold "Assigning role $r..."
    gcloud projects add-iam-policy-binding $PROJECT_ID \
      --member serviceAccount:$SA_EMAIL \
      --role roles/$r \
      --format=none || exit 1
  fi
done

export REDIS_INSTANCE_HOST=$(gcloud redis instances list \
  --project $NETWORK_PROJECT --region $REGION \
  --filter="name=projects/$NETWORK_PROJECT/locations/$REGION/instances/$REDIS_INSTANCE" \
  --format="value(host)")

if [ -z "$REDIS_INSTANCE_HOST" ]; then
  bold "Creating redis instance $REDIS_INSTANCE in project $NETWORK_PROJECT..."

  gcloud redis instances create $REDIS_INSTANCE --project $NETWORK_PROJECT \
    --region=$REGION --zone=$ZONE --network=$NETWORK_REFERENCE \
    --redis-config=notify-keyspace-events=gxE

  export REDIS_INSTANCE_HOST=$(gcloud redis instances list \
    --project $NETWORK_PROJECT --region $REGION \
    --filter="name=projects/$NETWORK_PROJECT/locations/$REGION/instances/$REDIS_INSTANCE" \
    --format="value(host)")
else
  bold "Using existing redis instance $REDIS_INSTANCE ($REDIS_INSTANCE_HOST)..."
fi

# TODO: Could verify ACLs here. In the meantime, error messages should suffice.
gsutil ls $BUCKET_URI

if [ $? != 0 ]; then
  bold "Creating bucket $BUCKET_URI..."

  gsutil mb -p $PROJECT_ID $BUCKET_URI
  gsutil versioning set on $BUCKET_URI
else
  bold "Using existing bucket $BUCKET_URI..."
fi

if [ -z "$CLUSTER_EXISTS" ]; then
  bold "Creating GKE cluster $GKE_CLUSTER..."

  # TODO: Move some of these config settings to properties file.
  # TODO: Should this be regional instead?
  eval gcloud beta container clusters create $GKE_CLUSTER --project $PROJECT_ID \
    --zone $ZONE --username "admin" --network $NETWORK_REFERENCE --subnetwork $SUBNET_REFERENCE \
    --cluster-version $GKE_CLUSTER_VERSION --machine-type $GKE_MACHINE_TYPE --image-type "COS" \
    --disk-type $GKE_DISK_TYPE --disk-size $GKE_DISK_SIZE --service-account $SA_EMAIL \
    --num-nodes $GKE_NUM_NODES --enable-stackdriver-kubernetes --enable-autoupgrade \
    --enable-autorepair --enable-ip-alias --addons HorizontalPodAutoscaling,HttpLoadBalancing \
    "${CLUSTER_SECONDARY_RANGE_NAME:+'--cluster-secondary-range-name' $CLUSTER_SECONDARY_RANGE_NAME}" \
    "${SERVICES_SECONDARY_RANGE_NAME:+'--services-secondary-range-name' $SERVICES_SECONDARY_RANGE_NAME}"

  # If the cluster already exists, we already retrieved credentials way up at the top of the script.
  bold "Retrieving credentials for GKE cluster $GKE_CLUSTER..."
  gcloud container clusters get-credentials $GKE_CLUSTER --zone $ZONE --project $PROJECT_ID
else
  bold "Using existing GKE cluster $GKE_CLUSTER..."
  check_existing_cluster_prereqs
fi

GCR_PUBSUB_TOPIC_NAME=projects/$PROJECT_ID/topics/gcr
EXISTING_GCR_PUBSUB_TOPIC_NAME=$(gcloud pubsub topics list --project $PROJECT_ID \
  --filter="name=$GCR_PUBSUB_TOPIC_NAME" --format="value(name)")

if [ -z "$EXISTING_GCR_PUBSUB_TOPIC_NAME" ]; then
  bold "Creating pubsub topic $GCR_PUBSUB_TOPIC_NAME for GCR..."
  gcloud pubsub topics create --project $PROJECT_ID $GCR_PUBSUB_TOPIC_NAME
else
  bold "Using existing pubsub topic $EXISTING_GCR_PUBSUB_TOPIC_NAME for GCR..."
fi

EXISTING_GCR_PUBSUB_SUBSCRIPTION_NAME=$(gcloud pubsub subscriptions list \
  --project $PROJECT_ID \
  --filter="name=projects/$PROJECT_ID/subscriptions/$GCR_PUBSUB_SUBSCRIPTION" \
  --format="value(name)")

if [ -z "$EXISTING_GCR_PUBSUB_SUBSCRIPTION_NAME" ]; then
  bold "Creating pubsub subscription $GCR_PUBSUB_SUBSCRIPTION for GCR..."
  gcloud pubsub subscriptions create --project $PROJECT_ID $GCR_PUBSUB_SUBSCRIPTION \
    --topic=gcr
else
  bold "Using existing pubsub subscription $GCR_PUBSUB_SUBSCRIPTION for GCR..."
fi

GCB_PUBSUB_TOPIC_NAME=projects/$PROJECT_ID/topics/cloud-builds
EXISTING_GCB_PUBSUB_TOPIC_NAME=$(gcloud pubsub topics list --project $PROJECT_ID \
  --filter="name=$GCB_PUBSUB_TOPIC_NAME" --format="value(name)")

if [ -z "$EXISTING_GCB_PUBSUB_TOPIC_NAME" ]; then
  bold "Creating pubsub topic $GCB_PUBSUB_TOPIC_NAME for GCB..."
  gcloud pubsub topics create --project $PROJECT_ID $GCB_PUBSUB_TOPIC_NAME
else
  bold "Using existing pubsub topic $EXISTING_GCB_PUBSUB_TOPIC_NAME for GCB..."
fi

EXISTING_GCB_PUBSUB_SUBSCRIPTION_NAME=$(gcloud pubsub subscriptions list \
  --project $PROJECT_ID \
  --filter="name=projects/$PROJECT_ID/subscriptions/$GCB_PUBSUB_SUBSCRIPTION" \
  --format="value(name)")

if [ -z "$EXISTING_GCB_PUBSUB_SUBSCRIPTION_NAME" ]; then
  bold "Creating pubsub subscription $GCB_PUBSUB_SUBSCRIPTION for GCB..."
  gcloud pubsub subscriptions create --project $PROJECT_ID $GCB_PUBSUB_SUBSCRIPTION \
    --topic=projects/$PROJECT_ID/topics/cloud-builds
else
  bold "Using existing pubsub subscription $GCB_PUBSUB_SUBSCRIPTION for GCB..."
fi

NOTIFICATION_PUBSUB_TOPIC_NAME=projects/$PROJECT_ID/topics/$PUBSUB_NOTIFICATION_TOPIC
EXISTING_NOTIFICATION_PUBSUB_TOPIC_NAME=$(gcloud pubsub topics list --project $PROJECT_ID \
  --filter="name=$NOTIFICATION_PUBSUB_TOPIC_NAME" --format="value(name)")

if [ -z "$EXISTING_NOTIFICATION_PUBSUB_TOPIC_NAME" ]; then
  bold "Creating pubsub topic $NOTIFICATION_PUBSUB_TOPIC_NAME for notifications..."
  gcloud pubsub topics create --project $PROJECT_ID $NOTIFICATION_PUBSUB_TOPIC_NAME
else
  bold "Using existing pubsub topic $EXISTING_NOTIFICATION_PUBSUB_TOPIC_NAME for notifications..."
fi

EXISTING_HAL_DEPLOY_APPLY_JOB_NAME=$(kubectl get job -n halyard \
  --field-selector metadata.name=="hal-deploy-apply" \
  -o json | jq -r .items[0].metadata.name)

if [ $EXISTING_HAL_DEPLOY_APPLY_JOB_NAME != 'null' ]; then
  bold "Deleting earlier job $EXISTING_HAL_DEPLOY_APPLY_JOB_NAME..."

  kubectl delete job hal-deploy-apply -n halyard || exit 1
fi

bold "Provisioning Spinnaker resources..."

envsubst < $REPO_PATH/spinnaker-for-gcp/scripts/install/quick-install.yml | kubectl apply -f -

job_ready() {
  printf "Waiting on job $1 to complete"
  while [[ "$(kubectl get job $1 -n halyard -o \
            jsonpath="{.status.succeeded}")" != "1" ]]; do
    printf "."
    sleep 5
  done
  echo ""
}

job_ready hal-deploy-apply

# Sourced to import $IP_ADDR. 
# Used at the end of setup to check if installation is exposed via a secured endpoint.
source $REPO_PATH/spinnaker-for-gcp/scripts/manage/update_landing_page.sh
REPO_PATH=$REPO_PATH PROPERTIES_FILE=$PROPERTIES $REPO_PATH/spinnaker-for-gcp/scripts/manage/deploy_application_manifest.sh

# Delete any existing deployment config secret.
# It will be recreated with up-to-date contents during push_config.sh.
EXISTING_DEPLOYMENT_SECRET_NAME=$(kubectl get secret -n halyard \
  --field-selector metadata.name=="spinnaker-deployment" \
  -o json | jq .items[0].metadata.name)

if [ $EXISTING_DEPLOYMENT_SECRET_NAME != 'null' ]; then
  bold "Deleting Kubernetes secret spinnaker-deployment..."
  kubectl delete secret spinnaker-deployment -n halyard
fi

EXISTING_CLOUD_FUNCTION=$(gcloud functions list --project $PROJECT_ID \
  --format="value(name)" --filter="entryPoint=$CLOUD_FUNCTION_NAME")

if [ -z "$EXISTING_CLOUD_FUNCTION" ]; then
  bold "Deploying audit log cloud function $CLOUD_FUNCTION_NAME..."

  cat $REPO_PATH/spinnaker-for-gcp/scripts/install/spinnakerAuditLog/config_json.template | envsubst > $REPO_PATH/spinnaker-for-gcp/scripts/install/spinnakerAuditLog/config.json
  cat $REPO_PATH/spinnaker-for-gcp/scripts/install/spinnakerAuditLog/index_js.template | envsubst > $REPO_PATH/spinnaker-for-gcp/scripts/install/spinnakerAuditLog/index.js
  gcloud functions deploy $CLOUD_FUNCTION_NAME --source $REPO_PATH/spinnaker-for-gcp/scripts/install/spinnakerAuditLog \
    --trigger-http --memory 2048MB --runtime nodejs8 --project $PROJECT_ID
else
  bold "Using existing audit log cloud function $CLOUD_FUNCTION_NAME..."
fi

if [ "$USE_CLOUD_SHELL_HAL_CONFIG" = true ] ; then
  $REPO_PATH/spinnaker-for-gcp/scripts/manage/push_and_apply.sh
else
  # We want the local hal config to match what was deployed.
  $REPO_PATH/spinnaker-for-gcp/scripts/manage/pull_config.sh
  # We want a full backup stored in the bucket and the full deployment config stored in a secret.
  $REPO_PATH/spinnaker-for-gcp/scripts/manage/push_config.sh
fi

deploy_ready() {
  printf "Waiting on $2 to come online"
  while [[ "$(kubectl get deploy $1 -n spinnaker -o \
            jsonpath="{.status.readyReplicas}")" != \
           "$(kubectl get deploy $1 -n spinnaker -o \
            jsonpath="{.status.replicas}")" ]]; do
    printf "."
    sleep 5
  done
  echo ""
}

deploy_ready spin-gate "API server"
deploy_ready spin-front50 "storage server"
deploy_ready spin-orca "orchestration engine"
deploy_ready spin-kayenta "canary analysis engine"
deploy_ready spin-deck "UI server"

$REPO_PATH/spinnaker-for-gcp/scripts/cli/install_hal.sh --version $HALYARD_VERSION
$REPO_PATH/spinnaker-for-gcp/scripts/cli/install_spin.sh

# We want a backup containing the newly-created ~/.spin/* files as well.
$REPO_PATH/spinnaker-for-gcp/scripts/manage/push_config.sh

# If restoring a secured endpoint, leave the user on the documentation for iap configuration.
if [ "$USE_CLOUD_SHELL_HAL_CONFIG" = true -a -n "$IP_ADDR" ] ; then
  $REPO_PATH/spinnaker-for-gcp/scripts/expose/launch_configure_iap.sh
fi

echo
bold "Installation complete."
echo
bold "Sign up for Spinnaker for GCP updates and announcements:"
bold "  https://groups.google.com/forum/#!forum/spinnaker-for-gcp-announce"
echo
