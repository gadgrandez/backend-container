#!/bin/sh
# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Starts an IPython container deployed to a GCE VM.

USAGE_ERROR=

gcloud -q config list compute/zone --format text | grep -q -i -F "none"
if [ $? = 0 ]; then
  USAGE_ERROR="Default compute zone is not set."
fi

gcloud -q config list project --format text | grep -q -i -F "none"
if [ $? = 0 ]; then
  USAGE_ERROR="Default cloud project is not set."
fi

if [ "$DOCKER_REGISTRY" = "" ]; then
  USAGE_ERROR="Docker registry has not been specified."
fi

if [ "$#" -lt 1 ]; then
  USAGE_ERROR="Missing required vm name parameter."
fi

if [ "$USAGE_ERROR" != "" ]; then
  echo $USAGE_ERROR
  echo
  echo "Usage: $0 <vm name> [<machine type>]"
  echo "  vm name:      the name of the VM to create."
  echo "  machine type: the type of VM to create (default: n1-standard-1)"
  echo
  echo "Required configuration:"
  echo "  - default cloud project"
  echo "    gcloud config set project <project name>"
  echo "  - default compute zone"
  echo "    gcloud config set compute/zone <zone name>"
  echo "  - docker registry (while docker image is unavailable via docker.io)"
  echo "    export DOCKER_REGISTRY=<docker host:port>"
  echo

  exit 1
fi

# Initialize variables
VM=$1
if [ "$2" = "" ]; then
  VM_TYPE="n1-standard-1"
else
  VM_TYPE=$2
fi

CLOUD_PROJECT=`gcloud config list project --format text | sed 's/core\.project: //'`
NETWORK_NAME=ipython
DOCKER_IMAGE="$DOCKER_REGISTRY/gcp-ipython"
PORT=8092


# Create VM instance if needed
gcloud -q compute instances describe $VM &> /dev/null
if [ $? -gt 0 ]; then

  # Generate the VM manifest
  cat > vm.yaml << EOF1
version: v1beta2
containers:
  - name: $VM
    image: $DOCKER_IMAGE
    env:
      - name: CLOUD_PROJECT
        value: $CLOUD_PROJECT
    ports:
      - name: ipython
        hostPort: 8080
        containerPort: 8080
    volumeMounts:
      - name: log
        mountPath: /var/log/ipython
volumes:
  - name: log
    source:
      hostDir:
        path: /ipython/log

EOF1


  # Create the network (if needed) and allow SSH access
  gcloud -q compute networks describe $NETWORK_NAME &> /dev/null
  if [ $? -gt 0 ]; then
    echo "Creating network '$NETWORK_NAME' to associate with VM ..."

    gcloud -q compute networks create $NETWORK_NAME &> /dev/null
    if [ $? != 0 ]; then
      echo "Failed to create network $NETWORK_NAME"
      exit 1
    fi

    gcloud -q compute firewall-rules create allow-ssh --allow tcp:22 \
      --network $NETWORK_NAME &> /dev/null
    if [ $? != 0 ]; then
      echo "Failed to create firewall rule to allow SSH in network $NETWORK_NAME"
      exit 1
    fi
  fi


  # Create the VM
  echo "Creating VM instance '$VM' ..."
  gcloud -q compute instances create $VM \
    --image container-vm-v20140731 \
    --image-project google-containers \
    --machine-type $VM_TYPE \
    --network $NETWORK_NAME \
    --scopes storage-full bigquery datastore sql \
    --metadata-from-file google-container-manifest=vm.yaml \
    --tags "ipython"
  if [ $? != 0 ]; then
    echo "Failed to create VM instance named $VM"
    exit 1
  fi


  # Cleanup
  rm vm.yaml


  # Wait for VM to start
  echo "Waiting for VM instance '$VM' to start ..."
  until $(gcloud -q compute instances describe $VM | grep -q '^status:[ \t]*RUNNING' ); do
    printf "."
    sleep 2
  done
  echo

else 
  echo "Using existing VM instance '$VM'"
fi


# Reclaim ssh tunnel port
PID=$(fuser $PORT/tcp 2> /dev/null)
if [ $? == 0 ]; then
  if (ps $PID | grep -q ssh); then
    fuser -k $PORT/tcp
  else
    echo "Port $PORT is already in use."
    fuser -v  $PORT/tcp
    exit 1
  fi
fi


# Set up ssh tunnel
echo "Creating ssh tunnel to instance '$VM' ..."
gcloud -q compute ssh --ssh-flag="-L $PORT:localhost:8080" --ssh-flag="-f" --ssh-flag="-N" $VM
if [ $? != 0 ]; then
  echo "Failed to create ssh tunnel to instance '$VM'"
  exit 1
fi


# Wait for containers to start
echo "Waiting for IPython container on instance '$VM' to start ..."
until $(curl -s -o /dev/null localhost:$PORT); do
  printf "."
  sleep 2
done
echo


echo "VM has been started..."

# Open IPython in local browser session
URL="http://localhost:$PORT"
case $(uname) in
  'Darwin') open $URL ;;
  'Linux') x-www-browser $URL ;;
esac
echo $URL

exit 0
