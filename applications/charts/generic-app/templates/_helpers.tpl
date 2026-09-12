{{/*
Expand the name of the chart.
*/}}
{{- define "generic-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "generic-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "generic-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "generic-app.labels" -}}
helm.sh/chart: {{ include "generic-app.chart" . }}
{{ include "generic-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "generic-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "generic-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "generic-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "generic-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Render env list entries (without the leading "env:" key).
Params: root (top-level context), env (list of EnvVar), secretEnv (dict with secretName and vars)
*/}}
{{- define "generic-app.envEntries" -}}
{{- $root := .root -}}
{{- with .env }}
{{ toYaml . }}
{{- end }}
{{- with .secretEnv }}
{{- $defaultSecret := .secretName | default $root.Values.secretEnv.secretName }}
{{- range .vars }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .secretName | default $defaultSecret | required (printf "secretEnv.secretName (or secretName on var %q) is required" .name) }}
      key: {{ .key | default .name }}
      {{- if hasKey . "optional" }}
      optional: {{ .optional }}
      {{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Labels for job/cronjob pods. Deliberately does NOT match the Deployment/Service
selector so job pods never receive Service traffic.
*/}}
{{- define "generic-app.jobPodLabels" -}}
app.kubernetes.io/name: {{ include "generic-app.name" .root }}-{{ .job.name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Pod spec shared by CronJobs and hook Jobs.
Params: root (top-level context), job (one entry from cronjobs/preHookJobs/postHookJobs)
*/}}
{{- define "generic-app.jobPodSpec" -}}
{{- $root := .root -}}
{{- $job := .job -}}
{{- $image := $job.image | default (dict) -}}
{{- $jobSecretEnv := $job.secretEnv | default (dict) -}}
{{- $inherit := true -}}
{{- if hasKey $job "inheritEnv" }}{{ $inherit = $job.inheritEnv }}{{ end -}}
{{- $rootHasEnv := or $root.Values.env $root.Values.secretEnv.vars -}}
{{- $jobHasEnv := or $job.env $jobSecretEnv.vars -}}
{{- if $root.Values.imagePullSecrets }}
imagePullSecrets:
  {{- include "generic-app.imagePullSecrets" $root | trim | nindent 2 }}
{{- end }}
serviceAccountName: {{ include "generic-app.serviceAccountName" $root }}
{{- with $root.Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
restartPolicy: {{ $job.restartPolicy | default "OnFailure" }}
containers:
  - name: {{ $job.name }}
    {{- with $root.Values.securityContext }}
    securityContext:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    image: "{{ $image.repository | default $root.Values.image.repository }}:{{ $image.tag | default ($root.Values.image.tag | default $root.Chart.AppVersion) }}"
    imagePullPolicy: {{ $image.pullPolicy | default $root.Values.image.pullPolicy }}
    {{- with $job.command }}
    command:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with $job.args }}
    args:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if or (and $inherit $rootHasEnv) $jobHasEnv }}
    env:
      {{- if $inherit }}
      {{- with (include "generic-app.envEntries" (dict "root" $root "env" $root.Values.env "secretEnv" $root.Values.secretEnv) | trim) }}{{ . | nindent 6 }}{{- end }}
      {{- end }}
      {{- with (include "generic-app.envEntries" (dict "root" $root "env" $job.env "secretEnv" $jobSecretEnv) | trim) }}{{ . | nindent 6 }}{{- end }}
    {{- end }}
    {{- $envFrom := concat (ternary $root.Values.envFrom (list) $inherit) ($job.envFrom | default (list)) }}
    {{- with $envFrom }}
    envFrom:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with $job.resources }}
    resources:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with $job.volumeMounts }}
    volumeMounts:
      {{- toYaml . | nindent 6 }}
    {{- end }}
{{- with $job.volumes }}
volumes:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Job spec fields shared by CronJob jobTemplate and hook Jobs (rendered at the "spec:" level).
Params: root, job
*/}}
{{- define "generic-app.jobSpecFields" -}}
{{- if hasKey .job "backoffLimit" }}
backoffLimit: {{ .job.backoffLimit }}
{{- end }}
{{- with .job.activeDeadlineSeconds }}
activeDeadlineSeconds: {{ . }}
{{- end }}
{{- if hasKey .job "ttlSecondsAfterFinished" }}
ttlSecondsAfterFinished: {{ .job.ttlSecondsAfterFinished }}
{{- end }}
{{- end }}

{{/*
Render a hook Job.
Params: root, job, hook (helm hook string, e.g. "pre-install,pre-upgrade"), component
*/}}
{{- define "generic-app.hookJob" -}}
{{- $root := .root -}}
{{- $job := .job -}}
{{- if not $job.command }}{{ fail (printf "%s job %q: command is required" .component $job.name) }}{{ end -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "generic-app.fullname" $root }}-{{ $job.name }}
  labels:
    {{- include "generic-app.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
  annotations:
    "helm.sh/hook": {{ $job.hook | default .hook | quote }}
    "helm.sh/hook-weight": {{ $job.weight | default 0 | quote }}
    "helm.sh/hook-delete-policy": {{ $job.deletePolicy | default "before-hook-creation,hook-succeeded" | quote }}
    {{- with $job.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with (include "generic-app.jobSpecFields" (dict "root" $root "job" $job) | trim) }}{{ . | nindent 2 }}{{- end }}
  template:
    metadata:
      labels:
        {{- include "generic-app.jobPodLabels" (dict "root" $root "job" $job "component" .component) | nindent 8 }}
      {{- with $job.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      {{- with (include "generic-app.jobPodSpec" (dict "root" $root "job" $job) | trim) }}{{ . | nindent 6 }}{{- end }}
{{- end }}

{{/*
imagePullSecrets entries. Accepts either plain strings ("my-secret") or
objects ({name: my-secret}) so values files can use whichever is convenient.
*/}}
{{- define "generic-app.imagePullSecrets" -}}
{{- range .Values.imagePullSecrets }}
- name: {{ if kindIs "string" . }}{{ . }}{{ else }}{{ .name }}{{ end }}
{{- end }}
{{- end }}
