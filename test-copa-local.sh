#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DOCKERFILE_PATH="docker/presets/models/tfs/Dockerfile"
BASE_IMAGE_NAME="kaito-tfs-dependencies"
IMAGE_TAG="test"
FULL_IMAGE="${BASE_IMAGE_NAME}:${IMAGE_TAG}"
PATCHED_TAG="${BASE_IMAGE_NAME}-patched"
BUILDKIT_CONTAINER="buildkitd-copa-test"
COPA_BINARY="/tmp/copa-app-level"
KAITO_ROOT=$(pwd)

echo -e "${BLUE}=== Copa App-Level Patching Test for Kaito TFS Dependencies ===${NC}"
echo -e "${BLUE}Building and testing local image: ${FULL_IMAGE}${NC}\n"

# Function to cleanup resources
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker stop ${BUILDKIT_CONTAINER} 2>/dev/null || true
    rm -f trivy-report-*.json copa-vex-*.json 2>/dev/null || true
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Step 1: Build Copa from PR #1091 (sozercan:lang-python2)
echo -e "${GREEN}Step 1: Building Copa from PR #1091 with app-level patching support...${NC}"

if [ ! -f ${COPA_BINARY} ] || [ "$REBUILD_COPA" = "true" ]; then
    # Install Go if not present
    if ! command -v go &> /dev/null; then
        echo -e "${YELLOW}Installing Go...${NC}"
        wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
        sudo tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        rm go1.22.0.linux-amd64.tar.gz
    fi
    
    # Clone and build Copa from the specific branch
    echo -e "${YELLOW}Cloning Copa repository from sozercan:lang-python2...${NC}"
    TEMP_DIR=$(mktemp -d)
    cd $TEMP_DIR
    git clone -b lang-python2 https://github.com/sozercan/copacetic.git
    cd copacetic
    
    echo -e "${YELLOW}Building Copa binary...${NC}"
    # Copa main.go is in the root directory
    go mod download
    go build -o ${COPA_BINARY} .
    
    if [ ! -f ${COPA_BINARY} ]; then
        echo -e "${RED}Failed to build Copa binary${NC}"
        exit 1
    fi
    
    cd ${KAITO_ROOT}
    rm -rf $TEMP_DIR
    
    echo -e "${GREEN}Copa built successfully from PR #1091${NC}"
else
    echo -e "${GREEN}Using existing Copa binary from PR #1091${NC}"
fi

${COPA_BINARY} version || echo "Copa version check failed - continuing anyway"

# Step 2: Build the dependencies target locally
echo -e "\n${GREEN}Step 2: Building TFS dependencies image locally...${NC}"
echo -e "${YELLOW}Building from ${DOCKERFILE_PATH} with target 'dependencies'${NC}"

docker build \
    --file ${DOCKERFILE_PATH} \
    --target dependencies \
    --tag ${FULL_IMAGE} \
    --build-arg MODEL_TYPE=tfs \
    --build-arg VERSION=${IMAGE_TAG} \
    .

echo -e "${GREEN}Image built successfully: ${FULL_IMAGE}${NC}"

# Display image size
IMAGE_SIZE=$(docker images ${FULL_IMAGE} --format "{{.Size}}")
echo -e "${BLUE}Image size: ${IMAGE_SIZE}${NC}"

# Step 3: Run initial Trivy scan for all vulnerabilities
echo -e "\n${GREEN}Step 3: Running Trivy scan for vulnerabilities...${NC}"

# OS vulnerabilities
echo -e "${YELLOW}Scanning for OS vulnerabilities:${NC}"
trivy image ${FULL_IMAGE} \
    --vuln-type os \
    --format table \
    --severity CRITICAL,HIGH,MEDIUM \
    --no-progress || echo "No OS vulnerabilities or scan failed"

# Library vulnerabilities
echo -e "\n${YELLOW}Scanning for library/app-level vulnerabilities:${NC}"
trivy image ${FULL_IMAGE} \
    --vuln-type library \
    --format table \
    --severity CRITICAL,HIGH,MEDIUM \
    --no-progress

# Generate JSON report for patching
echo -e "\n${GREEN}Generating JSON vulnerability report for patching...${NC}"
trivy image ${FULL_IMAGE} \
    --vuln-type library \
    --format json \
    --output trivy-report-library.json \
    --no-progress

