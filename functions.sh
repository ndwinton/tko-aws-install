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
    if [[ -z $(echo -n "${!varName}") ]]
    then
      fatal "Value for variable $varName is missing at line $(caller)"
    fi
  done
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

function findAvailabilityZones {
  aws ec2 describe-availability-zones | jq -r '.AvailabilityZones[].ZoneName'
}

function checkAvailabilityZones {
  local azNames=$(findAvailabilityZones)
  local azCount=$(echo $azNames | wc -w)

  if (($azCount < 3))
  then
    message "WARNING: Too few availability zones. Need 3 for production deployment but only found $azCount"
  fi
}

function setupWorkingDirectory {
  requireValue WORKING_DIR TKG_INSTALL_TAG

  banner "Setting up working state directory"

  if [[ -d $WORKING_DIR ]]
  then
    message "Working state directory $WORKING_DIR already exists"
    if [[ $TKG_INSTALL_TAG != $(<$WORKING_DIR/TKG_INSTALL_TAG) ]]
    then
      fatal "TKG_INSTALL_TAG value '$(<$WORKING_DIR/TKG_INSTALL_TAG)' for working state directory $WORKING_DIR does not match supplied value '$TKG_INSTALL_TAG'"
    fi
  else
    message "Creating state directory $WORKING_DIR"
    mkdir -p $WORKING_DIR
    echo -n $TKG_INSTALL_TAG > $WORKING_DIR/TKG_INSTALL_TAG
  fi
}

function createVpc {
  banner "Creating VPC"

  if usableState $WORKING_DIR/vpc
  then
    message "Using previously created VPC"
  else
    aws ec2 create-vpc --cidr-block 172.16.0.0/16 --tag-specifications "ResourceType=vpc, Tags=[{Key=Name,Value=TKGVPC-$TKG_INSTALL_TAG}]"  --output json > $WORKING_DIR/vpc
  fi
  local vpcId=$(findVpcId)
  requireValue vpcId
  message "VPC ID: $vpcId"
}

