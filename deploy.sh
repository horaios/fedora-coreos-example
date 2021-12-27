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
This script deploys a FCOS VM to a vSphere instance using the provided Ignition configuration.
Available options:
-h, --help             Print this help and exit
-v, --verbose          Print script debug info
-b, --bu-file          Path to the bu config to use for provisioning
-d, --download-dir     Path where CoreOS (images and files) should be stored locally
-e, --debug            Enable extra debugging of the VM via Serial Connection logging
-g, --host-signing-key Path to the SSH Host Signing Key
-i, --host-signing-pw  Password for the SSH Host Signing Key
-l, --library          vSphere Library name to store template in, defaults to 'fcos'
-n, --name             Name of the VM to create
-o, --deploy           Whether to deploy the VM (requires GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD to be set)
-p, --prefix           Prefix for the VM names for easier identification in vSphere, defaults to 'fcos'
-s, --stream           CoreOS stream, defaults to 'stable'
-t, --tls-certs        Path to the Certificate Authority from where to copy the '$name.cert.pem' and '$name.key.pem' files
-u, --user-signing-key Path to the SSH User Signing Key
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT

  if [[ -n "${buInc}" ]]; then
    if [[ -n "${commonConfig}" ]]; then
      for tmp in "${commonConfig}"/*; do
        tmpName=$(realpath --canonicalize-missing "${buInc}/$(basename "${tmp}")")
        message=$(printf "Removing temporary common config from '%s'\n" "${tmpName}")
        [[ $verbose == 1 ]] && msg "${message}"
        rm -rf "${tmpName}"
      done
    fi
    for tmp in "${buInc}/ssh/ssh_host_"*; do
      tmpName=$(realpath --canonicalize-missing "${buInc}/ssh/$(basename "${tmp}")")
      message=$(printf "Removing temporary SSH host key from '%s'\n" "${tmpName}")
      [[ $verbose == 1 ]] && msg "${message}"
      rm -f "${tmpName}"
    done
    if [[ -n "${userSigningKey-}" ]] && [[ -f "${buInc}/ssh/${userSigningKey}" ]]; then
      message=$(printf "Removing temporary SSH user signing certificate from '%s'\n" "${buInc}/ssh/${userSigningKey}")
      [[ $verbose == 1 ]] && msg "${message}"
      rm -f "${buInc}/ssh/${userSigningKey}"
    fi

    if [[ -n "${name}" ]]; then
      for tmp in "${buInc}/certs/app"*; do
          tmpName=$(realpath --canonicalize-missing "${buInc}/certs/$(basename "${tmp}")")
          message=$(printf "Removing temporary TLS certificate from '%s'\n" "${tmpName}")
          [[ $verbose == 1 ]] && msg "${message}"
          rm -f "${tmpName}"
      done
      staticCerts=("${buInc}/certs/ca.cert.pem" "${buInc}/certs/ca-chain.cert.pem" "${buInc}/certs/ia.cert.pem")
      for tmp in "${staticCerts[@]}"; do
        if [[ -f "${tmp}" ]]; then
          tmpName=$(realpath --canonicalize-missing "${buInc}/certs/$(basename "${tmp}")")
          message=$(printf "Removing temporary TLS certificate from '%s'\n" "${tmpName}")
          [[ $verbose == 1 ]] && msg "${message}"
          rm -f "${tmpName}"
        fi
      done
    fi
  fi
  if [[ -n "${ign_config_file}" ]]; then
    message=$(printf "Removing Ignition file from '%s'\n" "${ign_config_file}")
    [[ $verbose == 1 ]] && msg "${message}"
    rm -f "${ign_config_file}"
  fi
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
  bu=''
  deploy=0
  download=''
  debug=0
  hostSigningKey=''
  hostSigningPw="${SIMPLE_CA_SSH_PASSWORD-}"
  library='fcos'
  name=''
  prefix='fcos'
  stream='stable'
  tlsCerts=''
  userSigningKey=''
  verbose=0

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose)
      set -x
      verbose=1
      ;;
    --no-color) NO_COLOR=1 ;;
    -b | --bu-file)
      bu="${2-}"
      shift
      ;;
    -d | --download-dir)
      download="${2-}"
      shift
      ;;
    -e | --debug)
      debug=1
      ;;
    -g | --host-signing-key)
      hostSigningKey="${2-}"
      shift
      ;;
    -i | --host-signing-pw)
      hostSigningPw="${2-}"
      shift
      ;;
    -l | --library)
      name="${2-}"
      shift
      ;;
    -n | --name)
      name="${2-}"
      shift
      ;;
    -o | --deploy) deploy=1 ;;
    -s | --stream)
      stream="${2-}"
      shift
      ;;
    -t | --tls-certs)
      tlsCerts="${2-}"
      shift
      ;;
    -u | --user-signing-key)
      userSigningKey="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  # check required params and arguments
  [[ -z "${download-}" ]] && die "Missing required parameter: download-dir"
  [[ -z "${name-}" ]] && die "Missing required parameter: name"
  [[ -z "${bu-}" ]] && die "Missing required parameter: bu-file"
  [[ $deploy == 1 ]] && [[ -z "${GOVC_URL-}" ]] && [[ -z "${GOVC_USERNAME-}" ]] && [[ -z "${GOVC_PASSWORD-}" ]] && die "Missing required environment variables: GOVC_URL, GOVC_USERNAME, or GOVC_PASSWORD"
  [[ -z "${tlsCerts-}" ]] && die "Missing required parameter: tls-certs"

  return 0
}

parse_params "$@"
setup_colors

# script logic here

download=$(realpath --canonicalize-missing "${download}")
bu=$(realpath --canonicalize-missing "${bu}")
buDir=$(dirname "${bu}")
vmConfig=$(realpath --canonicalize-missing "${buDir}/resources.json")
buInc=$(realpath --canonicalize-missing "${buDir}/includes")
commonConfig=$(realpath --canonicalize-missing "${buDir}/../common")
signing_key=$(realpath --canonicalize-missing "${download}/fedora.asc")
if [[ -n "${hostSigningKey-}" ]]; then
  hostSigningKey=$(realpath --canonicalize-missing "${hostSigningKey}")
  [[ ! -f "${hostSigningKey-}" ]] && die "Parameter 'host-signing-key' does not point to an existing SSH key file"
fi
if [[ -n "${userSigningKey-}" ]]; then
  userSigningKey=$(realpath --canonicalize-missing "${userSigningKey}")
  [[ ! -f "${userSigningKey-}" ]] && die "Parameter 'user-signing-key' does not point to an existing SSH key file"
fi
tlsCerts=$(realpath --canonicalize-missing "${tlsCerts}")
stream_json=$(realpath --canonicalize-missing "${download}/${stream}.json")
ova_version=''
ign_config=''
ign_config_file=''

[[ ! -d "${tlsCerts-}" ]] && die "Parameter 'tls-certs' does not point to an existing location"

msg "Creating SSH Host Keys"
ssh-keygen -t ecdsa -N "" -f "${buInc}/ssh/ssh_host_ecdsa_key" -C "${name},${name}.local"
ssh-keygen -t ed25519 -N "" -f "${buInc}/ssh/ssh_host_ed25519_key" -C "${name},${name}.local"
ssh-keygen -t rsa -N "" -f "${buInc}/ssh/ssh_host_rsa_key" -C "${name},${name}.local"

if [[ -n "${hostSigningKey-}" ]]; then
  msg "Creating signed SSH certificates"
  ssh-keygen -s "${hostSigningKey}" \
    -P "${hostSigningPw}" \
    -I "${name} host key" \
    -n "${name},${name}.local" \
    -V -5m:+3650d \
    -h \
    "${buInc}/ssh/ssh_host_ecdsa_key" \
    "${buInc}/ssh/ssh_host_ed25519_key" \
    "${buInc}/ssh/ssh_host_rsa_key"
fi

if [[ -n "${userSigningKey-}" ]]; then
  message=$(printf "Temporarily copying SSH user signing certificate from '%s' to '%s'\n" "${userSigningKey}" "${buInc}/ssh")
  msg "${message}"
  cp -f "${userSigningKey}" "${buInc}/ssh"
fi

message=$(printf "Temporarily copying common config from '%s' to '%s'\n" "${commonConfig}" "${buInc}")
msg "${message}"
cp -fr "${commonConfig}/." "${buInc}"

message=$(printf "Temporarily copying certificates from '%s' to '%s'\n" "${tlsCerts}" "${buInc}")
msg "${message}"
cp -f "${tlsCerts}/certs/ca-chain.cert.pem" "${buInc}/certs"
cp -f "${tlsCerts}/certs/ca.cert.pem" "${buInc}/certs"
cp -f "${tlsCerts}/certs/ia.cert.pem" "${buInc}/certs"
cp -f "${tlsCerts}/certs/${name}.cert.pem" "${buInc}/certs/app.cert.pem"
cp -f "${tlsCerts}/certs/${name}.cert-chain.pem" "${buInc}/certs/app.cert-chain.pem"
cp -f "${tlsCerts}/private/${name}.key.pem" "${buInc}/certs/app.key.pem"

message=$(printf "Converting bu file '%s' to ign config\n" "${bu}")
msg "${message}"
ign_config=$(butane --strict --files-dir="${buInc}" "${bu}" | gzip | base64 -w0)
ign_config_file=$(realpath --canonicalize-missing "${buDir}/${name}.ign.gzip.b64")
echo "${ign_config}" > "${ign_config_file}"

if [[ $deploy == 1 ]]; then
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
    curl -sS "https://getfedora.org/static/fedora.gpg" -o "${signing_key}"
  fi

  # Make the signing key useful for verification purposes
  if [[ ! -f "${signing_key}.gpg" ]]; then
    gpg --dearmor "${signing_key}"
  fi

  # Download the CoreOS VM description for the particular stream
  message=$(printf "Downloading stream json to '%s'\n" "${stream_json}")
  msg "${message}"
  curl -sS "https://builds.coreos.fedoraproject.org/streams/${stream}.json" -o "${stream_json}"

  ova_version=$(jq --raw-output '.architectures.x86_64.artifacts.vmware.release' "${stream_json}")
  ova_url_location=$(jq --raw-output '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location' "${stream_json}")
  ova_url_signature=$(jq --raw-output '.architectures.x86_64.artifacts.vmware.formats.ova.disk.signature' "${stream_json}")
  ova_sha256=$(jq --raw-output '.architectures.x86_64.artifacts.vmware.formats.ova.disk.sha256' "${stream_json}")
  ova_file_path=$(realpath --canonicalize-missing "${download}/coreos-${stream}-${ova_version}.ova")
  ova_file_signature=$(realpath --canonicalize-missing "${download}/coreos-${stream}-${ova_version}.sig")
  ova_name="coreos-${stream}-${ova_version}"
  message=$(printf "Latest CoreOS Version for stream '%s' is '%s'\n" "${stream}" "${ova_version}")
  msg "${message}"

  # Download the latest available ova file for a particular stream
  if [[ ! -f "${ova_file_path}" ]]; then
    message=$(printf "Downloading CoreOS Version for stream '%s' with version '%s'\n" "${stream}" "${ova_version}")
    msg "${message}"
    curl -sS "${ova_url_location}" -o "${ova_file_path}"
    curl -sS "${ova_url_signature}" -o "${ova_file_signature}"
  fi

  message=$(printf "Verifying signature for '%s'\n" "${ova_file_path}")
  msg "${message}"
  gpg --no-default-keyring --keyring "${signing_key}.gpg" --verify "${ova_file_signature}" "${ova_file_path}"

  message=$(printf "Verifying checksum for '%s'\n" "${ova_file_path}")
  msg "${message}"
  message=$(printf "%s %s" "${ova_sha256}" "${ova_file_path}" | sha256sum --check)
  msg "${message}"

  msg "\nIgnition configuration transpiled and CoreOS Template downloaded; will now deploy to vCenter\n\n"

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

  if [[ $(govc library.ls | grep -c "${library}") -eq 0 ]]; then
    message=$(printf "The library '%s' does not exist in vCenter, creating it now\n" "${library}")
    msg "${message}"
    govc library.create "${library}"
  fi

  if [[ $(govc library.ls "/${library}/*" | grep -c "${ova_name}") -eq 0 ]]; then
    message=$(printf "Uploading ova '%s' as '%s' to vCenter library '%s'\n" "${ova_file_path}" "${ova_name}" "${library}")
    msg "${message}"
    govc library.import -n "${ova_name}" "${library}" "${ova_file_path}"
  fi

  message=$(printf "Deploying ova '%s' as '%s'\n" "${ova_name}" "${prefix}-${name}")
  msg "${message}"
  govc library.deploy "${library}/${ova_name}" "${prefix}-${name}"
  govc vm.change -vm "${prefix}-${name}" -e "guestinfo.ignition.config.data.encoding=gzip+base64"
  govc vm.change -vm "${prefix}-${name}" -f "guestinfo.ignition.config.data=${ign_config_file}"

  if [[ -f "${vmConfig}" ]]; then
    vmResources=$(cat "${vmConfig}")
    msg "Resource config found; updating VM"
    msg "Updating CPU Cores"
    govc vm.change -vm "${prefix}-${name}" -c="$(echo "${vmResources}" | jq '.cpu_cores')"
    msg "Updating RAM"
    govc vm.change -vm "${prefix}-${name}" -m="$(echo "${vmResources}" | jq '.ram')"
    msg "Updating resizing root disk"
    govc vm.disk.change -vm "${prefix}-${name}" \
      -disk.filePath="[datastore] ${prefix}-${name}/${prefix}-${name}.vmdk" \
      -size="$(echo "${vmResources}" | jq -r '.disks.root')"

    if govc datastore.ls "docker/${prefix}-${name}-docker.vmdk"; then
      msg "Docker disk exists, continuing"
    else
      govc datastore.mkdir -p docker
      govc datastore.disk.create -size "$(echo "${vmResources}" | jq -r '.disks.docker')" \
        "docker/${prefix}-${name}-docker.vmdk"
    fi
    if govc datastore.ls "data/${prefix}-${name}-data.vmdk"; then
      msg "Data disk exists, continuing"
    else
      govc datastore.mkdir -p data
      govc datastore.disk.create -size "$(echo "${vmResources}" | jq -r '.disks.data')" \
        "data/${prefix}-${name}-data.vmdk"
    fi

    # See https://github.com/vmware/govmomi/blob/master/govc/USAGE.md#vmdiskattach
    msg "Attaching docker disk"
    govc vm.disk.attach -vm "${prefix}-${name}" -disk="docker/${prefix}-${name}-docker.vmdk" \
      -link=false -mode=independent_persistent -sharing=sharingNone
    msg "Attaching app disk"
    govc vm.disk.attach -vm "${prefix}-${name}" -disk="data/${prefix}-${name}-data.vmdk" \
      -link=false -mode=independent_persistent -sharing=sharingNone
  fi

  govc vm.info -e "${prefix}-${name}"

  if [[ $debug == 1 ]]; then
    # In case of problems: the two lines below attach serial connection and create a debug log for the start up (including provisioning)
    message=$(printf "Enabling VM debugging, check log file in vSphere Datastore at '%s'" "${prefix}-${name}/${prefix}-${name}.log")
    msg "${message}"
    govc device.serial.add -vm "${prefix}-${name}"
    govc device.serial.connect -vm "${prefix}-${name}" "[datastore] ${prefix}-${name}/${prefix}-${name}.log"
  fi
  message=$(printf "Powering VM '%s' on\n" "${prefix}-${name}")
  msg "${message}"
  govc vm.power -on "${prefix}-${name}"

  msg "${YELLOW}For security reasons the 'guestinfo.ignition.config.data' parameter should be removed once startup completes:${NOFORMAT}"
  message=$(printf "govc vm.change -vm '%s-%s' -e 'guestinfo.ignition.config.data='" "${prefix}" "${name}")
  msg "${message}"
else
  echo "${ign_config}" | base64 -d | gzip -d | jq >"$(realpath --canonicalize-missing "${buDir}/${name}.ign.json")"
fi
