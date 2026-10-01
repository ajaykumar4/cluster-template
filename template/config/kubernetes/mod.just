set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

[doc('Force Argo CD to pull in changes from your Git repository')]
[group('kube')]
reconcile:
    argocd app get projects --refresh --hard && argocd app sync projects
    argocd app get repositories --refresh --hard && argocd app sync repositories
    argocd app get apps --refresh --hard && argocd app sync apps
