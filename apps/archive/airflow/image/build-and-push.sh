#!/bin/bash
set -e  # Exit on any error

# Configuration
IMAGE_REGISTRY=""
IMAGE_REPO="raulstechtips/airflow"
IMAGE_TAG="3.1.3-raulstechtips-0.0.1-rc2"
PLATFORM="linux/amd64"

# Derived variables
FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "Building Airflow Custom Image"
echo "=========================================="
echo "Registry: ${IMAGE_REGISTRY}"
echo "Repository: ${IMAGE_REPO}"
echo "Tag: ${IMAGE_TAG}"
echo "Platform: ${PLATFORM}"
echo "Full Image: ${FULL_IMAGE}"
echo "Build Context: ${SCRIPT_DIR}"
echo "=========================================="
echo ""

# Check if the image already exists locally
echo "Checking if image already exists locally..."
if docker image inspect "${FULL_IMAGE}" >/dev/null 2>&1; then
    echo "Image ${FULL_IMAGE} already exists locally. Skipping build."
    echo ""
else
    # Build the image
    echo "Image not found locally. Building image for ${PLATFORM}..."
    docker buildx build \
        --platform "${PLATFORM}" \
        -t "${FULL_IMAGE}" \
        --load \
        .
    
    echo "Build completed successfully!"
    echo ""
fi

# Push the image
echo "Pushing ${FULL_IMAGE}..."
docker push "${FULL_IMAGE}"

echo "Push completed successfully!"
echo ""
