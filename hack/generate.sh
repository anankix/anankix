#!/usr/bin/env bash

# Copyright 2025 The Anankix Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ==============================================================================
# generate.sh
#
# This script is responsible for all code and manifest generation tasks,
# such as generating deepcopy code, CRDs, RBAC roles, and Dockerfiles.
# ==============================================================================

# Source the common prelude script to set up the environment and helpers.
# shellcheck source=lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"

# ==============================================================================
# Consumed Environment Variables (from build/config.mk)
# ------------------------------------------------------------------------------
#   - CONTROLLER_GEN:       The path to the controller-gen binary.
#   - BOILERPLATE_FILE:     The path to the boilerplate header file for Go code.
#   - GOLANG_VERSION:       The Go version to be used in the Dockerfile.
# ==============================================================================

# Provide default values for consumed environment variables for robustness.
readonly CONTROLLER_GEN="${CONTROLLER_GEN:-${PROJECT_ROOT}/bin/controller-gen}"
readonly BOILERPLATE_FILE="${BOILERPLATE_FILE:-${PROJECT_ROOT}/hack/boilerplate/boilerplate.go.txt}"
readonly GOLANG_VERSION="${GOLANG_VERSION:-1.25}"

# ---
# Task Functions
# ---

# generate_deepcopy generates deepcopy methods for all API types.
generate_deepcopy() {
    info "Generating deepcopy code (zz_generated.deepcopy.go)..."

    if ! [ -f "${BOILERPLATE_FILE}" ]; then
        error "Boilerplate file not found at ${BOILERPLATE_FILE}"
    fi

    # The prelude.sh script already cds to PROJECT_ROOT, so we can run directly.
    # Scoping paths to ./api/... is more efficient than the default ./...
    "${CONTROLLER_GEN}" \
        object:headerFile="${BOILERPLATE_FILE}" \
        paths="./api/..."
}

# generate_manifests generates CRD and RBAC YAMLs from source code markers.
generate_manifests() {
    info "Generating manifests (CRDs, RBAC, Webhooks)..."
    
    # Scoping paths is more efficient and prevents accidental scanning of unrelated code.
    "${CONTROLLER_GEN}" \
        rbac:roleName=manager-role \
        crd \
        webhook \
        paths="./api/...;./internal/controller/..." \
        output:crd:artifacts:config=config/crd/bases
}

# generate_dockerfile_for_component generates a Dockerfile for a specific component.
# It uses an embedded heredoc as a template.
generate_dockerfile_for_component() {
    local component_name="$1"
    info "Generating Dockerfile for component '${component_name}'..."
    
    local output_dir="${PROJECT_ROOT}/_output/images/${component_name}"
    local output_file="${output_dir}/Dockerfile"

    # Ensure the output directory exists.
    mkdir -p "${output_dir}"

    # Use a Heredoc to write the templated Dockerfile.
    # Shell variables like ${GOLANG_VERSION} are automatically expanded.
    cat > "${output_file}" <<EOF
# Copyright $(date +%Y) The Anankix Authors.
# DO NOT EDIT. THIS FILE IS AUTO-GENERATED.

# --- Build Stage ---
# Use the official Golang image to create a build artifact.
# https://hub.docker.com/_/golang
FROM golang:${GOLANG_VERSION}-alpine AS builder

# Arguments for cross-platform builds.
ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace

# Copy Go module files and download dependencies first to leverage Docker cache.
# This layer is only invalidated when go.mod or go.sum changes.
COPY go.mod go.sum .
RUN go mod download

# Copy only the necessary Go source code.
# This prevents cache busting when non-source files (e.g., README.md) change.
COPY api/ api/
COPY internal/ internal/
COPY cmd/ cmd/
COPY pkg/ pkg/

# Build the binary for the specific component.
# The binary is named after the component for clarity.
RUN CGO_ENABLED=0 GOOS=\${TARGETOS:-linux} GOARCH=\${TARGETARCH:-amd64} go build \
    -a -o ${component_name} ./cmd/${component_name}/main.go


# --- Final Stage ---
# Use a distroless static image for a tiny and secure final image.
# https://github.com/GoogleContainerTools/distroless
FROM gcr.io/distroless/static:nonroot

# Copy the compiled binary from the builder stage.
COPY --from=builder /workspace/${component_name} .

# Run as a non-root user for security.
USER 65532:65532

# Set the entrypoint to our component's binary.
ENTRYPOINT ["/${component_name}"]
EOF
    echo "    Dockerfile for '${component_name}' generated at ${output_file}"
}

# ---
# Main Dispatcher
# ---
main() {
    if [[ $# -eq 0 ]]; then
        error "No target specified for generate.sh. Must be one of: deepcopy, manifests, dockerfile."
    fi

    local target="$1"
    local args=("${@:2}")

    info "Executing generate target: ${target}"

    case "$target" in
        deepcopy)
            generate_deepcopy
            ;;
        manifests)
            generate_manifests
            ;;
        dockerfile)
            _require_one_component "$target" "$@"
            generate_dockerfile_for_component "${args[0]}"
            ;;
        *)
            error "Unknown target '${target}' for generate.sh."
            ;;
    esac
}

# ---
# Script Entrypoint
# ---
main "$@"

echo -e "\033[32m✅ Script 'generate.sh' completed its task successfully.\033[0m"