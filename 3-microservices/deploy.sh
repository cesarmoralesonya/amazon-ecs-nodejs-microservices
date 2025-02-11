REGION=$1
STACK_NAME=$2
PROFILE=$3
AWS_ACCOUNT=$4

DEPLOYABLE_SERVICES=(
	users
	threads
	posts
);

PRIMARY='\033[0;34m'
NC='\033[0m' # No Color

# Fetch the stack metadata for use later
printf "${PRIMARY}* Fetching current stack state${NC}\n";

QUERY=$(cat <<-EOF
[
	Stacks[0].Outputs[?OutputKey==\`ClusterName\`].OutputValue,
	Stacks[0].Outputs[?OutputKey==\`ALBArn\`].OutputValue,
	Stacks[0].Outputs[?OutputKey==\`ECSRole\`].OutputValue,
	Stacks[0].Outputs[?OutputKey==\`Url\`].OutputValue,
	Stacks[0].Outputs[?OutputKey==\`VPCId\`].OutputValue,
	Stacks[0].Outputs[?OutputKey==\`PublicSubnetOneId\`].OutputValue,
	Stacks[0].Outputs[?OutputKey==\`PublicSubnetTwoId\`].OutputValue,
	Stacks[0].Outputs[?OutputKey==\`EcsSecurityGroupId\`].OutputValue
]
EOF)

RESULTS=$(aws cloudformation describe-stacks \
	--stack-name $STACK_NAME \
	--region $REGION \
	--query "$QUERY" \
	--output text \
	--profile $PROFILE);
RESULTS_ARRAY=($RESULTS)

CLUSTER_NAME=${RESULTS_ARRAY[0]}
ALB_ARN=${RESULTS_ARRAY[1]}
ECS_ROLE=${RESULTS_ARRAY[2]}
URL=${RESULTS_ARRAY[3]}
VPCID=${RESULTS_ARRAY[4]}
PUBLICSUBNETONEID=${RESULTS_ARRAY[5]}
PUBLICSUBNETTWOID=${RESULTS_ARRAY[6]}
ECSSECURITYGROUPID=${RESULTS_ARRAY[7]}

printf "DEPLOY IN CLUSTER: ${CLUSTER_NAME}\n";
printf "DEPLOY IN SUBNETONE: ${PUBLICSUBNETONEID}\n";
printf "DEPLOY IN SUBNETTWO: ${PUBLICSUBNETTWOID}\n";
printf "DEPLOY IN SECURITYGROUP: ${ECSSECURITYGROUPID}\n";
printf "DEPLOY IN ECS_ROLE: ${ECS_ROLE}\n";

printf "${PRIMARY}* Authenticating with EC2 Container Repository${NC}\n";

aws ecr get-login-password --region $REGION --profile $PROFILE | docker login --username AWS --password-stdin $AWS_ACCOUNT.dkr.ecr.$REGION.amazonaws.com

# Tag for versioning the container images, currently set to timestamp
TAG=`date +%s`

for SERVICE_NAME in "${DEPLOYABLE_SERVICES[@]}"
do
	printf "${PRIMARY}* Locating the ECR repository for service \`${SERVICE_NAME}\`${NC}\n";

	# Find the ECR repo to push to
	REPO=`aws ecr describe-repositories \
		--region $REGION \
		--repository-names "$SERVICE_NAME" \
		--query "repositories[0].repositoryUri" \
		--output text \
		--profile $PROFILE` 

	if [ "$?" != "0" ]; then
		# The repository was not found, create it
		printf "${PRIMARY}* Creating new ECR repository for service \`${SERVICE_NAME}\`${NC}\n";

		REPO=`aws ecr create-repository \
			--region $REGION \
			--repository-name "$SERVICE_NAME" \
			--query "repository.repositoryUri" \
			--output text \
			--profile $PROFILE`
	fi

	printf "${PRIMARY}* Building \`${SERVICE_NAME}\`${NC}\n";

	# Build the container, and assign a tag to it for versioning
	(cd services/$SERVICE_NAME && npm install);
	docker build -t $SERVICE_NAME ./services/$SERVICE_NAME
	docker tag $SERVICE_NAME:latest $REPO:$TAG

	# Push the tag up so we can make a task definition for deploying it
	printf "${PRIMARY}* Pushing \`${SERVICE_NAME}\`${NC}\n";

	docker push $REPO:$TAG

	printf "${PRIMARY}* Creating new task definition for \`${SERVICE_NAME}\`${NC}\n";

	# Build an create the task definition for the container we just pushed
	CONTAINER_DEFINITIONS=$(cat <<-EOF
		[{
			"name": "$SERVICE_NAME",
			"image": "$REPO:$TAG",
			"cpu": 256,
			"memory": 256,
			"portMappings": [{
				"containerPort": 80,
				"hostPort": 80
			}],
			"essential": true
		}]
	EOF)

	TASK_DEFINITION_ARN=`aws ecs register-task-definition \
		--execution-role-arn $ECS_ROLE \
		--region $REGION \
		--family $SERVICE_NAME \
		--container-definitions "$CONTAINER_DEFINITIONS" \
		--network-mode awsvpc \
		--query "taskDefinition.taskDefinitionArn" \
		--requires-compatibilities FARGATE \
		--cpu 256 \
		--memory 512 \
		--output text \
		--profile $PROFILE`

	# Ensure that the service exists in ECS
	STATUS=`aws ecs describe-services \
		--region $REGION \
		--cluster $CLUSTER_NAME \
		--services $SERVICE_NAME \
		--query "services[0].status" \
		--output text \
		--profile $PROFILE`

	if [ "$STATUS" != "ACTIVE" ]; then
		# New service that needs to be deployed because it hasn't
		# been created yet.
		if [ -e "./services/$SERVICE_NAME/rule.json" ]; then
			# If this service has a rule setup for routing traffic to the service, then
			# create a target group for the service, and a rule on the ELB for routing
			# traffic to the target group.
			printf "${PRIMARY}* Setting up web facing service \`${SERVICE_NAME}\`${NC}\n";
			printf "${PRIMARY}* Creating target group for service \`${SERVICE_NAME}\`${NC}\n";

			TARGET_GROUP_ARN=`aws elbv2 create-target-group \
				--region $REGION \
				--name $SERVICE_NAME \
				--vpc-id $VPCID \
				--target-type ip \
				--port 80 \
				--protocol HTTP \
				--health-check-protocol HTTP \
				--health-check-path / \
				--health-check-interval-seconds 6 \
				--health-check-timeout-seconds 5 \
				--healthy-threshold-count 2 \
				--unhealthy-threshold-count 2 \
				--query "TargetGroups[0].TargetGroupArn" \
				--matcher HttpCode=200 \
				--output text \
				--profile $PROFILE`

			printf "${PRIMARY}* Locating load balancer listener \`${SERVICE_NAME}\`${NC}\n";

			LISTENER_ARN=`aws elbv2 describe-listeners \
				--region $REGION \
				--load-balancer-arn $ALB_ARN \
				--query "Listeners[0].ListenerArn" \
				--output text \
				--profile $PROFILE`

			if [ "$LISTENER_ARN" == "None" ]; then
				printf "${PRIMARY}* Creating listener for load balancer${NC}\n";

				LISTENER_ARN=`aws elbv2 create-listener \
					--region $REGION \
					--load-balancer-arn $ALB_ARN \
					--port 80 \
					--protocol HTTP \
					--query "Listeners[0].ListenerArn" \
					--default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
					--output text \
					--profile $PROFILE`
			fi

			printf "${PRIMARY}* Adding rule to load balancer listener \`${SERVICE_NAME}\`${NC}\n";

			# Manipulate the template to customize it with the target group and listener
			RULE_DOC=`cat ./services/$SERVICE_NAME/rule.json |
								jq ".ListenerArn=\"$LISTENER_ARN\" | .Actions[0].TargetGroupArn=\"$TARGET_GROUP_ARN\""`
			
			printf "$RULE_DOC \n";
			
			RULE=`aws elbv2 create-rule \
				--region $REGION \
				--cli-input-json "$RULE_DOC" \
				--profile $PROFILE`
			
			printf "${PRIMARY}* Rule created for service \`${SERVICE_NAME}\`${NC}:\n";

			printf "$RULE\n";

			printf "${PRIMARY}* Creating new web facing service \`${SERVICE_NAME}\`${NC}\n";

			LOAD_BALANCERS=$(cat <<-EOF
				[{
					"targetGroupArn": "$TARGET_GROUP_ARN",
					"containerName": "$SERVICE_NAME",
					"containerPort": 80
				}]
			EOF)

			printf "$LOAD_BALANCERS\n"

			RESULT=`aws ecs create-service \
				--region $REGION \
				--cluster $CLUSTER_NAME \
				--load-balancers "$LOAD_BALANCERS" \
				--service-name $SERVICE_NAME \
				--task-definition $TASK_DEFINITION_ARN \
				--launch-type FARGATE \
				--desired-count 1 \
				--network-configuration "awsvpcConfiguration={subnets=[$PUBLICSUBNETONEID, $PUBLICSUBNETTWOID],securityGroups=[$ECSSECURITYGROUPID], assignPublicIp=ENABLED}" \
				--profile $PROFILE`
			
			printf "$RESULT\n"
		else
			# This service doesn't have a web interface, just create it without load balancer settings
			printf "${PRIMARY}* Creating new background service \`${SERVICE_NAME}\`${NC}\n";
			RESULT=`aws ecs create-service \
				--region $REGION \
				--cluster $CLUSTER_NAME \
				--service-name $SERVICE_NAME \
				--task-definition $TASK_DEFINITION_ARN \
				--desired-count 1 \
				--profile $PROFILE`
		fi
	else
		# The service already existed, just update the existing service.
		printf "${PRIMARY}* Updating service \`${SERVICE_NAME}\` with task definition \`${TASK_DEFINITION_ARN}\`${NC}\n";
		RESULT=`aws ecs update-service \
			--region $REGION \
			--cluster $CLUSTER_NAME \
			--service $SERVICE_NAME \
			--task-definition $TASK_DEFINITION_ARN \
			--profile $PROFILE`
	fi
done

printf "${PRIMARY}* Done, application is at: http://${URL}${NC}\n";
printf "${PRIMARY}* (It may take a minute for the container to register as healthy and begin receiving traffic.)${NC}\n";
