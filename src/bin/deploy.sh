#!/bin/sh
set -e
set -x
LOG="/home/ubuntu/deploy.log"
touch $LOG

DATA_DIRECTORY="/data"
TOML="$DATA_DIRECTORY/gitlab-runner-config/config.toml"
PORT=10080

export TOML="/data/gitlab-runner-config/config.toml"
export DISPATCHER_DESCRIPTION="Packaged Dispatcher on $CI_COMMIT_REF_SLUG-$INSTANCE"
export AIOPS_RUNNER_EC2_INSTANCE_TYPE="p2.xlarge"
# number of instances is limited by aws
# https://eu-central-1.console.aws.amazon.com/ec2/v2/home?region=eu-central-1#Limits:
export AIOPS_RUNNER_EC2_INSTANCE_LIMIT=1

export INSTANCE=""
export IMAGE_PATH=""
export AWS_ACCESS_KEY_ID=""
export AWS_SECRET_ACCESS_KEY=""
export GITLAB_ADMIN_TOKEN=""
export WORKAROUND_SLEEP="120"                               # This is a workaround variable used for deployment

while [ -n "$1" ]; do
  case "$1" in
  -i | --instance) INSTANCE="$2"
    echo "Connecting to ec2 instance $INSTANCE"            >> $LOG
    shift ;;
  -I | --image) IMAGE_PATH="$2"
    echo "Using docker image: $IMAGE_PATH"                 >> $LOG
    shift ;;
  -p | --port) PORT="$2"
    echo "Expecting gitlab at port $PORT"                  >> $LOG
    shift ;;
  -k | --key) AWS_ACCESS_KEY_ID="$2"
    echo "Using AWS_ACCESS_KEY_ID $AWS_ACCESS_KEY_ID"      >> $LOG
    shift ;;
  -s | --secret) AWS_SECRET_ACCESS_KEY="$2"
    echo "Using AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY"  >> $LOG
    shift ;;
  -n | --name) EC2_INSTANCE_NAME="$2"
    echo "Using EC2_INSTANCE_NAME $EC2_INSTANCE_NAME"
    shift ;;
  -g | --gitlab-admin-token) GITLAB_ADMIN_TOKEN="$2"
    echo "Using GITLAB_ADMIN_TOKEN $GITLAB_ADMIN_TOKEN"     >> $LOG
    shift ;;
  -w | --workaround) WORKAROUND_SLEEP="$2"
    echo "Using WORKAROUND_SLEEP $WORKAROUND_SLEEP"          >> $LOG
    shift ;;
  *) echo "Option $1 not recognized" ;;
  esac
  shift
done

echo "Successfuly parsed parameters"

if [ "$INSTANCE" = "" ]; then
  echo "Missing instance url. Use the -i or --instance option" >> $LOG
  exit 1
fi
if [ "$IMAGE_PATH" = "" ]; then
  echo "Missing docker image. Use the -I or --image option"    >> $LOG
  exit 1
fi
if [ "$AWS_ACCESS_KEY_ID" = "" ]; then
  echo "Missing AWS_ACCESS_KEY_ID. Use the -k or --key option" >> $LOG
  exit 1
fi
if [ "$AWS_SECRET_ACCESS_KEY" = "" ]; then
  echo "Missing AWS_SECRET_ACCESS_KEY. Use the -s or --secret option" >> $LOG
  exit 1
fi
if [ "$GITLAB_ADMIN_TOKEN" = "" ]; then
  echo "Missing GITLAB_ADMIN_TOKEN. Use the -g or --gitlab-admin-token option" >> $LOG
  exit 1
fi
export DISPATCHER_DESCRIPTION="Packaged Dispatcher on $CI_COMMIT_REF_SLUG-$INSTANCE"


echo "Registering packaged runner to local Gitlab instance" >> $LOG

LINE=$(sudo cat $TOML | grep token)
echo "The registration token is: $LINE"         >> $LOG
rm -rf $TOML                                    >> $LOG


# Update the Runner configuration on the new instance.
# https://docs.gitlab.com/runner/configuration/advanced-configuration.html#volumes-in-the-runnersdocker-section
# tee copies data from standard input to each FILE, and also to standard output.
# runtime="nvidia"
echo | sudo tee $TOML <<EOF
concurrent = 12
check_interval = 0

