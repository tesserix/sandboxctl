package chartgen

// Chart file templates. These are Go text/templates with `[[ ]]`
// delimiters so the Helm `{{ }}` syntax passes through verbatim — the
// same trick Helm's own starter-pack tooling uses. Substitution happens
// once at scaffold time (chart name, image, port); everything else is
// decided at helm-render time via values, keeping the generated chart
// fully portable off-sandbox.

const chartYamlTmpl = `apiVersion: v2
name: [[.Name]]
description: [[.Description]]
type: application
version: 0.1.0
appVersion: "0.1.0"
`

// valuesYamlTmpl deliberately uses the { image: { repository, tag } }
// shape sandboxctl's deploy-time pin resolver already understands, so a
// scaffolded chart needs zero special-casing there.
const valuesYamlTmpl = `replicaCount: 1

image:
  repository: [[.ImageRepo]]
  tag: latest
  # Kargo promotions pin the exact build by digest; empty means "just
  # the tag". A digest always wins over the tag when both are set.
  digest: ""
  pullPolicy: IfNotPresent

nameOverride: ""
fullnameOverride: ""
[[if .Port]]
service:
  type: ClusterIP
  port: [[.Port]]
[[end]]
[[if .SecretName]]# Secret providing the app's environment (template generated at
# k8s/secrets.example.yaml; Reloader rolls the pods when it changes).
envFromSecret: [[.SecretName]]
[[else]]# Name a Secret here to inject it as environment via envFrom.
envFromSecret: ""
[[end]]
[[if .ConfigVars]]# Non-secret configuration referenced by the app — add entries as
# {name: ..., value: ...}:
[[range .ConfigVars]]#   [[.]]
[[end]][[end]]env: []

serviceAccount:
  create: true
  name: ""

ingress:
  # Kubernetes Ingress stays off: in the sandbox, routing is the
  # VirtualService below; off-sandbox, enable whichever you use.
  enabled: false

sandbox:
  # The chart carries its own Istio VirtualService so GitOps owns the
  # app's URL end to end — no hand-written routing per app. Disabled
  # here so the chart stays portable; values-sandbox.yaml turns it on
  # with the sandbox host + gateway.
  virtualService:
    enabled: false
    host: ""
    gateway: ""

resources: {}

nodeSelector: {}
tolerations: []
affinity: {}
`

const valuesSandboxTmpl = `# Sandbox-flavoured values — picked up automatically by 'sandboxctl deploy'.
# The image repository points at the in-cluster registry; deploy re-pins
# the tag to whatever 'sandboxctl build' just pushed, and Kargo's dev
# Stage writes image.digest here on promotion.
image:
  repository: [[.ImageRepo]]
  tag: latest
  digest: ""
[[if .Port]]
sandbox:
  virtualService:
    enabled: true
    host: [[.Host]]
    gateway: [[.Gateway]]
[[end]]`

const helpersTmpl = `{{- define "[[.Name]].name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "[[.Name]].fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "[[.Name]].labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{ include "[[.Name]].selectorLabels" . }}
{{- end -}}

{{- define "[[.Name]].selectorLabels" -}}
app.kubernetes.io/name: {{ include "[[.Name]].name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "[[.Name]].serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "[[.Name]].fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
`

// deploymentTmpl: the reloader annotation makes secret edits roll pods
// (Reloader ships with every sandbox). Ports + readiness render only
// when the chart exposes a service port, so worker charts stay portless.
const deploymentTmpl = `apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "[[.Name]].fullname" . }}
  labels:
    {{- include "[[.Name]].labels" . | nindent 4 }}
  annotations:
    reloader.stakater.com/auto: "true"
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "[[.Name]].selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "[[.Name]].selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "[[.Name]].serviceAccountName" . }}
      containers:
        - name: [[.Name]]
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}{{- with .Values.image.digest }}@{{ . }}{{- end }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          {{- if .Values.envFromSecret }}
          envFrom:
            - secretRef:
                name: {{ .Values.envFromSecret }}
          {{- end }}
          {{- with .Values.env }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.service }}
          ports:
            - name: http
              containerPort: {{ .port }}
              protocol: TCP
          readinessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 3
            periodSeconds: 5
          {{- end }}
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
`

