#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
IMAGE_REGISTRY="mcr.microsoft.com"
IMAGE_NAME="aks/kaito/kaito-phi-4"
IMAGE_TAG="${1:-0.2.0}"  # Default to latest version, can be overridden
FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
PATCHED_TAG="${IMAGE_NAME//\//-}-${IMAGE_TAG}-patched"
BUILDKIT_CONTAINER="buildkitd-copa-test"

echo -e "${BLUE}=== Copa App-Level Patching Test for Kaito Phi-4 ===${NC}"
echo -e "${BLUE}Testing image: ${FULL_IMAGE}${NC}\n"

# Function to cleanup resources
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker stop ${BUILDKIT_CONTAINER} 2>/dev/null || true
    rm -f trivy-report-*.json copa-vex-*.json 2>/dev/null || true
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Step 1: Pull the image
echo -e "${GREEN}Step 1: Pulling image from MCR...${NC}"
docker pull ${FULL_IMAGE}

# Step 2: Run initial Trivy scan for all vulnerabilities
echo -e "\n${GREEN}Step 2: Running Trivy scan for all vulnerabilities...${NC}"
echo -e "${YELLOW}Scanning for OS vulnerabilities:${NC}"
trivy image ${FULL_IMAGE} \
    --vuln-type os \
    --format table \
    --severity CRITICAL,HIGH,MEDIUM \
    --no-progress

echo -e "\n${YELLOW}Scanning for library/app-level vulnerabilities:${NC}"
trivy image ${FULL_IMAGE} \
    --vuln-type library \
    --format table \
    --severity CRITICAL,HIGH,MEDIUM \
    --no-progress

# Generate JSON report for patching
echo -e "\n${GREEN}Generating JSON vulnerability report...${NC}"
trivy image ${FULL_IMAGE} \
    --vuln-type library \
    --format json \
    --output trivy-report-library.json \
    --no-progress

