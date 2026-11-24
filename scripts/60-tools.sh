#!/usr/bin/env bash
# Download checksum-verified oc and openshift-install for OCP_VERSION.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

base="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VERSION}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
curl -fsSLO "$base/sha256sum.txt"
client=openshift-client-linux-amd64-rhel9.tar.gz
for file in "$client" openshift-install-linux.tar.gz; do
  log "downloading $file"
  curl -fSL --progress-bar -O "$base/$file"
  grep -E "  ${file}\$" sha256sum.txt | sha256sum -c -
done

tar -xzf "$client" oc kubectl
tar -xzf openshift-install-linux.tar.gz openshift-install
install -m 0755 oc kubectl openshift-install /usr/local/bin/

/usr/local/bin/oc version --client
/usr/local/bin/openshift-install version
