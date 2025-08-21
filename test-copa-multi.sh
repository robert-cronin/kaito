#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
IMAGES=(
    "mcr.microsoft.com/aks/kaito/kaito-phi-4:0.2.0"
    "mcr.microsoft.com/aks/kaito/kaito-phi-4:0.1.1"
    "mcr.microsoft.com/aks/kaito/kaito-phi-4:0.1.0"
)

PATCH_LEVELS=("patch" "minor" "major")
BUILDKIT_CONTAINER="buildkitd-copa-test"
COPA_BINARY="/tmp/copa-app-level"

echo -e "${BLUE}=== Copa App-Level Patching Multi-Test ===${NC}"

# Function to cleanup resources
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker stop ${BUILDKIT_CONTAINER} 2>/dev/null || true
    rm -f trivy-*.json copa-*.json 2>/dev/null || true
}

# Function to build Copa from PR
build_copa() {
    echo -e "\n${GREEN}Building Copa from PR #1091 (sozercan:lang-python2)...${NC}"
    
    if [ ! -f ${COPA_BINARY} ] || [ "$REBUILD_COPA" = "true" ]; then
        # Install Go if not present
        if ! command -v go &> /dev/null; then
            echo -e "${YELLOW}Installing Go...${NC}"
            wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
            sudo tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
            export PATH=$PATH:/usr/local/go/bin
            rm go1.22.0.linux-amd64.tar.gz
        fi
        
        # Clone and build Copa
        TEMP_DIR=$(mktemp -d)
        cd $TEMP_DIR
        git clone -b lang-python2 https://github.com/sozercan/copacetic.git
        cd copacetic
        go build -o ${COPA_BINARY} ./cmd/copa
        cd $HOME
        rm -rf $TEMP_DIR
        
        echo -e "${GREEN}Copa built successfully${NC}"
    else
        echo -e "${GREEN}Using existing Copa binary${NC}"
    fi
    
    ${COPA_BINARY} version || echo "Version check failed - continuing"
}

# Function to test a single image with a patch level
test_image() {
    local IMAGE=$1
    local PATCH_LEVEL=$2
    local IMAGE_NAME=$(echo $IMAGE | sed 's/[:/]/-/g')
    
    echo -e "\n${BLUE}Testing: ${IMAGE} with patch level: ${PATCH_LEVEL}${NC}"
    
    # Pull image
    echo -e "${YELLOW}Pulling image...${NC}"
    docker pull ${IMAGE}
    
    # Scan for vulnerabilities
    echo -e "${YELLOW}Scanning for library vulnerabilities...${NC}"
    trivy image ${IMAGE} \
        --vuln-type library \
        --format json \
        --output trivy-${IMAGE_NAME}.json \
        --no-progress
    
    # Count vulnerabilities
    VULN_COUNT=$(cat trivy-${IMAGE_NAME}.json | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH")] | length')
    echo -e "Found ${RED}${VULN_COUNT}${NC} CRITICAL/HIGH library vulnerabilities"
    
    if [ ${VULN_COUNT} -eq 0 ]; then
        echo -e "${GREEN}No CRITICAL/HIGH vulnerabilities found, skipping patch${NC}"
        return
    fi
    
    # Patch image
    echo -e "${YELLOW}Patching with library-patch-level: ${PATCH_LEVEL}...${NC}"
    PATCHED_TAG="${IMAGE_NAME}-${PATCH_LEVEL}-patched"
    
    export COPA_EXPERIMENTAL=1
    ${COPA_BINARY} patch \
        --image ${IMAGE} \
        --report trivy-${IMAGE_NAME}.json \
        --tag ${PATCHED_TAG} \
        --pkg-types library \
        --library-patch-level ${PATCH_LEVEL} \
        --addr docker-container://${BUILDKIT_CONTAINER} \
        --output copa-${IMAGE_NAME}-${PATCH_LEVEL}.json \
        --format openvex || {
            echo -e "${RED}Patching failed for ${IMAGE} with ${PATCH_LEVEL}${NC}"
            return
        }
    
    # Re-scan patched image
    echo -e "${YELLOW}Re-scanning patched image...${NC}"
    trivy image ${PATCHED_TAG} \
        --vuln-type library \
        --format json \
        --output trivy-${IMAGE_NAME}-${PATCH_LEVEL}-patched.json \
        --no-progress
    
    VULN_COUNT_AFTER=$(cat trivy-${IMAGE_NAME}-${PATCH_LEVEL}-patched.json | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH")] | length')
    
    # Results
    echo -e "${GREEN}Results for ${IMAGE} (${PATCH_LEVEL}):${NC}"
    echo -e "  Before: ${RED}${VULN_COUNT}${NC} vulnerabilities"
    echo -e "  After:  ${GREEN}${VULN_COUNT_AFTER}${NC} vulnerabilities"
    echo -e "  Reduced by: ${YELLOW}$((VULN_COUNT - VULN_COUNT_AFTER))${NC}"
    
    # Save results
    echo "${IMAGE},${PATCH_LEVEL},${VULN_COUNT},${VULN_COUNT_AFTER},$((VULN_COUNT - VULN_COUNT_AFTER))" >> results.csv
}

# Main execution
trap cleanup EXIT

# Initialize results file
echo "Image,PatchLevel,VulnBefore,VulnAfter,Reduced" > results.csv

# Build Copa
build_copa

# Start BuildKit
echo -e "\n${GREEN}Starting BuildKit daemon...${NC}"
docker run \
    --detach \
    --rm \
    --privileged \
    --name ${BUILDKIT_CONTAINER} \
    --entrypoint buildkitd \
    moby/buildkit:latest

sleep 5

# Test each image with each patch level
for IMAGE in "${IMAGES[@]}"; do
    for PATCH_LEVEL in "${PATCH_LEVELS[@]}"; do
        test_image ${IMAGE} ${PATCH_LEVEL}
    done
done

# Display summary
echo -e "\n${BLUE}=== Summary Results ===${NC}"
column -t -s',' results.csv

echo -e "\n${GREEN}Test complete! Results saved to results.csv${NC}"