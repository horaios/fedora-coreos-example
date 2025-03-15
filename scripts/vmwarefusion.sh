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
-b, --bu-file          Path to the bu config to use for provisioning
-d, --download-dir     Path where CoreOS (images and files) should be stored locally
-e, --debug            Enable extra debugging of the VM via Serial Connection logging
-g, --host-signing-key Path to the SSH Host Signing Key
-i, --host-signing-pw  Password for the SSH Host Signing Key
-l, --library          VMWare Fusion Library name to store the VM in
-n, --name             Name of the VM to create
-o, --deploy           Whether to deploy the VM
-p, --prefix           Prefix for the VM names for easier identification in VMWare Fusion, defaults to 'fcos-'
-s, --stream           CoreOS stream, defaults to 'stable'
-t, --tls-certs        Path to the Certificate Authority from where to copy the '$name.cert.pem' and '$name.key.pem' files
EOF
	exit
}

cleanup() {
	trap - SIGINT SIGTERM ERR EXIT

	if [[ -n "${buInc-}" ]]; then
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
	if [[ -n "${ign_config_file-}" ]]; then
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
	library=$(realpath --canonicalize-missing "${HOME}/Virtual Machines.localized")
	name=''
	prefix='fcos-'
	stream='stable'
	tlsCerts=''
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
			library="${2-}"
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
		-?*) die "Unknown option: $1" ;;
		*) break ;;
		esac
		shift
	done

	# check required params and arguments
	[[ -z "${download-}" ]] && die "Missing required parameter: download-dir"
	[[ -z "${bu-}" ]] && die "Missing required parameter: bu-file"
	[[ -z "${name-}" ]] && die "Missing required parameter: name"
	[[ -z "${tlsCerts-}" ]] && die "Missing required parameter: tls-certs"
	return 0
}

parse_params "$@"
setup_colors

# script logic here

download=$(realpath --canonicalize-missing "${download}")
bu=$(realpath --canonicalize-missing "${bu}")
buDir=$(dirname "${bu}")
buInc=$(realpath --canonicalize-missing "${buDir}/includes")
commonConfig=$(realpath --canonicalize-missing "${buDir}/../common")
signing_key=$(realpath --canonicalize-missing "${download}/fedora.gpg")
if [[ -n "${hostSigningKey-}" ]]; then
	hostSigningKey=$(realpath --canonicalize-missing "${hostSigningKey}")
	[[ ! -f "${hostSigningKey-}" ]] && die "Parameter 'host-signing-key' does not point to an existing SSH key file"
fi
tlsCerts=$(realpath --canonicalize-missing "${tlsCerts}")
stream_json=$(realpath --canonicalize-missing "${download}/${stream}.json")
ova_version=''
ign_config=''
ign_config_file=''

[[ ! -f "${bu-}" ]] && die "Parameter 'bu-file' does not point to an existing location"
[[ ! -d "${tlsCerts-}" ]] && die "Parameter 'tls-certs' does not point to an existing location"

msg "Creating SSH Host Keys"
ssh-keygen -q -t ecdsa -N "" -f "${buInc}/ssh/ssh_host_ecdsa_key" -C "${name},${name}.local"
ssh-keygen -q -t ed25519 -N "" -f "${buInc}/ssh/ssh_host_ed25519_key" -C "${name},${name}.local"
ssh-keygen -q -t rsa -b 4096 -N "" -f "${buInc}/ssh/ssh_host_rsa_key" -C "${name},${name}.local"

if [[ -n "${hostSigningKey-}" ]]; then
	msg "Creating signed SSH certificates"
	if [[ -n "${hostSigningPw-}" ]]; then
		ssh-keygen -q -s "${hostSigningKey}" \
			-t rsa-sha2-512 \
			-P "${hostSigningPw}" \
			-I "${name} host key" \
			-n "${name},${name}.local" \
			-V -5m:+3650d \
			-h \
			"${buInc}/ssh/ssh_host_ecdsa_key" \
			"${buInc}/ssh/ssh_host_ed25519_key" \
			"${buInc}/ssh/ssh_host_rsa_key"
	else
		ssh-keygen -q -s "${hostSigningKey}" \
			-t rsa-sha2-512 \
			-I "${name} host key" \
			-n "${name},${name}.local" \
			-V -5m:+3650d \
			-h \
			"${buInc}/ssh/ssh_host_ecdsa_key" \
			"${buInc}/ssh/ssh_host_ed25519_key" \
			"${buInc}/ssh/ssh_host_rsa_key"
	fi
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
echo "${ign_config}" >"${ign_config_file}"

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
		curl --silent --show-error "https://getfedora.org/static/fedora.gpg" --output "${signing_key}"
		gpg --import "${signing_key}"
	fi

	# Download the CoreOS VM description for the particular stream
	message=$(printf "Downloading stream json to '%s'\n" "${stream_json}")
	msg "${message}"
	curl --silent --show-error "https://builds.coreos.fedoraproject.org/streams/${stream}.json" --output "${stream_json}"

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
		curl --silent --show-error "${ova_url_location}" --output "${ova_file_path}"
		curl --silent --show-error "${ova_url_signature}" --output "${ova_file_signature}"
	fi

	message=$(printf "Verifying signature for '%s'\n" "${ova_file_path}")
	msg "${message}"
	gpg --no-default-keyring --keyring "${signing_key}.gpg" --verify "${ova_file_signature}" "${ova_file_path}"

	message=$(printf "Verifying checksum for '%s'\n" "${ova_file_path}")
	msg "${message}"
	message=$(printf "%s %s" "${ova_sha256}" "${ova_file_path}" | sha256sum --check)
	msg "${message}"
	message=$(printf "Latest CoreOS image available at: %s\n" "${ova_file_path}")
	msg "${message}"
	msg "\nIgnition configuration transpiled and CoreOS Template downloaded; will now deploy to VMWare Fusion\n\n"

	message=$(printf "Deploying '%s' to '%s'\n" "${name}" "${library}")
	msg "${message}"
	ovftool \
		--powerOffTarget \
		--overwrite \
		--name="${prefix}${name}" \
		--maxVirtualHardwareVersion=18 \
		--allowExtraConfig \
		--extraConfig:guestinfo.hostname="${name}" \
		--extraConfig:guestinfo.ignition.config.data.encoding="gzip+base64" \
		--extraConfig:guestinfo.ignition.config.data="${ign_config}" \
		"${ova_file_path}" "${library}"

	if [[ $debug == 1 ]]; then
		msg "${YELLOW}To enable VM debugging 'Add Device' and choose 'Serial Port' and select path where to save the log file.${NOFORMAT}"
	fi
	msg "${GREEN}To finalize the VM setup open the VMWare Fusion UI and update the desired settings.${NOFORMAT}"
else
	echo "${ign_config}" | base64 -d | gzip -d | jq >"$(realpath --canonicalize-missing "${buDir}/${name}.ign.json")"
fi
