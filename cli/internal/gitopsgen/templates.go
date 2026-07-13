package gitopsgen

// GitOps manifest templates. Go-template delimiters are [[ ]] so both
// Helm-style {{ }} and Kargo's ${{ }} expressions pass through
// untouched. Everything generated here is plain, portable YAML — the
// in-cluster endpoints sit in commented, easily-swapped spots so the
// same files can point at a real Argo CD + Kargo install later.

const projectTmpl = `# Kargo project for [[.App]]. The project's namespace ([[.Project]])
# holds the Warehouse, Stages, and the git credentials Secret that
# 'sandboxctl deploy' creates. Named "<app>-kargo" so it can never
# collide with the app's own deployment namespaces.
apiVersion: kargo.akuity.io/v1alpha1
kind: Project
metadata:
  name: [[.Project]]
`

const warehouseTmpl = `# Watches the sandbox registry for new builds of [[.App]].
# 'sandboxctl build' pushes mutable :latest tags; the Digest strategy
# turns every push into new Freight by tracking what the tag points at.
# The registry is plain HTTP in-cluster — image subscriptions handle
# that with TLS verification off (chart subscriptions would not).
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: [[.App]]
  namespace: [[.Project]]
spec:
  subscriptions:
    - image:
        repoURL: [[.ImageRepo]]
        imageSelectionStrategy: Digest
        constraint: [[.ImageTag]]
        insecureSkipTLSVerify: true
        discoveryLimit: 5
`

const stagesTmpl = `# Promotion pipeline for [[.App]]: dev takes Freight straight from the
# Warehouse; staging takes what dev has proven. Each promotion commits
# the image digest into the stage's values file in the chart's Gitea
# repo, pushes, and points Argo CD at the new revision — GitOps end to
# end, no imperative deploys.
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: dev
  namespace: [[.Project]]
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: [[.App]]
      sources:
        direct: true
  promotionTemplate:
    spec:
      steps:
        - uses: git-clone
          config:
            repoURL: [[.GitRepo]]
            checkout:
              - branch: main
                path: ./repo
        - uses: yaml-update
          as: update
          config:
            path: ./repo/[[.DevValuesFile]]
            updates:
              - key: image.digest
                value: ${{ imageFrom("[[.ImageRepo]]").Digest }}
        - uses: git-commit
          as: commit
          config:
            path: ./repo
            message: 'kargo: promote dev to ${{ imageFrom("[[.ImageRepo]]").Digest }}'
        - uses: git-push
          config:
            path: ./repo
        - uses: argocd-update
          config:
            apps:
              - name: [[.App]]
                sources:
                  - repoURL: [[.GitRepo]]
                    desiredRevision: ${{ task.outputs.commit.commit }}
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: staging
  namespace: [[.Project]]
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: [[.App]]
      sources:
        stages:
          - dev
  promotionTemplate:
    spec:
      steps:
        - uses: git-clone
          config:
            repoURL: [[.GitRepo]]
            checkout:
              - branch: main
                path: ./repo
        - uses: yaml-update
          as: update
          config:
            path: ./repo/values-staging.yaml
            updates:
              - key: image.digest
                value: ${{ imageFrom("[[.ImageRepo]]").Digest }}
        - uses: git-commit
          as: commit
          config:
            path: ./repo
            message: 'kargo: promote staging to ${{ imageFrom("[[.ImageRepo]]").Digest }}'
        - uses: git-push
          config:
            path: ./repo
        - uses: argocd-update
          config:
            apps:
              - name: [[.App]]-staging
                sources:
                  - repoURL: [[.GitRepo]]
                    desiredRevision: ${{ task.outputs.commit.commit }}
`

const applicationTmpl = `# Argo CD Applications, one per stage. The authorized-stage annotation
# is Kargo's permission to update the app on promotion. The dev app
# keeps the plain "[[.App]]" name so status, routing, and undeploy keep
# working exactly as before.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: [[.App]]
  namespace: argocd
  annotations:
    kargo.akuity.io/authorized-stage: "[[.Project]]:dev"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: [[.GitRepo]]
    targetRevision: main
    path: .
    helm:
      valueFiles: ["[[.DevValuesFile]]"]
  destination:
    server: https://kubernetes.default.svc
    namespace: [[.App]]
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: [[.App]]-staging
  namespace: argocd
  annotations:
    kargo.akuity.io/authorized-stage: "[[.Project]]:staging"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: [[.GitRepo]]
    targetRevision: main
    path: .
    helm:
      valueFiles: ["values-staging.yaml"]
  destination:
    server: https://kubernetes.default.svc
    namespace: [[.App]]-staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
`

const valuesStagingTmpl = `# Staging values — the staging Stage's promotions write image.digest
# here; everything else inherits the chart's values.yaml defaults.
image:
  repository: [[.ImageRepo]]
  tag: [[.ImageTag]]
  digest: ""
`
