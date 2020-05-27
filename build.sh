#!/bin/sh

APP_NAME=`echo ${GITHUB_REPO} | sed 's/_/-/g'`
APP_NAME=`echo ${APP_NAME} | sed 's/-//g'`
APP_NAME=`echo ${APP_NAME} | cut -c1-15`

echo -n "$CODEBUILD_BUILD_ID" | sed "s/.*:\([[:xdigit:]]\{7\}\).*/\1/" > build.id
if [ "$DEPLOY_ENVIRONMENT" = "development" ] || \
   [ "$DEPLOY_ENVIRONMENT" = "feature" ] || \
   [ "$DEPLOY_ENVIRONMENT" = "hotfix" ]; then
    echo -n "$TAG_NAME-$BUILD_SCOPE-$(cat ./build.id)" > docker.tag
    docker build -t $AWS_ACCOUNT_ID.dkr.ecr.$ECS_REGION.amazonaws.com/$ECR_NAME:$(cat docker.tag) .
    TAG=$(cat docker.tag)
elif [ "$DEPLOY_ENVIRONMENT" = "staging" ] ; then
    echo -n "${RELEASE_PLAN}-$BUILD_SCOPE-$(cat ./build.id)" > docker.tag
    docker build --build-arg DEPLOY_ENVIRONMENT=$DEPLOY_ENVIRONMENT -t $AWS_ACCOUNT_ID.dkr.ecr.$ECS_REGION.amazonaws.com/$ECR_NAME:$(cat docker.tag) .
    TAG=$(cat docker.tag)
elif [ "$DEPLOY_ENVIRONMENT" = "release" ] ; then
    GITHUB_TOKEN=${GITHUB_TOKEN}
    git config --global user.email ${GITHUB_EMAIL}
    git config --global user.name ${GITHUB_USERNAME}
    git clone https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}
    cd ${GITHUB_REPO}
    git checkout staging
    git tag
    echo "$(git log `git describe --tags --abbrev=0`..HEAD --pretty=format:"<br>- %s%b<br>")" | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/<br>/g' | tr -d '\r' | sed "s/\"/'/g" > ./commits
    cat ./commits
    git tag $(cat ../docker.tag)
    git push --tags
    git checkout master
    git merge staging
    git push origin master
    API_JSON=$(printf '{"tag_name": "%s","target_commitish": "master",
    "name": "%s - (Release Notes)","body": "%s",
    "draft": false,"prerelease": false}' $RELEASE_PLAN $RELEASE_PLAN "$(cat commits)")
    echo $API_JSON
    API_URI="https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/releases?access_token=${GITHUB_TOKEN}"
    echo $API_URI
    RELEASE_STATUS=$(curl --write-out %{http_code} --silent --output /dev/null --data "$API_JSON" "$API_URI")
    if [ $RELEASE_STATUS != 201 ]; then
        echo "Release Failed with status:${RELEASE_STATUS}"
        exit 1;
    fi
    cd ..
else
    echo "Entering Production Build"
    GITHUB_TOKEN=${GITHUB_TOKEN}
    git clone https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}
    cd ${GITHUB_REPO}
    git checkout staging
    STAGE_TAG=$(git describe --tags --abbrev=0 --match "*candidate*")
    TAG=$(curl https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/releases/latest?access_token=${GITHUB_TOKEN} | grep tag_name | grep -Eo "([0-9]\.*)+")
    echo $STAGE_TAG > ../stage.tag
    echo $TAG > ../prod.tag
    cat ../stage.tag
    cat ../prod.tag
    cd ..
fi

if [ "$DEPLOY_ENVIRONMENT" != "release" ] ; then
  sed -i "s@APP_NAME@$APP_NAME@g" ecs/service.yaml
  sed -i "s@TAG@$TAG@g" ecs/service.yaml
  sed -i "s#EMAIL#$EMAIL#g" ecs/service.yaml
  sed -i "s@ENVIRONMENT_NAME@$ENVIRONMENT_NAME@g" ecs/service.yaml
  sed -i "s@BUILD_SCOPE@$BUILD_SCOPE@g" ecs/service.yaml
  sed -i "s@ECS_REPOSITORY_NAME@$ECR_NAME@g" ecs/service.yaml
  sed -i "s@ECS_CPU_COUNT@$ECS_CPU_COUNT@g" ecs/service.yaml
  sed -i "s@ECS_MEMORY_RESERVATION_COUNT@$ECS_MEMORY_RESERVATION_COUNT@g" ecs/service.yaml
  sed -i "s@HOSTED_ZONE@$HOSTED_ZONE@g" ecs/service.yaml
  sed -i "s@CERTIFICATE_ARN@$CERTIFICATE_ARN@g" ecs/service.yaml
  sed -i "s@DESIRED_COUNT@$DESIRED_COUNT@g" ecs/service.yaml

  if [ "$S3_SWAGGER_BUCKET_NAME" != "" ] ; then
    sed -i "s@S3_SWAGGER_BUCKET_NAME@$S3_SWAGGER_BUCKET_NAME@g" ecs/service.yaml
    sed -i "s@GITHUB_REPO@$GITHUB_REPO@g" ecs/service.yaml
    sed -i "s@{{APP_NAME}}@$APP_NAME@g" swagger.yaml
    sed -i "s@{{DOMAIN_NAME}}@`echo $HOSTED_ZONE | sed s'/.$//'`@g" swagger.yaml
    cat swagger.yaml | sed 's/^/        /' > _swagger.yaml
    perl -i -pe 's/OPEN_API_SPEC/`cat _swagger.yaml`/e' ecs/service.yaml
    aws s3 cp swagger.yaml s3://$S3_SWAGGER_BUCKET_NAME/$GITHUB_REPO.yaml
  else
    sed -i "s@S3_SWAGGER_BUCKET_NAME@SKIP_API_GATEWAY@g" ecs/service.yaml
    sed -i "s@OPEN_API_SPEC@        SKIP_API_GATEWAY@g" ecs/service.yaml
  fi

  . ecs/params.sh
  perl -i -pe 's/ENVIRONMENT_VARIABLES/`cat env.yaml`/e' ecs/service.yaml
  # Remove the env yaml (not to persist secrets)
  rm env.yaml
fi
