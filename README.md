# Fedora CoreOS for VMWare vSphere

This repository contains minimal examples for [Fedora CoreOS](https://docs.fedoraproject.org/en-US/fedora-coreos/)
configurations and scripts that help deploy them on VMWare vSphere (or Fusion).

The base setup contains an [etcd](https://etcd.io) cluster consisting of three members, a [Traefik](https://traefik.io)
edge router, and a [hello-world application](https://github.com/mendhak/docker-http-https-echo) each in their own Fedora
CoreOS VM. Service 'discovery' is done by pushing service information into the etcd cluster on VM startup which is then
read by Traefik. On VM shutdown the information [is deleted](https://github.com/horaios/fedora-coreos-example/issues/1)
from etcd and Traefik stops serving traffic there.

Each VM will be provisioned with [SSH certificates](https://smallstep.com/blog/use-ssh-certificates/) by default, the
configuration can be extended with client certificates as
outlined [here](https://github.com/coreos/butane/issues/210#issuecomment-824212588).

---

The shell script template used for the generator scripts is the MIT licensed
[script-template.sh](https://gist.github.com/m-radzikowski/53e0b39e9a59a1518990e76c2bff8038) by Maciej Radzikowski.

## Required Software

- [bash](https://www.gnu.org/software/bash/) scripting environment
- [butane](https://github.com/coreos/butane) Fedora CoreOS configuration converter
- [curl](https://github.com/curl/curl) curl to download files off of the Internet
- [govc](https://github.com/vmware/govmomi/) vSphere client software
- [gpg](https://www.gnupg.org/) OpenPGP implementation for signature checks
- [jq](https://stedolan.github.io/jq/) JSON parser
- [ssh](https://www.openssh.com) SSH implementation

A way to provide TLS and SSH certificates. You can use [simple-ca](https://github.com/horaios/simple-file-ca) to get
started quickly and without modifying the scripts if you simply want to get started quickly and play around.

### Windows

- For a Bash based environment it is easiest to use [Git for Windows](https://gitforwindows.org)
	- make sure to select the Windows Terminal Profile Fragment during installation for a better user experience later
	  on
	- also make sure to use the Windows Secure Channel library if you plan on rolling out certificates to your machine
	  otherwise you'll have to manually patch the bundled certificate bundle
	- make sure to use "Checkout as-is, commit as-is" to not break line endings of existing files
	- this includes a compatible curl, GPG, and OpenSSH version by default
- Instead of using the MinTTY console installed by Git consider
  use [Windows Terminal](https://github.com/microsoft/terminal) instead for a better user experience
- For a simple installation consider using [Scoop](https://scoop.sh)
	- alternatively, you have to manually add _butane_, _govc_, and _jq_ to your `$PATH` environment variable

## VM Configuration Contents

The Butane configuration files contain pieces for the following tools along side the actual service configurations:

- [Docker](https://docs.docker.com/reference/)
- [NetworkManager](https://developer.gnome.org/NetworkManager/stable/NetworkManager.html),
  [NetworkManager CLI Documentation](https://developer.gnome.org/NetworkManager/stable/nmcli.html)
- [rpm-ostree](https://coreos.github.io/rpm-ostree/), [rpm-ostree manpage](https://www.mankier.com/1/rpm-ostree)
- [SSH](https://docs.fedoraproject.org/en-US/fedora/rawhide/system-administrators-guide/infrastructure-services/OpenSSH/)
- [Systemd Unit](https://www.freedesktop.org/software/systemd/man/systemd.directives.html)
- [Zincati](https://coreos.github.io/zincati/)

## Getting started

Please note the VM configs contain references to additional disks in the `storage` section – they have to be removed in
case you want to launch on VMWare Fusion (or Workstation). The OVA conversion doesn't account for them.

1. Deploy the etcd cluster
2. Once provisioning is finished and the VM is in its second boot (required for installing VMWare tools), log into each
   member machine and change the cluster state from `new` to `existing`
   in `/etc/systemd/system.conf.d/10-default-env.conf`
3. In the meanwhile you can deploy Traefik
4. The base infrastructure should now be in place to add additional services, such as the `hello-world` example.

## General Usage

Because of the dynamic nature of the SSH host key pairs and certificates the passphrase for the root key pair and the
path to the private key has to be provided either as environment variable (`SIMPLE_CA_SSH_PASSWORD`) or as inline shell
parameter (`-i`).

The following command will generate an [Ignition](https://coreos.github.io/ignition/) configuration using the TLS
certificates provided by a `simple-ca` based certificate authority and the aforementioned root key pair for the SSH host
certificates for the `hello-world` Butane configuration. During the script run the latest stable CoreOS version will be
downloaded, verified, and uploaded to the default vSphere/vCenter template library. Once done, the template item will be
deployed as `hello-world` VM with the hardware specification derived from the `resources.json` and the Ignition
configuraton applied. In the end the VM will be powered on and start the provisioning process.

```bash
export GOVC_URL='vcenter.example.local'
export GOVC_USERNAME='username@vsphere.local'
export GOVC_PASSWORD='password'

./deploy.sh -s stable -d ~/Downloads/coreos/ \
-n hello-world -b ./hello-world/hello-world.yaml \
-t /Volumes/simple-ca/data/intermediate-ca-name \
-g '/Volumes/simple-ca/data/ssh-ca/ca' -i 'sshpassword' \
-o
```

Don't forget to read the documentation via `--help` to see what other flags and settings can be specified.

### Updating VMs

Simply deleting VMs via the vCenter/vSphere management UI will cause all attached disks to be deleted, including ones
you may want to keep. There is no confirmation or selection dialog to prevent this. To prevent this an `undeploy.sh`
script was added that unmounts the non-system disks after a clean shutdown of the VM and allows you to reuse them. This
is handy during a redeployment of an "existing" VM:

```bash
export GOVC_URL='vcenter.example.local'
export GOVC_USERNAME='username@vsphere.local'
export GOVC_PASSWORD='password'
# dry-run
./undeploy.sh -n fcos-hello-world
# List of resources to be removed
#...
# apply removal of VM but keep data volumes
./undeploy.sh -n fcos-hello-world -a
```

Running a `deploy.sh` run afterwards for `hello-world` will reattach the existing disks.

### Deleting VMs

If you want to remove all data, either do so via the vSphere/vCenter UI or run `remove.sh`. This will remove all VM
related information including all disks.

```bash
export GOVC_URL='vcenter.example.local'
export GOVC_USERNAME='username@vsphere.local'
export GOVC_PASSWORD='password'
# dry-run
./remove.sh -n fcos-hello-world
# List of resources to be removed
# ...
# apply removal of VM and data volumes
./remove.sh -n fcos-hello-world -a
```
