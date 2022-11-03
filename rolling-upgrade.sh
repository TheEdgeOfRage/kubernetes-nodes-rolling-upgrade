#!/usr/bin/env bash
set -euo pipefail

# Perform a rolling upgrade on a Kubernetes cluster.
#
# See README.md for details

DRY_RUN=${DRY_RUN:-}
DRAIN_TIMEOUT=${DRAIN_TIMEOUT:-3600}
TARGET_STORAGE_SIZE=${TARGET_STORAGE_SIZE:-104845292Ki}

function run() {
  if [ -z "$DRY_RUN" ]; then
    echo "Running: $*"
    "$@"
  else
    echo "Dry run mode enabled 🍃"
    echo "Would run: $*"
  fi
}
bold=$(tput bold)
normal=$(tput sgr0)

while true; do
  echo "Looking for upgradeable nodes..."
  ALL_NODES=$(kubectl get node --no-headers | awk '{print $1}')

  for NODE in $ALL_NODES; do
    STORAGE_SIZE=$(kubectl get node -o jsonpath={.status.capacity.ephemeral-storage} $NODE)

    if [ $STORAGE_SIZE == $TARGET_STORAGE_SIZE ]; then
      continue
    fi

    echo ""
    echo "• Upgrading node ${bold}$NODE${normal}"
    echo ""

    echo "${bold}Step 1: drain${normal}"
    set +e
    run kubectl drain --timeout="$DRAIN_TIMEOUT"s --ignore-daemonsets --delete-emptydir-data "$NODE"
    STATUS=$?
    if [ $STATUS -eq 0 ]
    then
      echo "Node drained successfully"
    elif [ $STATUS -eq 124 ]
    then
      echo "⚠️  Drain went over timeout, terminating node anyway"
    else
      echo "⚠️  Drain failed, skipping node"
      continue
    fi

    echo "${bold}Step 2: terminate${normal}"
    INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=$NODE" --output text --query 'Reservations[*].Instances[*].InstanceId')
    if [ -z "$INSTANCE_ID" ]
    then
      echo "Instance disappeared, skipping"
      continue
    fi
    run aws ec2 terminate-instances --instance-ids="$INSTANCE_ID"

    echo "${bold}Step 3: wait for pending pods${normal}"
    PODS=$(kubectl get pods --all-namespaces)
    if [ -z "$DRY_RUN" ]; then
      while echo "$PODS" | grep -e 'Pending' -e 'ContainerCreating' -e 'Terminating'
      do
        echo "^ Found pending / terminating pods, waiting 5 seconds..."
        sleep 5
        PODS=$(kubectl get pods --all-namespaces)
      done
    else
      echo "Dry run mode enabled 🍃"
      echo "Would wait for pods"
    fi

    echo "No unscheduled pods!"
    echo ""
  done
done
