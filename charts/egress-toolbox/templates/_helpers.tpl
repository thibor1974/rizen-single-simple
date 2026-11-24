{{- define "egress-toolbox.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "egress-toolbox.fullname" -}}
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

{{- define "egress-toolbox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "egress-toolbox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "egress-toolbox.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "egress-toolbox.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Image: the internal registry when built in-cluster, otherwise image.repository. */}}
{{- define "egress-toolbox.image" -}}
{{- if .Values.build.enabled }}
{{- printf "image-registry.openshift-image-registry.svc:5000/%s/%s:%s" .Release.Namespace (include "egress-toolbox.fullname" .) .Values.image.tag }}
{{- else }}
{{- $repo := required "image.repository is required when build.enabled=false" .Values.image.repository }}
{{- printf "%s:%s" $repo .Values.image.tag }}
{{- end }}
{{- end }}
