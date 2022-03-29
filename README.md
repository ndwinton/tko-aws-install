# TKO on AWS install scripts

These scripts help you to install Tanzu Kubernetes Grid (TKG) as part of Tanzu
for Kubernetes Operations(TKO), according to the
[deployment guide for AWS](https://docs.vmware.com/en/VMware-Tanzu/services/tanzu-reference-architecture/GUID-deployment-guides-tko-aws.html).
This guide follows the
[TKO Reference Architecture](https://docs.vmware.com/en/VMware-Tanzu/services/tanzu-reference-architecture/GUID-reference-designs-index.html).

These scripts are not officially supported by VMware or anyone else.
**Use at your own risk!**

## Installation

The `install-tkg.sh` script (unsurprisingly) installs TKG.
It will prompt for AWS credentials, unless they are found in the
environment.
It will also prompt for a "tag" value which it uses to create a
"state" directory named `tkg-install-<tag>` and also in the name
of resources that it creates.
If part of the installation fails, it is safe to re-run the script
using the same tag value. The script will re-use any previously
created resources for which it can find details in the state
directory.

You must download the **VMware Tanzu CLI for Linux** and **kubectl cluster cli for Linux** distribution files from the
[Customer Connect](https://customerconnect.vmware.com/downloads/details?downloadGroup=TKG-142&productId=988&rPId=73652)
site before running the script.

The script will create a VPC, subnets, gateways, routing and a
jumpbox machine.
It will upload the necessary software to the jumpbox and then start the
graphical installer to create a management cluster.

## Cleanup

The `cleanup-tkg.sh` attempts to destroy everything created by the
`install-tkg.sh` script.
It reads the state from the directory created by the install script.

It is likely that you will have to run the cleanup script multiple times
as it does not take account of how long it may take to destroy
some resources, so some later deletion operations can fail because
earlier ones have not completed.
Do not delete the state directory until you are satisfied that all
resources have been deleted.

Note that the cleanup script will *not* remove any management
or workload clusters that might have been created.
You must destroy these yourself before attempting to tear down
the jumpbox and VPC.

## A note on CloudFormation

As described in 
[this documentation](https://docs.vmware.com/en/VMware-Tanzu-Kubernetes-Grid/1.4/vmware-tanzu-kubernetes-grid-14/GUID-mgmt-clusters-aws.html?hWord=N4IghgNiBcIC4GsDmBaAxhA9gVwCYoDcBbAdzACcBTdTIkAXyA#iam-permissions):

> To enable Tanzu Kubernetes Grid to deploy clusters to Amazon EC2, you
> must create a CloudFormation stack, `tkg-cloud-vmware-com`, in your AWS
> account. This CloudFormation stack defines the identity and access
> management (IAM) resources and permissions that Tanzu Kubernetes Grid
> needs to deploy and manage clusters on Amazon EC2.

The creation of this stack only needs to be done once in an AWS account,
and should be possible by selecting the **Automate creation of AWS
CloudFormation Stack** option within one of the GUI installer
screens. However, if neither this nor running the alternative
`tanzu management-cluster permissions aws set` command work, then
you must create the stack by hand, using the AWS web console.
In this case, you can take the definition from the
`tkg-cloud-vmware-com.cloudformation.yaml` file.