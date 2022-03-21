#!/usr/bin/env bash

source $(dirname $0)/functions.sh

banner "Setting up environment"

findOrPrompt AWS_ACCESS_KEY_ID "AWS Access Key ID" true
findOrPrompt AWS_SECRET_ACCESS_KEY "AWS Secret Access Key" true
findOrPromptWithDefault AWS_REGION "Region with at least 3 available AZs" us-east-1
findOrPromptWithDefault WORKING_DIR "Working directory" $(pwd)/tkg-vpc

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"
export WORKING_DIR

azNames=$(aws ec2 describe-availability-zones | jq -r '.AvailabilityZones[].ZoneName')
azCount=$(echo $azNames | wc -w)

if (($azCount < 3))
then
  message "WARNING: Too few availability zones. Needed 3 but only found $azCount"
fi

message "Creating working directory: $WORKING_DIR"
mkdir -p $WORKING_DIR

createVpc
createSubnets
createInternetGateway
createNatGateway
createTransitGateway
createPrivateRouteTable
createPublicRouteTable
createJumpbox
