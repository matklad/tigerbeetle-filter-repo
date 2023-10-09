#!/usr/bin/env bash
set -eu

usage() {
	cat <<-EOF
	usage: ${0##*/} <tag>

	Push the TigerBeetle Docker images to Antithesis' registry.
	EOF
}

cat /tmp/key | base64 --decode | sudo docker login -u _json_key https://us-central1-docker.pkg.dev/ --password-stdin

if [ $# -ne 1 ] || [ "$1" = '-h' ]; then
	usage >&2
	exit 1
fi
tag=$1
url_prefix='us-central1-docker.pkg.dev/molten-verve-216720/tigerbeetle-repository'

push_image() {
	image=$1
	url="$url_prefix/$image:$tag"
	latest_url="$url_prefix/$image:antithesis-latest"

	# XXX sudo
	sudo docker tag "$image:$tag" "$url"
	sudo docker tag "$image:$tag" "$latest_url"
	sudo docker push              "$url"
	sudo docker push              "$latest_url"
}

push_image api
push_image config
push_image replica
push_image workload