[[runners]]
  name = "${DISPATCHER_DESCRIPTION}"
  limit = $AIOPS_RUNNER_EC2_INSTANCE_LIMIT
  url = "http://$INSTANCE:$PORT/"
$LINE
  executor = "docker"
  [runners.docker]
    image = "alpine:latest"
    tls_verify = false
    privileged = true
    disable_cache = false
    volumes = ["/cache"]
    shm_size = 0
  [runners.cache]
    ServerAddress = "s3.amazonaws.com"
    AccessKey = "$AWS_ACCESS_KEY_ID"
    SecretKey = "$AWS_SECRET_ACCESS_KEY"
    BucketName = "mlreef-runner-cache"
    BucketLocation = "eu-central-1"

EOF


# Just a copy of the multi runner configuration to be able to play with it
echo | sudo tee "$TOML.multi-runner" <<EOF
concurrent = 12
check_interval = 0

[[runners]]
  name = "${DISPATCHER_DESCRIPTION}"
  limit = $AIOPS_RUNNER_EC2_INSTANCE_LIMIT
  url = "http://$INSTANCE:$PORT/"
$LINE
  executor = "docker+machine"
  [runners.docker]
    tls_verify = false
    image = "alpine:latest"
    privileged = true
    disable_cache = false
    volumes = ["/cache"]
    shm_size = 0
  [runners.cache]
    ServerAddress = "s3.amazonaws.com"
    AccessKey = "$AWS_ACCESS_KEY_ID"
    SecretKey = "$AWS_SECRET_ACCESS_KEY"
    BucketName = "mlreef-runner-cache"
    BucketLocation = "eu-central-1"
  [runners.machine]
    IdleCount = 0
    MachineDriver = "amazonec2"
    MachineName = "mlreef-aiops-%s"
    MachineOptions = [
      "amazonec2-access-key=$AWS_ACCESS_KEY_ID",
      "amazonec2-secret-key=$AWS_SECRET_ACCESS_KEY",
      "amazonec2-ssh-user=ubuntu",
      "amazonec2-region=eu-central-1",
      "amazonec2-zone=b",
      "amazonec2-instance-type=$AIOPS_RUNNER_EC2_INSTANCE_TYPE",
      "amazonec2-ami=ami-050a22b7e0cf85dd0",
    ]
    IdleTime = 5
    OffPeakTimezone = ""
    OffPeakIdleCount = 0

EOF

if [ "$GITLAB_SECRETS_SECRET_KEY_BASE" = "" ]; then
  export GITLAB_SECRETS_SECRET_KEY_BASE=secret11111111112222222222333333333344444444445555555555666666666612345
fi

if [ "$GITLAB_SECRETS_OTP_KEY_BASE" = "" ]; then
  export GITLAB_SECRETS_OTP_KEY_BASE=secret11111111112222222222333333333344444444445555555555666666666612345
fi

if [ "$GITLAB_SECRETS_DB_KEY_BASE" = "" ]; then
  export GITLAB_SECRETS_DB_KEY_BASE=secret11111111112222222222333333333344444444445555555555666666666612345
fi

if [ "$GITLAB_ADMIN_TOKEN" = "" ]; then
  export GITLAB_ADMIN_TOKEN=QVj_FkeHyuJURko2ggZT
fi

echo "# generated by deploy.sh" > local.env
echo GITLAB_SECRETS_SECRET_KEY_BASE=$GITLAB_SECRETS_SECRET_KEY_BASE >> local.env
echo GITLAB_SECRETS_OTP_KEY_BASE=$GITLAB_SECRETS_OTP_KEY_BASE >> local.env
echo GITLAB_SECRETS_DB_KEY_BASE=$GITLAB_SECRETS_DB_KEY_BASE >> local.env
echo GITLAB_ADMIN_TOKEN=$GITLAB_ADMIN_TOKEN >> local.env


docker-compose stop

docker-compose up --detach
sleep "${WORKAROUND_SLEEP}"

docker-compose stop backend
sleep "${WORKAROUND_SLEEP}"

# 1. Inject known admin token
echo "Creating the admin token with GITLAB_ADMIN_TOKEN: ${GITLAB_ADMIN_TOKEN}"
docker exec --tty postgresql setup-gitlab.sh

docker-compose up --detach
sleep "30"

docker-compose stop backend
sleep "30"


docker-compose up --detach