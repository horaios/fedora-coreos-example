#!/usr/bin/env bash

# script-template.sh https://gist.github.com/m-radzikowski/53e0b39e9a59a1518990e76c2bff8038 by Maciej Radzikowski
# MIT License https://gist.github.com/m-radzikowski/d925ac457478db14c2146deadd0020cd
# https://betterdev.blog/minimal-safe-bash-script-template/

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

# shellcheck disable=SC2034
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v]
This script deploys a FCOS VM to a VMWare Fusion instance using the provided Ignition configuration.
Available options:
-h, --help             Print this help and exit
-v, --verbose          Print script debug info
-d, --download-dir     Path where CoreOS (images and files) should be stored locally
-i, --ign-file         Path to Ignition Config
-m, --vm-dir           Path to the VM storage
-n, --name             Name of the VM to create
-s, --stream           CoreOS stream, defaults to 'stable'
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
    # shellcheck disable=SC2034
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
  download=''
  ign=''
  name=''
  stream='stable'
  vm=''

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -d | --download-dir)
      download="${2-}"
      shift
      ;;
    -i | --ign-file)
      ign="${2-}"
      shift
      ;;
    -m | --vm-dir)
      vm="${2-}"
      shift
      ;;
    -n | --name)
      name="${2-}"
      shift
      ;;
    -s | --stream)
      stream="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  # check required params and arguments
  [[ -z "${download-}" ]] && die "Missing required parameter: download-dir"
  [[ -z "${ign-}" ]] && die "Missing required parameter: ign-file"
  [[ -z "${vm-}" ]] && die "Missing required parameter: vm-dir"
  [[ -z "${name-}" ]] && die "Missing required parameter: name"

  return 0
}

parse_params "$@"
setup_colors

# script logic here

download=$(realpath --canonicalize-missing "${download}")
ign=$(realpath --canonicalize-missing "${ign}")
vm=$(realpath --canonicalize-missing "${vm}")
signing_key=$(realpath --canonicalize-missing "${download}/fedora.asc")
stream_json=$(realpath --canonicalize-missing "${download}/${stream}.json")
ova_version=''

[[ ! -f "${ign-}" ]] && die "Parameter 'ign-file' does not point to an existing file"

ign_config=$(jq -c . <"${ign}" | gzip | base64 -w0)

# Init download directory if it doesn't exist
if [[ ! -d "${download}" ]]; then
  message=$(printf "Creating CoreOS Downloads Folder at '%s'\n" "${download}")
  msg "${message}"
  mkdir -p "${download}"
fi

# Download the signing key for verification purposes
if [[ ! -f "${signing_key}" ]]; then
  message=$(printf "Downloading the Fedora signing key to '%s'" "${signing_key}")
  msg "${message}"
  wget -q -nv "https://getfedora.org/static/fedora.gpg" -O "${signing_key}"
fi

# Make the signing key useful for verification purposes
if [[ ! -f "${signing_key}.gpg" ]]; then
  gpg --dearmor "${signing_key}"
fi

# Download the CoreOS VM description for the particular stream
message=$(printf "Downloading stream json to '%s'\n" "${stream_json}")
msg "${message}"
wget -q -nv "https://builds.coreos.fedoraproject.org/streams/${stream}.json" -O "${stream_json}"

ova_version=$(jq --raw-output '.architectures.x86_64.artifacts.vmware.release' "${stream_json}")
ova_url_location=$(jq --raw-output '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location' "${stream_json}")
ova_url_signature=$(jq --raw-output '.architectures.x86_64.artifacts.vmware.formats.ova.disk.signature' "${stream_json}")
ova_sha256=$(jq --raw-output '.architectures.x86_64.artifacts.vmware.formats.ova.disk.sha256' "${stream_json}")
ova_file_path=$(realpath --canonicalize-missing "${download}/coreos-${stream}-${ova_version}.ova")
ova_file_signature=$(realpath --canonicalize-missing "${download}/coreos-${stream}-${ova_version}.sig")
message=$(printf "Latest CoreOS Version for stream '%s' is '%s'\n" "${stream}" "${ova_version}")
msg "${message}"

# Download the latest available ova file for a particular stream
if [[ ! -f "${ova_file_path}" ]]; then
  message=$(printf "Downloading CoreOS Version for stream '%s' with version '%s'\n" "${stream}" "${ova_version}")
  msg "${message}"
  wget -q -nv "${ova_url_location}" -O "${ova_file_path}"
  wget -q -nv "${ova_url_signature}" -O "${ova_file_signature}"
fi

message=$(printf "Verifying signature for '%s'\n" "${ova_file_path}")
msg "${message}"
gpg --no-default-keyring --keyring "${signing_key}.gpg" --verify "${ova_file_signature}" "${ova_file_path}"

message=$(printf "Verifying checksum for '%s'\n" "${ova_file_path}")
msg "${message}"
message=$(printf "%s %s" "${ova_sha256}" "${ova_file_path}" | sha256sum --check)
msg "${message}"

message=$(printf "Deploying '%s' to '%s'\n" "${name}" "${vm}")
msg "${message}"
ovftool \
  --powerOffTarget \
  --overwrite \
  --name="${name}" \
  --maxVirtualHardwareVersion=18 \
  --allowExtraConfig \
  --extraConfig:guestinfo.hostname="${name}" \
  --extraConfig:guestinfo.ignition.config.data.encoding="gzip+base64" \
  --extraConfig:guestinfo.ignition.config.data="${ign_config}" \
  "${ova_file_path}" "${vm}"
