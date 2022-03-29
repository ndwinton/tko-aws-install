#!/usr/bin/env bash

source $(dirname $0)/functions.sh

banner "Setting up environment"

findOrPrompt AWS_ACCESS_KEY_ID "AWS Access Key ID" true
findOrPrompt AWS_SECRET_ACCESS_KEY "AWS Secret Access Key" true
findOrPromptWithDefault AWS_REGION "Region with at least 3 available AZs" us-east-1
findOrPromptWithDefault WORKING_DIR "Working directory" $(pwd)/tkg-install-*

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

if [[ ! -d $WORKING_DIR ]]
then
  fatal "Working directory $WORKING_DIR not found"
fi

if [[ ! -f $WORKING_DIR/TKG_INSTALL_TAG ]]
then
  fatal "Installation tag file $WORKING_DIR/TKG_INSTALL_TAG not found"
else
  export TKG_INSTALL_TAG=$(<$WORKING_DIR/TKG_INSTALL_TAG)
fi

banner "Starting cleanup"

if usableState $WORKING_DIR/instance_jb_started
then
  instanceId=$(findJumpboxId)
  message "Terminating jumpbox instance $instanceId"
  aws ec2 terminate-instances --instance-ids $instanceId
fi

if usableState $WORKING_DIR/sg_jumpbox_ssh
then
  groupId=$(findId .GroupId $WORKING_DIR/sg_jumpbox_ssh)
  message "Removing security group $groupId"
  aws ec2 delete-security-group --group-id $groupId
fi

if usableState $WORKING_DIR/pub-rt-associations
then
  for associationId in $(findPublicAssociationIds)
  do
    message "Removing public route table association $associationId"
    aws ec2 disassociate-route-table --association-id $associationId
  done
fi

if usableState $WORKING_DIR/pub-rt
then
  routeTableId=$(findPublicRouteTableId)
  message "Deleting public route table $routeTableId"
  aws ec2 delete-route-table --route-table-id $routeTableId
fi


if usableState $WORKING_DIR/priv-rt-associations
then
  for associationId in $(findPrivateAssociationIds)
  do
    message "Removing private route table association $associationId"
    aws ec2 disassociate-route-table --association-id $associationId
  done
fi

if usableState $WORKING_DIR/priv-rt
then
  routeTableId=$(findPrivateRouteTableId)
  message "Deleting private route table $routeTableId"
  aws ec2 delete-route-table --route-table-id $routeTableId
fi

if usableState $WORKING_DIR/attachment_transit_gw
then
  attachmentId=$(findTransitGwAttachmentId)
  message "Deleting transit gateway VPC attachment $attachmentId"
  aws ec2 delete-transit-gateway-vpc-attachment --transit-gateway-attachment-id=$attachmentId
fi

if usableState $WORKING_DIR/transit-gw
then
  tgwId=$(findTransitGwId)
  message "Deleting created transit gateway $tgwId"
  aws ec2 delete-transit-gateway --transit-gateway-id=$tgwId
fi

if usableState $WORKING_DIR/nat-gw
then
  natGwId=$(findNatGwId)
  message "Deleting NAT gateway $natGwId"
  aws ec2 delete-nat-gateway --nat-gateway-id=$natGwId
fi

if usableState $WORKING_DIR/nat-eip
then
  allocationId=$(findIpAllocationId)
  message "Releasing IP address allocation $allocationId"
  aws ec2 release-address --allocation-id=$allocationId
fi

if usableState $WORKING_DIR/inet-gw
then
  vpcId=$(findVpcId)
  inetGwId=$(findInternetGwId)
  message "Detaching and deleting Internet gateway $inetGwId"
  aws ec2 detach-internet-gateway --internet-gateway-id=$inetGwId --vpc-id=$vpcId
  aws ec2 delete-internet-gateway --internet-gateway-id=$inetGwId
fi

for subnetFile in $WORKING_DIR/subnet-*
do
  if usableState $subnetFile
  then
    subnetId=$(findSubnetIdFor $subnetFile)
    message "Deleting subnet $subnetId"
    aws ec2 delete-subnet --subnet-id=$subnetId
  fi
done

if usableState $WORKING_DIR/vpc
then
  vpcId=$(findVpcId)
  message "Deleting VPC $vpcId"
  aws ec2 delete-vpc --vpc-id=$vpcId
fi

banner "Completed" "Remove files from $WORKING_DIR if no longer needed"