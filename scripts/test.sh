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
This script uses 'butane' to convert the given configuration file, verifying that this works as expected.
Available options:
-h, --help             Print this help and exit
-v, --verbose          Print script debug info
-b, --bu-file          Path to the bu config to use for provisioning
-c, --cleanup          Cleanup the transpiled configs in the end
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
	if [[ -d "${tmpDir-}" ]]; then
		message=$(printf "Removing temporary directory '%s'\n" "${tmpDir}")
		[[ $verbose == 1 ]] && msg "${message}"
		rm -rf "${tmpDir}"
	fi
	if [[ -n "${ign_config_file-}" ]] && [[ $cleanup == 1 ]]; then
		message=$(printf "Removing Ignition file from '%s'\n" "${ign_config_file}")
		[[ $verbose == 1 ]] && msg "${message}"
		rm -f "${ign_config_file}"
	fi
	if [[ -n "${ign_config_file_plain-}" ]] && [[ $cleanup == 1 ]]; then
		message=$(printf "Removing Ignition file from '%s'\n" "${ign_config_file_plain}")
		[[ $verbose == 1 ]] && msg "${message}"
		rm -f "${ign_config_file_plain}"
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
	cleanup=0
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
		-c | --cleanup)
			cleanup=1
			;;
		-?*) die "Unknown option: $1" ;;
		*) break ;;
		esac
		shift
	done

	# check required params and arguments
	[[ -z "${bu-}" ]] && die "Missing required parameter: bu-file"

	return 0
}

parse_params "$@"
setup_colors

# script logic here
name="$(date +%s)_test"
bu=$(realpath --canonicalize-missing "${bu}")
buDir=$(dirname "${bu}")
buInc=$(realpath --canonicalize-missing "${buDir}/includes")
commonConfig=$(realpath --canonicalize-missing "${buDir}/../common")
tmpDir=$(realpath --canonicalize-missing "${buDir}/../tmp")
hostSigningKey=$(realpath --canonicalize-missing "/${tmpDir}/${name}_key")
tlsCerts=$(realpath --canonicalize-missing "/${tmpDir}/tls")

[[ ! -f "${bu-}" ]] && die "Parameter 'bu-file' does not point to an existing location"

msg "Creating temporary directory and files for e.g. SSH keys"
mkdir -p "${tlsCerts}/certs" "${tlsCerts}/private"
touch "${tlsCerts}/certs/ca-chain.cert.pem"
touch "${tlsCerts}/certs/ca.cert.pem"
touch "${tlsCerts}/certs/ia.cert.pem"
touch "${tlsCerts}/certs/${name}.cert.pem"
touch "${tlsCerts}/certs/${name}.cert-chain.pem"
touch "${tlsCerts}/private/${name}.key.pem"

msg "Creating temporary SSH Keys"
ssh-keygen -t rsa -b 4096 -N "" -f "${hostSigningKey}" -C "${name} Host Signing Key"
ssh-keygen -t ed25519 -N "" -f "${tmpDir}/user_ed25519" -C "User Key"
ssh-keygen -t rsa -b 4096 -N "" -f "${tmpDir}/user_rsa" -C "User Key"
cp -f "${tmpDir}/user_ed25519.pub" "${commonConfig}/user/id_ed25519.pub"
cp -f "${tmpDir}/user_rsa.pub" "${commonConfig}/user/id_rsa.pub"

msg "Creating SSH Host Keys"
ssh-keygen -t ecdsa -N "" -f "${buInc}/ssh/ssh_host_ecdsa_key" -C "${name},${name}.local"
ssh-keygen -t ed25519 -N "" -f "${buInc}/ssh/ssh_host_ed25519_key" -C "${name},${name}.local"
ssh-keygen -t rsa -b 4096 -N "" -f "${buInc}/ssh/ssh_host_rsa_key" -C "${name},${name}.local"

if [[ -n "${hostSigningKey-}" ]]; then
	msg "Creating signed SSH certificates"
	ssh-keygen -s "${hostSigningKey}" \
		-t rsa-sha2-512 \
		-P "" \
		-I "${name} host key" \
		-n "${name},${name}.local" \
		-V -5m:+3650d \
		-h \
		"${buInc}/ssh/ssh_host_ecdsa_key" \
		"${buInc}/ssh/ssh_host_ed25519_key" \
		"${buInc}/ssh/ssh_host_rsa_key"
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
ign_config_file_plain=$(realpath --canonicalize-missing "${buDir}/${name}.ign.json")
echo "${ign_config}" >"${ign_config_file}"
echo "${ign_config}" | base64 -d | gzip -d | jq >"${ign_config_file_plain}"