function usableState {
  [[ -r $1 && -s $1 ]] && egrep -q '^[^[:space:]]+$' $1
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
    for az in $(findAvailabilityZones)
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
    requireValue subnetId
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
  requireValue inetGwId
  message "Internet Gateway ID: $inetGwId"
  message "Applying tags to gateway"
  aws ec2 create-tags \
    --resources $inetGwId \
    --tags Key=Name,Value="tkg-inet-gw-$TKG_INSTALL_TAG"

  local vpcId=$(findVpcId)
  requireValue vpcId
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
  requireValue allocationId
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
  requireValue natGwId
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
  requireValue tgwId
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
  local attachmentId=$(findTransitGwAttachmentId)
  requireValue attachmentId
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

function findTransitGwAttachmentId {
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
  requireValue privateRouteTableId
  message "Private Route Table ID: $privateRouteTableId"

  message "Adding tags"
  aws ec2 create-tags --resources $privateRouteTableId --tags "Key=Name,Value=tkgvpc-priv-rt-$TKG_INSTALL_TAG"

  message "Creating NAT route (ignore any RouteAlreadyExists errors)"
  aws ec2 create-route \
    --route-table-id $privateRouteTableId \
    --destination-cidr-block "0.0.0.0/0" \
    --nat-gateway-id $(findNatGwId)

  message "Creating transit gateway route"
  local transitGwId=$(findTransitGwId)
  waitForTransitGateway $transitGwId
  # Route any corporate IPs through your transit gw
  aws ec2 create-route \
    --route-table-id $privateRouteTableId \
    --destination-cidr-block "172.16.0.0/12" \
    --transit-gateway-id $transitGwId

  message "Associating private route table with subnets"
  local subnetFile subnetId
  for subnetFile in $WORKING_DIR/subnet-priv-*
  do
    subnetId="$(findSubnetIdFor $subnetFile)"
    requireValue subnetId
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
  requireValue publicRouteTableId
  message "Public Route Table ID: $publicRouteTableId"

  message "Adding tags"
  aws ec2 create-tags --resources $publicRouteTableId --tags "Key=Name,Value=tkgvpc-pub-rt-$TKG_INSTALL_TAG"

  message "Creating internet gateway route"
  aws ec2 create-route \
  --route-table-id "$publicRouteTableId" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id $(findInternetGwId)

  message "Creating transit gateway route"
  local transitGwId=$(findTransitGwId)
  waitForTransitGateway $transitGwId
  # Route any corporate IPs through your transit gw
  aws ec2 create-route \
  --route-table-id $publicRouteTableId \
  --destination-cidr-block "172.16.0.0/12" \
  --transit-gateway-id $transitGwId

  message "Associating public route table with subnets"
  local subnetFile subnetId
  for subnetFile in $WORKING_DIR/subnet-pub-*
  do
    subnetId="$(findSubnetIdFor $subnetFile)"
    requireValue subnetId
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

function createCloudFormationStackIfNecessary {
  banner "Checking for IAM resources"

  local template="$1"
  local instanceProfiles=$(aws iam list-instance-profiles | jq -r '.InstanceProfiles[].InstanceProfileName' | sort | grep '\.tkg\.cloud\.vmware.com$')
  local policies=$(aws iam list-policies --scope Local | jq -r '.Policies[].PolicyName' | sort | grep '\.tkg\.cloud\.vmware.com$')
  local roles=$(aws iam list-roles | jq -r '.Roles[].RoleName' | sort | grep '\.tkg\.cloud\.vmware.com$')
  if [[ "$instanceProfiles/$policies/$roles" == "//" ]]
  then
    createCloudFormationStack "$1"
  else
    checkIamResources 'instance profile' $instanceProfiles
    checkIamResources 'policy' $policies
    checkIamResources 'role' $roles
    message "All necessary resources already exist"
  fi
}

function checkIamResources {
  local -A present
  local expected="control-plane.tkg.cloud.vmware.com controllers.tkg.cloud.vmware.com nodes.tkg.cloud.vmware.com"
  local resource="$1"
  shift

  local arg
  for arg in $*
  do
    present[$arg]="true"
  done

  # OK if all expected elements are there, fatal error otherwise
  for arg in $expected
  do
    [[ "${present[$arg]}" == "true" ]] || fatal "Missing some IAM resources of type $resource" \
      "Expected: $expected" \
      "Found: $*"
  done
}

function createCloudFormationStack {
  message "Creating tkg-cloud-vmware-com CloudFormation stack"

  aws cloudformation create-stack --stack-name tkg-cloud-vmware-com --template-body "$(< $1)" --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
}

function createJumpbox {
  banner "Creating jumpbox"

  if usableState $WORKING_DIR/sg_jumpbox_ssh
  then
    message "Using previously created security group"
  else
    message "Setting up jumpbox-ssh security group"
    aws ec2 create-security-group \
      --group-name "jumpbox-ssh-$TKG_INSTALL_TAG" \
      --description "To Jumpbox $TKG_INSTALL_TAG" \
      --vpc-id "$(findVpcId)" --output json > $WORKING_DIR/sg_jumpbox_ssh
  fi
  local groupId=$(findId .GroupId $WORKING_DIR/sg_jumpbox_ssh)
  requireValue groupId

  aws ec2 create-tags \
    --resources $groupId \
    --tags Key=Name,Value="jumpbox-ssh-$TKG_INSTALL_TAG"

  message "Authorizing SSH to jumpbox (ignore any InvalidPermission.Duplicate errors)"
  aws ec2 authorize-security-group-ingress \
    --group-id  $groupId --protocol tcp --port 22 --cidr "0.0.0.0/0"

# Save this file or use some team keypair already created

  if usableState $WORKING_DIR/tkgkp.pem
  then
    message "Using previously created key-pair"
  else
    aws ec2 create-key-pair --key-name tkg-kp-$TKG_INSTALL_TAG --query 'KeyMaterial' --output text > $WORKING_DIR/tkgkp.pem
    chmod 400 $WORKING_DIR/tkgkp.pem
  fi

  if usableState $WORKING_DIR/instance_jb_starting
  then
    message "Using previously created jumpbox"
  else
    # Using AMI for Focal Fossa (Ubuntu 20.04)
    local amiId=$(findAmi $AWS_REGION focal | head -n 1)
    requireValue amiId
    aws ec2 run-instances \
      --image-id $amiId \
      --count 1 \
      --instance-type t2.medium \
      --key-name tkg-kp-$TKG_INSTALL_TAG \
      --security-group-ids $groupId \
      --subnet-id $(findSubnetIdFor $WORKING_DIR/subnet-pub-a) \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=tkg-jumpbox-$TKG_INSTALL_TAG}]" \
      --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=64}' > $WORKING_DIR/instance_jb_starting
  fi

  waitForJumpbox
}

function findJumpboxId {
  findId '.Instances[0].InstanceId' $WORKING_DIR/instance_jb_starting
}

function waitForJumpbox {
  local jumpboxIp
  local status=not-ready

  while [[ $status != 'up-and-running' ]]
  do
    message "Waiting for jumpbox ..."
    sleep 10
    jumpboxIp=$(findJumpboxPublicIp)
    status=$(ssh ubuntu@$jumpboxIp \
      -i $WORKING_DIR/tkgkp.pem \
      -oStrictHostKeyChecking=accept-new \
      echo 'up-and-running')
  done
  message "Jumpbox ready"
}

_CACHED_JB_IP_=''
function findJumpboxPublicIp {

  if [[ "$_CACHED_JB_IP_" != "" ]]
  then
    echo $_CACHED_JB_IP_
    return 0
  fi

  local instanceId=$(findJumpboxId)
  requireValue instanceId
  aws ec2 describe-instances --instance-id $instanceId > $WORKING_DIR/instance_jb_started
  local ip=$(findId '.Reservations[0].Instances[0].PublicIpAddress' $WORKING_DIR/instance_jb_started)
  if [[ "$ip" =~ *.*.*.* ]]
  then
    _CACHED_JB_IP_=$ip
  fi
  echo $ip
}

