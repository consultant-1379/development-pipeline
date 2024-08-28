#!/bin/bash

# Phase1 images
PHASE1_IMAGES="msfm mspm fm-alarm-processing supervisionclient comecimpolicy eventbasedclient serviceregistry medrouter pmic-router-policy sentinel jmsserver mscm com-ecim-mscm fls lcmservice cmservice uiservice access-control networkexplorer gossiprouter fm-service pki-ra-service pmservice security-service web-push-service sps-service"

PHASE1_ARTIFACTORY_URL="armdocker.rnd.ericsson.se/proj-enm"
ECR_URL="152254703525.dkr.ecr.eu-west-1.amazonaws.com/enm"

for i in $PHASE1_IMAGES
do
   :
    name="eric-enmsg-$i"
    tag=`grep -Ehrv "template|httpd" ./enm-integration |  grep -A 1 "name: eric-enmsg-$i" | grep "tag: "  | head -1 | cut -d ":" -f2 |awk '{$1=$1};1'`
    phase1_image="$name:$tag"
    docker pull $PHASE1_ARTIFACTORY_URL/$phase1_image
    docker tag $PHASE1_ARTIFACTORY_URL/$phase1_image $ECR_URL/$phase1_image
    # docker push $ECR_URL/$phase1_image
    docker rmi $PHASE1_ARTIFACTORY_URL/$phase1_image $ECR_URL/$phase1_image
    echo ""
done