# Display vulnerability summary
echo -e "\n${YELLOW}Vulnerability Summary:${NC}"
VULN_COUNT=$(cat trivy-report-library.json | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH")] | length')
echo -e "Found ${RED}${VULN_COUNT}${NC} CRITICAL/HIGH library vulnerabilities"

# Step 3: Build and install Copa from PR #1091 (sozercan:lang-python2)
echo -e "\n${GREEN}Step 3: Building Copa from PR #1091 with app-level patching support...${NC}"
echo -e "${YELLOW}Building Copa from sozercan:lang-python2 branch...${NC}"

# Check if we need to build Copa
if [ ! -f /tmp/copa-app-level ] || [ "$REBUILD_COPA" = "true" ]; then
    # Install Go if not present
    if ! command -v go &> /dev/null; then
        echo -e "${YELLOW}Installing Go...${NC}"
        wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
        sudo tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        rm go1.22.0.linux-amd64.tar.gz
    fi
    
    # Clone and build Copa from the specific branch
    echo -e "${YELLOW}Cloning Copa repository...${NC}"
    TEMP_DIR=$(mktemp -d)
    cd $TEMP_DIR
    git clone -b lang-python2 https://github.com/sozercan/copacetic.git
    cd copacetic
    
    echo -e "${YELLOW}Building Copa binary...${NC}"
    go build -o /tmp/copa-app-level ./cmd/copa
    cd $HOME
    rm -rf $TEMP_DIR
    
    echo -e "${GREEN}Copa built successfully from PR #1091${NC}"
else
    echo -e "${GREEN}Using existing Copa binary from PR #1091${NC}"
fi

# Use the custom Copa binary
alias copa=/tmp/copa-app-level
/tmp/copa-app-level version || echo "Copa version check failed - continuing anyway"

# Step 4: Start BuildKit daemon
echo -e "\n${GREEN}Step 4: Starting BuildKit daemon...${NC}"
docker run \
    --detach \
    --rm \
    --privileged \
    --name ${BUILDKIT_CONTAINER} \
    --entrypoint buildkitd \
    moby/buildkit:latest

# Wait for BuildKit to be ready
sleep 5

# Step 5: Patch the image with Copa (app-level)
echo -e "\n${GREEN}Step 5: Patching image with Copa (app-level vulnerabilities)...${NC}"
export COPA_EXPERIMENTAL=1
export BUILDKIT_HOST=docker-container://${BUILDKIT_CONTAINER}

echo -e "${YELLOW}Running Copa patch with library-level patching...${NC}"
/tmp/copa-app-level patch \
    --image ${FULL_IMAGE} \
    --report trivy-report-library.json \
    --tag ${PATCHED_TAG} \
    --pkg-types library \
    --library-patch-level patch \
    --addr docker-container://${BUILDKIT_CONTAINER} \
    --output copa-vex-library.json \
    --format openvex

echo -e "${GREEN}Patching completed!${NC}"

# Step 6: Verify the patched image
echo -e "\n${GREEN}Step 6: Verifying patched image...${NC}"
echo -e "${YELLOW}Image details:${NC}"
docker images | grep -E "(${IMAGE_NAME}|${PATCHED_TAG})" | head -5

# Step 7: Re-scan the patched image
echo -e "\n${GREEN}Step 7: Re-scanning patched image for vulnerabilities...${NC}"
echo -e "${YELLOW}Library vulnerabilities after patching:${NC}"
trivy image ${PATCHED_TAG} \
    --vuln-type library \
    --format table \
    --severity CRITICAL,HIGH,MEDIUM \
    --no-progress

# Generate post-patch report
trivy image ${PATCHED_TAG} \
    --vuln-type library \
    --format json \
    --output trivy-report-library-patched.json \
    --no-progress

# Step 8: Compare before and after
echo -e "\n${GREEN}Step 8: Comparison Summary${NC}"
VULN_COUNT_AFTER=$(cat trivy-report-library-patched.json | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH")] | length')

echo -e "${BLUE}=== Patching Results ===${NC}"
echo -e "Original image: ${FULL_IMAGE}"
echo -e "Patched image:  ${PATCHED_TAG}"
echo -e "\nLibrary vulnerabilities (CRITICAL/HIGH):"
echo -e "  Before: ${RED}${VULN_COUNT}${NC}"
echo -e "  After:  ${GREEN}${VULN_COUNT_AFTER}${NC}"
echo -e "  Reduced by: ${YELLOW}$((VULN_COUNT - VULN_COUNT_AFTER))${NC}"

# Step 9: Display VEX document
echo -e "\n${GREEN}Step 9: VEX Document Summary${NC}"
if [ -f copa-vex-library.json ]; then
    echo -e "${YELLOW}Statements in VEX document:${NC}"
    jq -r '.statements[] | "- \(.vulnerability.name): \(.status)"' copa-vex-library.json 2>/dev/null | head -10
    TOTAL_STATEMENTS=$(jq '.statements | length' copa-vex-library.json)
    echo -e "Total VEX statements: ${BLUE}${TOTAL_STATEMENTS}${NC}"
fi

# Step 10: Test specific Python packages if it's a Python image
echo -e "\n${GREEN}Step 10: Testing specific package versions (if Python image)...${NC}"
docker run --rm ${PATCHED_TAG} python -c "
import sys
print(f'Python version: {sys.version}')
try:
    import torch
    print(f'PyTorch version: {torch.__version__}')
except ImportError:
    pass
try:
    import transformers
    print(f'Transformers version: {transformers.__version__}')
except ImportError:
    pass
try:
    import numpy
    print(f'NumPy version: {numpy.__version__}')
except ImportError:
    pass
" 2>/dev/null || echo "Not a Python image or packages not found"

echo -e "\n${GREEN}=== Test Complete ===${NC}"
echo -e "${BLUE}You can now use the patched image: ${PATCHED_TAG}${NC}"
echo -e "${YELLOW}To push to a registry: docker tag ${PATCHED_TAG} <your-registry>/${PATCHED_TAG} && docker push <your-registry>/${PATCHED_TAG}${NC}"