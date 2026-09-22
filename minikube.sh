#!/usr/bin/env bash
set -euo pipefail

# Configuration Variables
KUBERNETES_VERSION="v1.35.8"
SERVICE_CIDR="10.43.0.0/16"
POD_CIDR="10.244.0.0/16"
ZSCALER_CERT="${HOME}/.minikube/certs/zscaler.crt"

echo "=== Step 1: Cleaning up existing Minikube cluster ==="
minikube delete || true

echo "=== Step 2: Provisioning Minikube Cluster with Custom CIDRs & Zscaler CA ==="
if [ ! -f "${ZSCALER_CERT}" ]; then
  echo "Error: Zscaler CA bundle not found at ${ZSCALER_CERT}"
  exit 1
fi

# Mount into /usr/share/ca-certificates/custom/ to avoid /etc/ssl/certs mount collision
minikube start \
  --driver=podman \
  --container-runtime=docker \
  --cpus=max \
  --memory=max \
  --kubernetes-version="${KUBERNETES_VERSION}" \
  --cni=false \
  --embed-certs \
  --service-cluster-ip-range="${SERVICE_CIDR}" \
  --extra-config=kubeadm.pod-network-cidr="${POD_CIDR}" \
  --mount \
  --mount-string="${ZSCALER_CERT}:/usr/share/ca-certificates/custom/zscaler.crt"

echo "=== Step 3: Updating Minikube Node Certificate Trust Store ==="
minikube ssh "
  sudo cp /usr/share/ca-certificates/custom/zscaler.crt /usr/local/share/ca-certificates/zscaler.crt
  sudo update-ca-certificates --fresh || true
"

echo "=== Step 4: Removing Default CoreDNS Resources ==="
kubectl delete deployment coredns -n kube-system --ignore-not-found
kubectl delete service kube-dns -n kube-system --ignore-not-found
kubectl delete serviceaccount coredns -n kube-system --ignore-not-found
kubectl delete configmap coredns -n kube-system --ignore-not-found

echo "=== Step 5: Bootstrapping Applications (Namespaces, Cilium, CoreDNS, ArgoCD) ==="
just bootstrap apps

echo "=== Step 6: Patching ArgoCD Repo Server ==="
kubectl create configmap argocd-tls-certs-cm \
  -n argo-system \
  --from-file=zscaler.crt="${ZSCALER_CERT}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl patch deployment argocd-repo-server -n argo-system --type strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "volumes": [
          {
            "name": "zscaler-ca-vol",
            "configMap": {
              "name": "argocd-tls-certs-cm"
            }
          }
        ],
        "containers": [
          {
            "name": "repo-server",
            "env": [
              {
                "name": "SSL_CERT_FILE",
                "value": "/etc/ssl/certs/zscaler.crt"
              }
            ],
            "volumeMounts": [
              {
                "name": "zscaler-ca-vol",
                "mountPath": "/etc/ssl/certs/zscaler.crt",
                "subPath": "zscaler.crt"
              }
            ]
          }
        ]
      }
    }
  }
}'

echo "=== Step 8: Patching Cert-Manager Controller ==="
kubectl create configmap cert-manager-zscaler-ca \
  -n cert-manager \
  --from-file=zscaler.crt="${ZSCALER_CERT}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl patch deployment cert-manager -n cert-manager --type strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "volumes": [
          {
            "name": "zscaler-ca-vol",
            "configMap": {
              "name": "cert-manager-zscaler-ca"
            }
          }
        ],
        "containers": [
          {
            "name": "cert-manager-controller",
            "env": [
              {
                "name": "SSL_CERT_FILE",
                "value": "/etc/ssl/certs/zscaler.crt"
              }
            ],
            "volumeMounts": [
              {
                "name": "zscaler-ca-vol",
                "mountPath": "/etc/ssl/certs/zscaler.crt",
                "subPath": "zscaler.crt"
              }
            ]
          }
        ]
      }
    }
  }
}'

echo "=== Step 9: Restarting Deployments ==="
kubectl rollout restart deployment argocd-repo-server -n argo-system
kubectl rollout restart deployment cert-manager -n cert-manager

echo "=== Setup complete! ==="
