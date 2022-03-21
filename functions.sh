#!/usr/bin/env bash


function banner {
  local line
  echo ""
  echo "###"
  for line in "$@"
  do
    echo "### $line"
  done
  echo "###"
  echo ""
}

function message {
  local line
  for line in "$@"
  do
    echo ">>> $line"
  done
}

function fatal {
  message "ERROR: $*" >&2
  exit 1
}

function findOrPrompt {
  local varName="$1"
  local prompt="$2"
  local secret=${3-false}

  if [[ -z "${!varName}" ]]
  then
    echo "$varName not found in environment"
    read -p "$prompt: " $varName
  elif $secret
  then
    echo "Value for $varName found in environment: <SECRET>"
  else
    echo "Value for $varName found in environment: ${!varName}"
  fi
}

function findOrPromptWithDefault {
  local varName="$1"
  local prompt="$2"
  local default="$3"

  findOrPrompt "$varName" "$prompt [$default]"
  if [[ -z "${!varName}" ]]
  then
    export ${varName}="$default"
  fi
}

function requireValue {
  local varName

  for varName in $*
  do
    if [[ -z "${!varName}" ]]
    then
      fatal "Variable $varName is missing at line $(caller)"
    fi
  done
}

function hostIp {
  # This works on both macOS and Linux
  ifconfig -a | awk '/^(en|wl)/,/(inet |status|TX error)/ { if ($1 == "inet") { print $2; exit; } }'
}

function aws {
  requireValue AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_REGION
  
  docker run \
    -eAWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
    -eAWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
    -eAWS_DEFAULT_REGION=${AWS_DEFAULT_REGION} \
    -eAWS_REGION=${AWS_REGION} \
    -eAWS_PAGER="" \
    --rm -v $(pwd):/aws amazon/aws-cli "$@"
}

function createVpc {
  banner "Creating VPC"

  if usableState $WORKING_DIR/vpc
  then
    message "Using previously created VPC"
  else
    aws ec2 create-vpc --cidr-block 172.16.0.0/16 --tag-specifications 'ResourceType=vpc, Tags=[{Key=Name,Value=TKGVPC}]'  --output json > $WORKING_DIR/vpc
  fi
  message "VPC ID: $(findVpcId)"
}

function usableState {
  [[ -r $1 && -s $1 ]]
}

function findId {
  local jqExpr="$1"
  local file="$2"

  if [[ ! -r $file ]]
  then
    fatal "JSON data file '$file' does not exist or can't be read!"
  fi
  local id="$(jq -r "$jqExpr" $file)"
  if [[ "$id" == "" ]]
  then
    fatal "Failed to extract ID from $file"
  fi
  echo "$id"
}

function findVpcId {
  findId '.Vpc.VpcId' $WORKING_DIR/vpc 
}

