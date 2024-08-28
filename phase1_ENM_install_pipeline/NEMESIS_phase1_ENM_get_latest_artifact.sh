#!/bin/bash

ARTIFACTORY_URL=https://arm.epk.ericsson.se/artifactory/proj-enm-helm/enm-integration/

echo '### GET LATEST TARBALL FROM ARTIFACTORY ###'
LATEST_TAR=`curl -s $ARTIFACTORY_URL | grep '.tgz' | grep -Ev "sha|md5" | awk -F " " '{print $2,$3,$4}' | sort  -k2,3 | tail -n 1 | cut -d '"' -f2`
echo "### GOT $LATEST_TAR ###"

echo "### DOWNLOADING $LATEST_TAR ###"
`wget $ARTIFACTORY_URL$LATEST_TAR`
