#!/bin/bash

OSS_PHASE0_PATH="ENM-containerisation-POC/phase-0"

# ======================================================
# TODO remove these lines once local testing is done
ECR_LINK="152254703525.dkr.ecr.eu-west-1.amazonaws.com"
BUILD_ID="jenkins_build_id"
CLOUD_FRONT_DOMAIN="d13h60r5ikn7wu.cloudfront.net"
GERRIT_USER="echiamm" # change to your signum
git clone ssh://$GERRIT_USER@gerrit.ericsson.se:29418/OSS/com.ericsson.oss.containerisation/ENM-containerisation-POC
# ======================================================

echo "Step 1. prepare the list of phase0 dockerfiles to be processed by the script."
PHASE0_NEO4J_BUILD_EXCLUDED_REPOS="eric-enm-neo4j-extension-plugin"

PHASE0_BUILD_EXCLUDED_REPOS='todo|eric-nfs-client-provisioner'

echo "Add neo4j repos to the phase 0 build excluded repos"
for phase0_neo4j_repo in ${PHASE0_NEO4J_BUILD_EXCLUDED_REPOS}; do
    PHASE0_BUILD_EXCLUDED_REPOS="${PHASE0_BUILD_EXCLUDED_REPOS}|${phase0_neo4j_repo}"
done

echo ""

PHASE1_BUILD_EXCLUDED_REPOS="msfm mspm fm-alarm-processing supervisionclient comecimpolicy eventbasedclient \
serviceregistry medrouter pmic-router-policy sentinel jmsserver mscm com-ecim-mscm fls \
lcmservice cmservice uiservice access-control networkexplorer gossiprouter fm-service pki-ra-service \
pmservice security-service web-push-service sps-service"

echo "Add phase1 repos to the list of phase 0 build excluded repos"
num_phase1_build_excluded_repos=0
for build_excluded_phase1_repo in ${PHASE1_BUILD_EXCLUDED_REPOS}; do
    PHASE0_BUILD_EXCLUDED_REPOS="${PHASE0_BUILD_EXCLUDED_REPOS}|${build_excluded_phase1_repo}"
    num_phase1_build_excluded_repos=$((num_phase1_build_excluded_repos+1))
done
echo "Number of phase1 images that will be excluded from phase0 build stage: $num_phase1_build_excluded_repos"

echo ""

PHASE0_REPOS_TO_BUILD=$(ls ${OSS_PHASE0_PATH} | grep eric | grep -E -v ${PHASE0_BUILD_EXCLUDED_REPOS})

echo ""

echo "Step 2. create ECR repos on AWS for PROCESSED_DOCKER_IMAGES"

ECR_REPOS=$(aws ecr describe-repositories | grep repositoryName | awk '{print $2}' | tr -d '",')

echo "Prepare the phase1 build excluded repos names for the ECR repo create stage"
# trasform space separated phase1 repo names to a new line separated values, so that the values are ready to use inside the ECR repo create loop

PHASE1_REPOS_FOR_ECR=""
for phase1_build_excluded_repo in $PHASE1_BUILD_EXCLUDED_REPOS; do

    # get the exact phase1 repo name, given a partial value provided in the PHASE1_BUILD_EXCLUDED_REPOS list
    phase1_build_excluded_repo_name=`basename $(find enm-integration -type d | grep $phase1_build_excluded_repo | head -1)`

    # at the beginning of the loop, PHASE1_REPOS_FOR_ECR variable is still empty, so to avoid having an empty line followed by values
    if [ -z "$PHASE1_REPOS_FOR_ECR" ]; then
        PHASE1_REPOS_FOR_ECR="${phase1_build_excluded_repo_name}"
    else
        PHASE1_REPOS_FOR_ECR="${PHASE1_REPOS_FOR_ECR}"$'\n'"${phase1_build_excluded_repo_name}"
    fi

done

# any repo (whether phase 0 or 1) that needs to be created on ECR
REPOS_FOR_ECR="${PHASE0_REPOS_TO_BUILD} ${PHASE1_REPOS_FOR_ECR}"

