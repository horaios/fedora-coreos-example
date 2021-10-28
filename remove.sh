#!/usr/bin/env bash

# script-template.sh https://gist.github.com/m-radzikowski/53e0b39e9a59a1518990e76c2bff8038 by Maciej Radzikowski
# MIT License https://gist.github.com/m-radzikowski/d925ac457478db14c2146deadd0020cd
# https://betterdev.blog/minimal-safe-bash-script-template/

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v]
Removes a VM from vSphere, keeping nothing by default. Default mode is 'dry-run' true.
Available options:
-h, --help             Print this help and exit
-v, --verbose          Print script debug info
-a, --apply            Apply removal as described in the dry-run, default is false
-k, --keep-data        Delete the VM but keep additional disks that were added, default is false
-n, --name             Name of the VM to delete
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  apply=0
  keep=0
  name=''

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -a | --apply) apply=1 ;;
    -k | --keep-data) keep=1 ;;
    -n | --name)
      name="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  # check required params and arguments
  [[ -z "${name-}" ]] && die "Missing required parameter: name"
  [[ -z "${GOVC_URL-}" ]] && [[ -z "${GOVC_USERNAME-}" ]] && [[ -z "${GOVC_PASSWORD-}" ]] && die "Missing required environment variables: GOVC_URL, GOVC_USERNAME, or GOVC_PASSWORD"

  return 0
}

parse_params "$@"
setup_colors

# script logic here

set +e
if ! govc about.cert;
then
  msg "${RED}No valid certificate for govc found, will attempt to use 'GOVC_TLS_CA_CERTS'.\n${NOFORMAT}"
  if [[ -z ${GOVC_TLS_CA_CERTS-} ]]; then
    message=$(printf "The environment variable 'GOVC_TLS_CA_CERTS' is not set.\n")
    msg "${message}"
    if [[ ! -f "${HOME}/.govmomi/certificates/${GOVC_URL}.pem" ]]; then
      message=$(printf "%sNo matching certificate found at '%s/.govmomi/certificates/%s.pem'.\n%s" "${RED}" "${HOME}" "${GOVC_URL}" "${NOFORMAT}")
      msg "${message}"
      message=$(printf "%sPlease download the certificate using the following command and verify it:\n%s" "${RED}" "${NOFORMAT}")
      msg "${message}"
      message=$(printf "%s\tmkdir -p '%s/.govmomi/certificates/' && govc about.cert -k -show | tee '%s/.govmomi/certificates/%s.pem'\n%s" "${RED}" "${HOME}" "${HOME}" "${GOVC_URL}" "${NOFORMAT}")
      msg "${message}"
      exit 1
    fi
    message=$(printf "Found certificate at '%s/.govmomi/certificates/%s.pem', exporting it as required.\n" "${HOME}" "${GOVC_URL}")
    msg "${message}"
    export GOVC_TLS_CA_CERTS="${HOME}/.govmomi/certificates/${GOVC_URL}.pem"
  fi
fi
set -e

msg "The following VM is planned for removal, please check carefully\n\n"
govc vm.info -e "${name}"

if [[ $keep == 0 ]]; then
  msg "${RED}The following disks will be removed${NOFORMAT}"
else
  msg "${GREEN}The following disks will be kept${NOFORMAT}"
fi
govc device.info -vm "${name}" disk-1000-1 || msg "disk-1000-1 doesn't exist, ignoring"
govc device.info -vm "${name}" disk-1000-2 || msg "disk-1000-2 doesn't exist, ignoring"

if [[ $apply == 1 ]]; then
  msg "\n${RED}Will now remove the VM as described above from vCenter${NOFORMAT}\n\n"

  message=$(printf "Powering VM '%s' off\n" "${name}")
  msg "${message}"
  govc vm.power -off "${name}"

  if [[ $keep == 1 ]]; then
    msg "${GREEN}Detaching disks to keep${NOFORMAT}"
    govc device.remove -vm "${name}" -keep disk-1000-1 || msg "disk-1000-1 doesn't exist, ignoring"
    govc device.remove -vm "${name}" -keep disk-1000-2 || msg "disk-1000-2 doesn't exist, ignoring"
    msg "Showing remaining disks that will be removed\n"
    govc device.info -vm "${name}" disk-*
  fi

  msg "${RED}Removing the VM${NOFORMAT}\n"
  govc vm.destroy "${name}"
else
  msg "${RED}To continue return the command and add the '--apply' parameter${NOFORMAT}\n"
fi
