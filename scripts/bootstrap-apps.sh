#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Talos requires the nodes to be 'Ready=False' before applying resources
function wait_for_nodes() {
    log debug "Waiting for nodes to be available"

    # Skip waiting if all nodes are 'Ready=True'
    if kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        log info "Nodes are available and ready, skipping wait for nodes"
        return
    fi

    # Wait for all nodes to be 'Ready=False'
    until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
        log info "Nodes are not available, waiting for nodes to be available. Retrying in 10 seconds..."
        sleep 10
    done
}

# Namespaces to be applied before the SOPS secrets are installed
function apply_namespaces() {
    log debug "Applying namespaces"

    local -r apps_dir="${ROOT_DIR}/kubernetes/apps"

    if [[ ! -d "${apps_dir}" ]]; then
        log error "Directory does not exist" "directory=${apps_dir}"
    fi

    for app in "${apps_dir}"/*/; do
        namespace=$(basename "${app}")

        # Check if the namespace resources are up-to-date
        if kubectl get namespace "${namespace}" &>/dev/null; then
            log info "Namespace resource is up-to-date" "resource=${namespace}"
            continue
        fi

        # Apply the namespace resources
        if kubectl create namespace "${namespace}" --dry-run=client --output=yaml \
            | kubectl apply --server-side --filename - &>/dev/null;
        then
            log info "Namespace resource applied" "resource=${namespace}"
        else
            log error "Failed to apply namespace resource" "resource=${namespace}"
        fi
    done
}

# SOPS secrets to be applied before the helmfile charts are installed
function apply_sops_secrets() {
    log debug "Applying secrets"

    local -r secrets=(
        "${ROOT_DIR}/kubernetes/components/common/helm-secrets-private-keys.sops.yaml"
    )

    for secret in "${secrets[@]}"; do
        if [ ! -f "${secret}" ]; then
            log warn "File does not exist" "file=${secret}"
            continue
        fi

        # Check if the secret resources are up-to-date
        if sops exec-file "${secret}" "kubectl --namespace argo-system diff --filename {}" &>/dev/null; then
            log info "Secret resource is up-to-date" "resource=$(basename "${secret}" ".sops.yaml")"
            continue
        fi

        # Apply secret resources
        if sops exec-file "${secret}" "kubectl --namespace argo-system apply --server-side --filename {}" &>/dev/null; then
            log info "Secret resource applied successfully" "resource=$(basename "${secret}" ".sops.yaml")"
        else
            log error "Failed to apply secret resource" "resource=$(basename "${secret}" ".sops.yaml")"
        fi
    done
}

# CRDs to be applied before the helmfile charts are installed
function apply_crds() {
    log debug "Applying CRDs"

    local -r crds=(
        # renovate: datasource=github-releases depName=prometheus-operator/prometheus-operator
        https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.81.0/stripped-down-crds.yaml
        # renovate: datasource=github-releases depName=kubernetes-sigs/external-dns
        https://raw.githubusercontent.com/kubernetes-sigs/external-dns/refs/tags/v0.16.1/docs/sources/crd/crd-manifest.yaml
    )

    for crd in "${crds[@]}"; do
        if kubectl diff --filename "${crd}" &>/dev/null; then
            log info "CRDs are up-to-date" "crd=${crd}"
            continue
        fi
        if kubectl apply --server-side --filename "${crd}" &>/dev/null; then
            log info "CRDs applied" "crd=${crd}"
        else
            log error "Failed to apply CRDs" "crd=${crd}"
        fi
    done
}

# Apply Helm releases using helmfile
function apply_helm_releases() {
    log debug "Applying Helm releases with helmfile"

    local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log error "File does not exist" "file=${helmfile_file}"
    fi

    if ! helmfile --file "${helmfile_file}" apply --hide-notes --skip-diff-on-install --suppress-diff --suppress-secrets; then
        log error "Failed to apply Helm releases"
    fi

    log info "Helm releases applied successfully"
}

# Apply Argo Cluster Bootstrapping
function apply_argo_bootstrapping() {
    log debug "Applying Argo Bootstrapping"

    local -r bootstrappingmaps=(
        "${ROOT_DIR}/kubernetes/components/common/apps.yaml"
        "${ROOT_DIR}/kubernetes/components/common/repositories.yaml"
        "${ROOT_DIR}/kubernetes/components/common/settings.yaml"
    )

    for bootstrappingmap in "${bootstrappingmaps[@]}"; do
        if [ ! -f "${bootstrappingmap}" ]; then
            log warn "File does not exist" file "${bootstrappingmap}"
            continue
        fi

        # Check if the bootstrappingmap resources are up-to-date
        if kubectl --namespace argo-system diff --filename "${bootstrappingmap}" &>/dev/null; then
            log info "bootstrappingmap resource is up-to-date" "resource=$(basename "${bootstrappingmap}" ".yaml")"
            continue
        fi

        # Apply bootstrappingmap resources
        if kubectl --namespace argo-system apply --server-side --filename "${bootstrappingmap}" &>/dev/null; then
            log info "bootstrappingmap resource applied successfully" "resource=$(basename "${bootstrappingmap}" ".yaml")"
        else
            log error "Failed to apply bootstrappingmap resource" "resource=$(basename "${bootstrappingmap}" ".yaml")"
        fi
    done
}

function main() {
    check_cli helmfile kubectl kustomize sops talhelper yq

    # Apply resources and Helm releases
    wait_for_nodes
    apply_namespaces
    apply_sops_secrets
    apply_crds
    apply_helm_releases
    apply_argo_bootstrapping

    log info "Congrats! The cluster is bootstrapped and Argo is syncing the Git repository"
}

main "$@"