for repo_for_ecr in ${REPOS_FOR_ECR}; do
    ecr_repo_name="enm/$repo_for_ecr"

    grep -q $ecr_repo_name <<< "$ECR_REPOS"

    if [[ $? -eq 0 ]]; then
        echo "repository ${ecr_repo_name} already exists on ECR."
    else
        echo "$ecr_repo_name does not exist on ECR, creating it."
        aws ecr create-repository --repository-name ${ecr_repo_name} || echo "Failed to create $ecr_repo_name on ECR." && exit 1

        # TODO json_policy might be turned into a file, created outside the loop and used.
        json_policy="{\"rules\":[{\"action\":{\"type\":\"expire\"},\"selection\":{
        \"countType\":\"imageCountMoreThan\",\"countNumber\":5,\"tagStatus\":\"any\"},
        \"description\":\"Keep the latest + 4 images on repository.\",\"rulePriority\":1}]}"

        aws ecr put-lifecycle-policy --repository-name "${ecr_repo_name}" \
        --lifecycle-policy-text "$json_policy" || echo "Failed to assign lifecycle policy on ECR for $ecr_repo_name" && exit 1

        echo "Successfully created $ecr_repo_name on ECR."
    fi
done

echo ""

echo "Step 3. modify cifwk_enm and rhel yum repos to point to cloud front domain."

all_rhel6base_repos="$OSS_PHASE0_PATH/eric-enm-rhel6base/image_content/yum.repos.d/*.repo"
cifwk_enm_repo_path="$OSS_PHASE0_PATH/eric-enm-rhel6base/image_content/yum.repos.d/cifwk_enm.repo"
rhel_repo_path="$OSS_PHASE0_PATH/eric-enm-rhel6base/image_content/yum.repos.d/rhel.repo"

echo "remove /latest from all rhel6base repos"
sed -i s"/\/latest//g" $all_rhel6base_repos

echo "change staticRepos link for cifwk_enm.repo to cloud front domain."
sed -i s"/cifwk-oss.lmera.ericsson.se\/static\/staticRepos/${CLOUD_FRONT_DOMAIN}/g" $cifwk_enm_repo_path

echo "change staticRepos link for rhel.repo to cloud front domain."
sed -i s"/cifwk-oss.lmera.ericsson.se\/static\/staticRepos\/RHEL6.10_OS_Patch_Set/${CLOUD_FRONT_DOMAIN}\/RHEL\/RHEL6-2.1.2/g" $rhel_repo_path

for repo_file in $(ls $all_rhel6base_repos -1);
    do echo ""
    echo "$repo_file contents:"
    cat $repo_file
    echo ""
done

echo ""

echo "Step 4. inject manually downloaded dependencies to rhel base Dockerfile "
# Modify Dockerfile to refer to a local package instead of remote repo as follows:
# 1. Download desired package to image_content folder
# 2. Modify Dockerfile commands to copy the package to /var/tmp inside the docker image
# 3. Modify package installation command to use the rpm from /var/tmp
# Note: Packages should be mapped in MANUAL_DEP_MAP to get the URL

ES_URL="https://arm101-eiffel004.lmera.ericsson.se:8443/nexus/content/repositories/litp_releases/com/ericsson/nms/litp/3pps/EXTRlitprsyslogelasticsearch_CXP9032173"
declare -A MANUAL_DEP_MAP=( ["EXTRlitprsyslogelasticsearch_CXP9032173"]="${ES_URL}" )

ES_dependency="EXTRlitprsyslogelasticsearch_CXP9032173"
ES_dependency_version="1.1.5"
ES_rpm_file="${ES_dependency}-${ES_dependency_version}.rpm"

pkg_url="${MANUAL_DEP_MAP[${ES_dependency}]}"

enm_rhel6base_download_dest="$OSS_PHASE0_PATH/eric-enm-rhel6base/image_content"
echo "Download elastic search dependency to $enm_rhel6base_download_dest"
wget -P ${enm_rhel6base_download_dest} "${pkg_url}/${ES_dependency_version}/${ES_rpm_file}" || exit $?

echo ""

enm_rhel6base_dockerfile="$OSS_PHASE0_PATH/eric-enm-rhel6base/Dockerfile"