# Display vulnerability summary
echo -e "\n${YELLOW}Vulnerability Summary:${NC}"
VULN_COUNT=$(cat trivy-report-library.json | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH")] | length' || echo 0)
echo -e "Found ${RED}${VULN_COUNT}${NC} CRITICAL/HIGH library vulnerabilities"

# Display some specific vulnerable packages
echo -e "\n${YELLOW}Sample vulnerable packages:${NC}"
cat trivy-report-library.json | jq -r '.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH") | "\(.PkgName) \(.InstalledVersion) -> \(.FixedVersion // "no fix") (\(.Severity))"' | head -10

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

# Step 5: Test different patch levels
echo -e "\n${GREEN}Step 5: Testing Copa patching with different library patch levels...${NC}"

PATCH_LEVELS=("patch" "minor" "major")

for LEVEL in "${PATCH_LEVELS[@]}"; do
    echo -e "\n${BLUE}Testing with --library-patch-level ${LEVEL}${NC}"
    
    PATCHED_IMAGE="${PATCHED_TAG}-${LEVEL}:${IMAGE_TAG}"
    
    export COPA_EXPERIMENTAL=1
    export BUILDKIT_HOST=docker-container://${BUILDKIT_CONTAINER}
    
    echo -e "${YELLOW}Running Copa patch...${NC}"
    ${COPA_BINARY} patch \
        --image ${FULL_IMAGE} \
        --report trivy-report-library.json \
        --tag ${PATCHED_IMAGE} \
        --pkg-types library \
        --library-patch-level ${LEVEL} \
        --addr docker-container://${BUILDKIT_CONTAINER} \
        --output copa-vex-${LEVEL}.json \
        --format openvex || {
            echo -e "${RED}Failed to patch with level: ${LEVEL}${NC}"
            continue
        }
    
    echo -e "${GREEN}Patching completed for level: ${LEVEL}${NC}"
    
    # Re-scan the patched image
    echo -e "${YELLOW}Re-scanning patched image (${LEVEL})...${NC}"
    trivy image ${PATCHED_IMAGE} \
        --vuln-type library \
        --format json \
        --output trivy-report-library-${LEVEL}-patched.json \
        --no-progress
    
    VULN_COUNT_AFTER=$(cat trivy-report-library-${LEVEL}-patched.json | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH")] | length' || echo 0)
    
    echo -e "${BLUE}Results for patch level '${LEVEL}':${NC}"
    echo -e "  Before: ${RED}${VULN_COUNT}${NC} vulnerabilities"
    echo -e "  After:  ${GREEN}${VULN_COUNT_AFTER}${NC} vulnerabilities"
    echo -e "  Reduced by: ${YELLOW}$((VULN_COUNT - VULN_COUNT_AFTER))${NC}"
    
    # Check VEX document
    if [ -f copa-vex-${LEVEL}.json ]; then
        VEX_COUNT=$(jq '.statements | length' copa-vex-${LEVEL}.json)
        echo -e "  VEX statements: ${BLUE}${VEX_COUNT}${NC}"
    fi
    
    # Show sample of what was patched
    echo -e "${YELLOW}Sample patched packages:${NC}"
    docker run --rm ${PATCHED_IMAGE} pip list | grep -E "(torch|transformers|numpy|fastapi|pydantic)" || true
done

# Step 6: Comparison summary
echo -e "\n${GREEN}Step 6: Final Comparison Summary${NC}"
echo -e "${BLUE}=== Patching Results Summary ===${NC}"

for LEVEL in "${PATCH_LEVELS[@]}"; do
    if [ -f trivy-report-library-${LEVEL}-patched.json ]; then
        VULN_AFTER=$(cat trivy-report-library-${LEVEL}-patched.json | jq '[.Results[].Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH")] | length' || echo 0)
        echo -e "Patch level '${LEVEL}':"
        echo -e "  Original: ${RED}${VULN_COUNT}${NC} → Patched: ${GREEN}${VULN_AFTER}${NC} (Reduced by ${YELLOW}$((VULN_COUNT - VULN_AFTER))${NC})"
    fi
done

# Step 7: Test specific Python packages
echo -e "\n${GREEN}Step 7: Testing Python package versions in best patched image...${NC}"

# Find the best patched image (usually 'major' has most fixes)
BEST_IMAGE="${PATCHED_TAG}-major:${IMAGE_TAG}"
if docker images -q ${BEST_IMAGE} > /dev/null 2>&1; then
    echo -e "${YELLOW}Checking package versions in ${BEST_IMAGE}:${NC}"
    docker run --rm ${BEST_IMAGE} python -c "
import sys
print(f'Python version: {sys.version}')

packages = [
    'torch', 'transformers', 'numpy', 'fastapi', 'pydantic',
    'vllm', 'accelerate', 'uvicorn', 'sentencepiece', 'jinja2'
]

for pkg in packages:
    try:
        module = __import__(pkg)
        version = getattr(module, '__version__', 'unknown')
        print(f'{pkg}: {version}')
    except ImportError:
        print(f'{pkg}: not found')
    except Exception as e:
        print(f'{pkg}: error - {e}')
"
fi

echo -e "\n${GREEN}=== Test Complete ===${NC}"
echo -e "${BLUE}Images created:${NC}"
docker images | grep ${BASE_IMAGE_NAME} | head -5
echo -e "\n${YELLOW}To use a patched image in your workflow, update your Dockerfile or compose file to use one of the patched images above.${NC}"