function createSubnets {
  banner "Creating subnets in each AZ"

  local subnet=0
  local vpcId=$(findVpcId)
  local type az azSuffix

  for type in priv pub
  do
    for az in $azNames
    do
      azSuffix=${az#$AWS_REGION}
      if usableState $WORKING_DIR/subnet-$type-$azSuffix
      then
        message "Using existing subnet-$type-$azSuffix"
      else
        aws ec2 create-subnet \
          --vpc-id $vpcId \
          --cidr-block 172.16.$subnet.0/24 \
          --availability-zone $az \
          --tag-specifications "ResourceType=subnet, Tags=[{Key=Name,Value=$type-$azSuffix}]" \
          --output json > $WORKING_DIR/subnet-$type-$azSuffix
      fi
      message "Subnet $type-$azSuffix ID: $(findSubnetIdFor $WORKING_DIR/subnet-$type-$azSuffix)"
      ((subnet = subnet + 1))
    done
  done

  banner "Setting map-public-ip-on-launch for public subnets"

  local subnetFile subnetId
  for subnetFile in $WORKING_DIR/subnet-pub-*
  do
    subnetId=$(findSubnetIdFor $subnetFile)
    aws ec2 modify-subnet-attribute --subnet-id "$subnetId" --map-public-ip-on-launch
    message "Modified $subnetId"
  done
}

function findSubnetIdFor {
  findId .Subnet.SubnetId "$1"
}

function createInternetGateway {
  banner "Creating Internet gateway and attaching to VPC"

  if usableState $WORKING_DIR/inet-gw
  then
    message "Using existing Internet gateway"
  else
    aws ec2 create-internet-gateway  --output json > $WORKING_DIR/inet-gw
  fi
  local inetGwId=$(findInternetGwId)
  message "Internet Gateway ID: $inetGwId"
  message "Applying tags to gateway"
  aws ec2 create-tags \
    --resources $inetGwId \
    --tags Key=Name,Value="tkg-inet-gw"

  local vpcId=$(findVpcId)
  local currentAttachments=$(aws ec2 describe-internet-gateways \
      --internet-gateway-ids $inetGwId | \
      jq -r .InternetGateways[].Attachments[].VpcId)
  if echo "$currentAttachments" | grep -q $vpcId
  then
    message "VPC already attached to gateway"
  else
    message "Attaching gateway to VPC"
    aws ec2 attach-internet-gateway \
      --internet-gateway-id $inetGwId \
      --vpc-id $vpcId
  fi
}

function findInternetGwId {
  findId .InternetGateway.InternetGatewayId $WORKING_DIR/inet-gw
}

function createNatGateway {
  banner "Allocating IP address and creating NAT gateway"

  if usableState $WORKING_DIR/nat-eip
  then
    message "Using previously allocated address"
  else
    aws ec2 allocate-address > $WORKING_DIR/nat-eip
  fi
  local allocationId=$(findIpAllocationId)
  message "Allocation ID: $allocationId"

  if usableState $WORKING_DIR/nat-gw
  then
    message "Using existing NAT gateway"
  else
    aws ec2 create-nat-gateway \
      --subnet $(findSubnetIdFor $WORKING_DIR/subnet-pub-a) \
      --allocation-id $allocationId \
      --output json > $WORKING_DIR/nat-gw
  fi
  local natGwId=$(findNatGwId)
  message "NAT Gateway ID: $natGwId"
}

function findIpAllocationId {
  findId .AllocationId $WORKING_DIR/nat-eip
}

function findNatGwId {
  findId .NatGateway.NatGatewayId $WORKING_DIR/nat-gw
}

function createTransitGateway {
  banner "Creating transit gateway attaching to VPC"

  if usableState $WORKING_DIR/transit-gw
  then
    message "Using previously created transit gateway"
  else
    message "Creating transit gateway"
    aws ec2 create-transit-gateway --description "For TKG Transit" > $WORKING_DIR/transit-gw
  fi
  local tgwId=$(findTransitGwId)
  message "Transit Gateway ID: $tgwId"

  waitForTransitGateway $tgwId

  if usableState $WORKING_DIR/attachment_transit_gw
  then
    message "Using existing transit gateway VPC attachment"
  else
  message "Creating transit gateway VPC attachments"
    aws ec2 create-transit-gateway-vpc-attachment \
      --transit-gateway-id  $tgwId \
      --vpc-id $(findVpcId) \
      $(findSubnetIdFor <(cat $WORKING_DIR/subnet-priv-*) | sed -e 's/^/--subnet-ids /') \
      --output json > $WORKING_DIR/attachment_transit_gw
  fi
  local attachmentId=$(findTransitGwAttachementId)
  message "Transit Gateway Attachment ID: $attachmentId"
}

function findTransitGwId {
  findId .TransitGateway.TransitGatewayId $WORKING_DIR/transit-gw
}

function transitGatewayState {
  local tgwId=$1
  aws ec2 describe-transit-gateways --transit-gateway-ids $tgwId | jq -r .TransitGateways[].State
}
function waitForTransitGateway {
  local tgwId=$1
  local state=$(transitGatewayState $tgwId)
  while [[ "$state" != "available" ]]
  do
    message "Waiting for transit gateway $tgwId to become available (currently $state)..."
    sleep 10
    state=$(transitGatewayState $tgwId)
  done
}

function findTransitGwAttachementId {
  findId .TransitGatewayVpcAttachment.TransitGatewayAttachmentId $WORKING_DIR/attachment_transit_gw
}

function createPrivateRouteTable {
  banner "Creating route table for private subnets"

  if usableState $WORKING_DIR/priv-rt
  then
    message "Using existing private route table"
  else
    aws ec2 create-route-table --vpc-id  $(findVpcId) --output json > $WORKING_DIR/priv-rt
  fi
  local privateRouteTableId=$(findPrivateRouteTableId)
  message "Private Route Table ID: $privateRouteTableId"

  message "Adding tags"
  aws ec2 create-tags --resources $privateRouteTableId --tags 'Key=Name,Value=tkgvpc-priv-rt'

  message "Creating NAT route"
  aws ec2 create-route \
    --route-table-id $privateRouteTableId \
    --destination-cidr-block "0.0.0.0/0" \
    --nat-gateway-id $(findNatGwId)

  message "Creating transit gateway route"
  # Route any corporate IPs through your transit gw
  aws ec2 create-route \
    --route-table-id $privateRouteTableId \
    --destination-cidr-block "172.16.0.0/12" \
    --transit-gateway-id $(findTransitGwId)

  message "Associating private route table with subnets"
  local subnetFile subnetId
  for subnetFile in $WORKING_DIR/subnet-priv-*
  do
    subnetId="$(findSubnetIdFor $subnetFile)"
    aws ec2 associate-route-table \
      --subnet-id $subnetId \
      --route-table-id $privateRouteTableId \
      --output json >> $WORKING_DIR/priv-rt-associations
  done
}

function findPrivateRouteTableId {
  findId .RouteTable.RouteTableId $WORKING_DIR/priv-rt
}

function findPrivateAssociationIds {
  findId .AssociationId $WORKING_DIR/priv-rt-associations | sort -u
}

function createPublicRouteTable {
  banner "Creating route table for public subnets"

  if usableState $WORKING_DIR/pub-rt
  then
    message "Using existing public route table"
  else
    message "Creating public route table"
    aws ec2 create-route-table --vpc-id  $(findVpcId) --output json > $WORKING_DIR/pub-rt
  fi
  local publicRouteTableId=$(findPublicRouteTableId)
    message "Public Route Table ID: $publicRouteTableId"

  message "Adding tags"
  aws ec2 create-tags --resources $publicRouteTableId --tags 'Key=Name,Value=tkgvpc-pub-rt'

  message "Creating internet gateway route"
  aws ec2 create-route \
  --route-table-id "$publicRouteTableId" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id $(findInternetGwId)

  message "Creating transit gateway route"
  # Route any corporate IPs through your transit gw
  aws ec2 create-route \
  --route-table-id $publicRouteTableId \
  --destination-cidr-block "172.16.0.0/12" \
  --transit-gateway-id $(findTransitGwId)

  message "Associating public route table with subnets"
  local subnetFile subnetId
  for subnetFile in $WORKING_DIR/subnet-pub-*
  do
    subnetId="$(findSubnetIdFor $subnetFile)"
    aws ec2 associate-route-table \
      --subnet-id $subnetId \
      --route-table-id $publicRouteTableId \
      --output json >> $WORKING_DIR/pub-rt-associations
  done
}

function findPublicRouteTableId {
  findId .RouteTable.RouteTableId $WORKING_DIR/pub-rt
}

function findPublicAssociationIds {
  findId .AssociationId $WORKING_DIR/pub-rt-associations | sort -u
}

# Find an AMI for the region https://cloud-images.ubuntu.com/locator/ec2/
function findAmi {
  local region="$1"
  local codename="$2"
  curl -s https://cloud-images.ubuntu.com/locator/ec2/releasesTable | \
    sed -ne "/\"$region\".*\"$codename\".*\"amd64\".*\"hvm:ebs-ssd\"/s/.*launchAmi=\(ami-[a-f0-9]*\).*/\1/p"
}

function createJumpbox {
  banner "Creating jumpbox"

  message "Setting up jumpbox-ssh security group"
  aws ec2 create-security-group \
    --group-name "jumpbox-ssh" \
    --description "To Jumpbox" \
    --vpc-id "$(findVpcId)" --output json > $WORKING_DIR/sg_jumpbox_ssh

  local groupId=$(findId .GroupId $WORKING_DIR/sg_jumpbox_ssh)
  aws ec2 create-tags \
    --resources $groupId \
    --tags Key=Name,Value="jumpbox-ssh"

  message "Authorizing SSH to jumpbox"
  aws ec2 authorize-security-group-ingress \
    --group-id  $groupId --protocol tcp --port 22 --cidr "0.0.0.0/0"

# Save this file or use some team keypair already created

  if usableState $WORKING_DIR/tkgkp.pem
  then
    message "Using previously created key-pair"
  else
    aws ec2 create-key-pair --key-name tkg-kp --query 'KeyMaterial' --output text > $WORKING_DIR/tkgkp.pem
    chmod 400 $WORKING_DIR/tkgkp.pem
  fi

# Using AMI for Focal Fossa (Ubuntu 20.04)
  local amiId=$(findAmi $AWS_REGION focal | head -n 1)
  aws ec2 run-instances \
    --image-id $amiId \
    --count 1 \
    --instance-type t2.medium \
    --key-name tkg-kp \
    --security-group-ids $groupId \
    --subnet-id $(findSubnetIdFor $WORKING_DIR/subnet-pub-a) \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=tkg-jumpbox}]' \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=64}' > $WORKING_DIR/instance_jb_starting
}

function findJumpboxId {
  findId '.Instances[0].InstanceId' $WORKING_DIR/instance_jb_starting
}