echo "modify the install command to install the dependency using the rpm under /var/tmp/"
sed -i s"/${ES_dependency}/\/var\/tmp\/${ES_rpm_file}/g" $enm_rhel6base_dockerfile

echo "add a copy command to copy the downloaded dependency from image_content to /var/tmp/"
sed -i -e "/MAINTAINER dudderlads/a \\\nCOPY image_content/${ES_rpm_file} /var/tmp/" $enm_rhel6base_dockerfile

echo ""

echo "Step 5. change armdocker link to ECR for phase0 docker files"

for phase0_repo in $PHASE0_REPOS_TO_BUILD; do
    echo "Trying to change armdocker link to ECR for $phase0_repo"
    sed -i s"/armdocker.rnd.ericsson.se\/proj_oss_releases/${ECR_LINK}/g" "$OSS_PHASE0_PATH/$phase0_repo/Dockerfile"
    echo ""
done

echo "Number of phase0 docker files that might have armdocker link changed to ECR: $(echo "$PHASE0_REPOS_TO_BUILD" | wc -l)"

echo ""

# TODO Ask Sajeesh to request this change to be done if possible
echo "Modify neo4j's Dockerfile to copy postgres_key.pem from image_content dir"
sed -i s"/COPY postgres_key.pem/COPY image_content\/postgres_key.pem/g" "$OSS_PHASE0_PATH/eric-enmsg-neo4j/Dockerfile"

echo ""

echo  "Step 6. modify opendj_config.sh"
OPENDJ_CONFIG_SCRIPT="$OSS_PHASE0_PATH/eric-enmsg-opendj/image_content/opendj_config.sh"
REMOVE_CMD="rm -rf /etc/security/limits.d/opendj_custom.conf"
sed -i -e "/#aws fixes/a $REMOVE_CMD" $OPENDJ_CONFIG_SCRIPT

echo ""

echo "Step 7. build selected phase0 images and push to ECR"
for phase0_repo in ${PHASE0_REPOS_TO_BUILD}; do

    build_tagged_phase0_img="$ECR_LINK/enm/$phase0_repo:$BUILD_ID"
    echo "Build $phase0_repo image with $build_tagged_phase0_img tag"
    docker build -t $build_tagged_phase0_img "$OSS_PHASE0_PATH/$phase0_repo/" || exit $?
    echo ""

    echo "Tag the built $phase0_repo image as latest"
    latest_tagged_phase0_img="$ECR_LINK/enm/$phase0_repo:latest"
    docker tag $build_tagged_phase0_img $latest_tagged_phase0_img
    echo ""

    echo "Pushing $build_tagged_phase0_img and $latest_tagged_phase0_img to ECR:"
    docker push $build_tagged_phase0_img || exit $?
    docker push $latest_tagged_phase0_img || exit $?
    echo ""

    echo "Cleanup $phase0_repo images"
    docker rmi $build_tagged_phase0_img $latest_tagged_phase0_img
    echo "============================================================================================================================================="
    echo ""
done

# The previous loop leaves an image, but better not to remove it for cashing purposes
# docker rmi registry.access.redhat.com/rhel6/rhel:6.10

echo ""

echo "Step 8. pull, tag and push phase0 neo4j-server-extension image to ECR"
docker pull armdocker.rnd.ericsson.se/proj_oss_releases/enm/eric-enm-neo4j-server-extension
echo ""

docker tag armdocker.rnd.ericsson.se/proj_oss_releases/enm/eric-enm-neo4j-server-extension:latest \
152254703525.dkr.ecr.eu-west-1.amazonaws.com/enm/eric-enm-neo4j-server-extension:latest
echo ""

docker push 152254703525.dkr.ecr.eu-west-1.amazonaws.com/enm/eric-enm-neo4j-server-extension:latest
echo ""

docker rmi armdocker.rnd.ericsson.se/proj_oss_releases/enm/eric-enm-neo4j-server-extension:latest \
152254703525.dkr.ecr.eu-west-1.amazonaws.com/enm/eric-enm-neo4j-server-extension:latest
echo ""

echo "Docker build and push script has finished successfully"