const serviceTmpl = `{{- if .Values.service }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "[[.Name]].fullname" . }}
  labels:
    {{- include "[[.Name]].labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type | default "ClusterIP" }}
  selector:
    {{- include "[[.Name]].selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
{{- end }}
`

// virtualServiceTmpl renders only when the chart exposes a Service AND
// the sandbox values enable it — so default renders stay portable and
// worker charts stay routeless. The chained `and` is nil-safe because
// template and/or short-circuit (and helm 4's Values type rejects
// sprig's dig, so this is also the portable spelling).
const virtualServiceTmpl = `{{- if and .Values.service .Values.sandbox .Values.sandbox.virtualService .Values.sandbox.virtualService.enabled }}
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: {{ include "[[.Name]].fullname" . }}
  labels:
    {{- include "[[.Name]].labels" . | nindent 4 }}
spec:
  hosts:
    - {{ .Values.sandbox.virtualService.host | quote }}
  gateways:
    - {{ .Values.sandbox.virtualService.gateway | quote }}
  http:
    - route:
        - destination:
            host: {{ include "[[.Name]].fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local
            port:
              number: {{ .Values.service.port }}
{{- end }}
`

// Umbrella chart templates (monorepos with 2+ charted apps). The
// umbrella is the "install the whole stack with one helm command"
// artifact; the sandbox itself keeps deploying per-app charts with
// per-app pipelines and URLs, and recognizes the umbrella by its
// annotation so it is never double-deployed.
const umbrellaChartYamlTmpl = `# Umbrella chart — installs every app in this repo together:
#
#   sandboxctl deploy --umbrella          # whole stack as one Argo app
#   sandboxctl install                    # same stack via plain helm (no GitOps)
#
# or standalone, anywhere helm runs:
#
#   helm dependency build --skip-refresh [[.Dir]]
#   helm install [[.Name]] [[.Dir]] -f [[.Dir]]/values-sandbox.yaml
#
# sandboxctl's default deploy uses the per-app charts + Kargo pipelines
# and recognizes this chart by the annotation below, so it is never
# double-deployed.
apiVersion: v2
name: [[.Name]]
description: Umbrella chart installing every app in this repo
type: application
version: 0.1.0
annotations:
  sandboxctl.io/umbrella: "true"
dependencies:
[[- range .Apps]]
  - name: [[.Name]]
    version: "0.1.0"
    repository: file://../charts/[[.Name]]
    condition: [[.Name]].enabled
[[- end]]
`

const umbrellaValuesTmpl = `# Umbrella values: toggle whole apps on/off; anything else nests under
# the app's name and flows into that subchart (e.g. api.replicaCount).
[[- range .Apps]]
[[.Name]]:
  enabled: true
[[- end]]
`

const umbrellaValuesSandboxTmpl = `# Sandbox flavour for umbrella installs — used by both
# 'sandboxctl deploy --umbrella' and standalone 'helm install -f'.
# (The default per-app deploy uses each chart's own values-sandbox.)
[[- range .Apps]]
[[.Name]]:
  image:
    repository: [[$.Registry]]/[[.Name]]
    tag: latest
    digest: ""
[[- if .Port]]
  sandbox:
    virtualService:
      enabled: true
      host: [[.Name]].[[$.Domain]]
      gateway: [[$.Gateway]]
[[- end]]
[[- end]]
`

const serviceAccountTmpl = `{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "[[.Name]].serviceAccountName" . }}
  labels:
    {{- include "[[.Name]].labels" . | nindent 4 }}
{{- end }}
`
