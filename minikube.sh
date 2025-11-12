#!/bin/bash

# Configuration
K8S_VERSION="v1.34.0"
DRIVER="docker"
NODES=2

echo "🚀 Starting Minikube cluster with ${NODES} nodes..."

# Step 1: Start cluster
minikube start \
  --nodes=${NODES} \
  --driver=${DRIVER} \
  --kubernetes-version=${K8S_VERSION} \
  --cpus=4 --memory=2048