function runOnJumpbox {
  local jumpboxIp=$(findJumpboxPublicIp)
  requireValue jumpboxIp
  ssh -i $WORKING_DIR/tkgkp.pem ubuntu@$jumpboxIp "$@"
}

function copyToJumpbox {
  local jumpboxIp=$(findJumpboxPublicIp)
  requireValue jumpboxIp
  scp -i $WORKING_DIR/tkgkp.pem "$1" ubuntu@$jumpboxIp:/home/ubuntu/$2
}

function updateJumpbox {
  banner "Updating and installing base software on jumpbox"

  cat > $WORKING_DIR/update-jumpbox.sh <<'EOF'
#!/bin/sh

set -x

sudo apt update -y
sudo apt install -y docker.io screen
sudo adduser ubuntu docker
sudo reboot
EOF
  copyToJumpbox $WORKING_DIR/update-jumpbox.sh

  message "Executing update script (system will reboot)"
  runOnJumpbox /bin/sh /home/ubuntu/update-jumpbox.sh

  waitForJumpbox
}

function installTanzuSoftware {
  banner "Installing Tanzu software on jumpbox"

  cat > $WORKING_DIR/install-tanzu-software.sh <<'EOSH'
#!/bin/sh

set -x

# Find latest modified gzip file, in case of multiple uploads
kubectl_gzip=$(ls -1tr kubectl-linux-*.gz | tail -n 1)
kubectl_base=${kubectl_gzip%.gz}
gunzip $kubectl_gzip
sudo install $kubectl_base /usr/local/bin/kubectl

# Install kind (useful for early failure debugging)
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.12.0/kind-linux-amd64
chmod +x ./kind
sudo install kind /usr/local/bin/kind

rm -rf ./cli
tar -xvf tanzu-cli-bundle-linux-amd64.tar
cd cli/
sudo install core/v1.*/tanzu-core-linux_amd64 /usr/local/bin/tanzu
gunzip *.gz
sudo install imgpkg-linux-amd64-* /usr/local/bin/imgpkg
sudo install kapp-linux-amd64-* /usr/local/bin/kapp
sudo install kbld-linux-amd64-* /usr/local/bin/kbld
sudo install vendir-linux-amd64-* /usr/local/bin/vendir
sudo install ytt-linux-amd64-* /usr/local/bin/ytt
cd ..
tanzu plugin install --local cli all

# Create custom Load Balancer control file
tanzu config init
cat <<EOF > ~/.config/tanzu/tkg/providers/ytt/03_customizations/internal_lb.yaml
#@ load("@ytt:overlay", "overlay")
#@ load("@ytt:data", "data")

#@overlay/match by=overlay.subset({"kind":"AWSCluster"})
---
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha3
kind: AWSCluster
spec:
#@overlay/match missing_ok=True
  controlPlaneLoadBalancer:
#@overlay/match missing_ok=True
    scheme: "internal"

EOF
EOSH

  message "Copying files to jumpbox"

  copyToJumpbox $WORKING_DIR/install-tanzu-software.sh
  copyToJumpbox $DOWNLOADED_KUBECTL

  # Because the CLI bundle is so big, try to avoid copying this
  local cliSha=$(shasum $DOWNLOADED_TANZU_CLI_BUNDLE | awk '{ print $1; }')
  local remoteCliSha=$(runOnJumpbox shasum /home/ubuntu/tanzu-cli-bundle-linux-amd64.tar | awk '{ print $1; }')
  if [[ "$cliSha" == "$remoteCliSha" ]]
  then
    message "Tanzu CLI bundle already up to date - not copied"
  else
    copyToJumpbox $DOWNLOADED_TANZU_CLI_BUNDLE tanzu-cli-bundle-linux-amd64.tar
  fi

  message "Running install script"

  runOnJumpbox /bin/sh /home/ubuntu/install-tanzu-software.sh
}

function startInstaller {
  banner "Starting TKG installer"

  local credentials="$(aws sts get-session-token)"
  requireValue credentials
  local sessionAccessKeyId=$(echo "$credentials" | jq -r .Credentials.AccessKeyId)
  local sessionSecretAccessKey=$(echo "$credentials" | jq -r .Credentials.SecretAccessKey)
  local sessionToken=$(echo "$credentials" | jq -r .Credentials.SessionToken)

  cat <<EOT

The TKG installer will be running on http://localhost:8080.

=== NOTE ===
Temporary session credentials have been generated and are shown
below. These are NOT the values you supplied to this script.

The following information will be needed during the installation:

  * Access Key ID: $sessionAccessKeyId
  * Secret Access Key:$sessionSecretAccessKey
  * Session Token: $sessionToken
  * Region: $AWS_REGION
  * SSH key name: tkg-kp-$TKG_INSTALL_TAG
  * VPC ID: $(findVpcId)

EOT

  runOnJumpbox -L 8080:localhost:8080 tanzu management-cluster create --ui
}