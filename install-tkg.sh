#!/usr/bin/env bash

source $(dirname $0)/functions.sh

banner "Setting up environment"

findOrPrompt AWS_ACCESS_KEY_ID "AWS Access Key ID" true
findOrPrompt AWS_SECRET_ACCESS_KEY "AWS Secret Access Key" true
findOrPromptWithDefault AWS_REGION "Region with at least 3 available AZs" us-east-1
findOrPromptWithDefault TKG_INSTALL_TAG "Unique tag for this installation" $(date +%Y%m%d)
findOrPromptWithDefault TKG_INSTALL_STATE_DIR "Installation state directory" $(pwd)/tkg-install-$TKG_INSTALL_TAG

defaultCliDownload=$(find . ~/Downloads -name 'tanzu-cli-bundle-linux-amd64.tar' | head -n 1)
defaultKubectlDownload=$(find . ~/Downloads -name 'kubectl-linux-*+vmware.*.gz' | head -n 1)

findOrPromptWithDefault DOWNLOADED_TANZU_CLI_BUNDLE "Tanzu CLI bundle tar file" $defaultCliDownload
findOrPromptWithDefault DOWNLOADED_KUBECTL "VMware kubectl gzip file" $defaultKubectlDownload

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"
# The variable WORKING_DIR is used within the scripts to better
# align with the deployment documentation, but the external name
# of TKG_INSTALL_STATE_DIR is more descriptive for users.
export WORKING_DIR="$TKG_INSTALL_STATE_DIR"
export DOWNLOADED_TANZU_CLI_BUNDLE
export DOWNLOADED_KUBECTL

[[ -r $DOWNLOADED_TANZU_CLI_BUNDLE ]] || fatal "Can't find or read Tanzu CLI bundle file $DOWNLOADED_TANZU_CLI_BUNDLE"
[[ -r $DOWNLOADED_KUBECTL ]] || fatal "Can't find or read kubectl gzip file DOWNLOADED_KUBECTL"

FORMATION_TEMPLATE="$(dirname $0)/tkg-cloud-vwmare-com.cloudformation.yaml"

setupWorkingDirectory
checkAvailabilityZones
createVpc
createSubnets
createInternetGateway
createNatGateway
createTransitGateway
createPrivateRouteTable
createPublicRouteTable
createJumpbox
updateJumpbox
installTanzuSoftware
createCloudFormationStackIfNecessary "$FORMATION_TEMPLATE"
startInstaller
