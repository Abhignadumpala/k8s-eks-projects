{{/* Common labels added to every object */}}
{{- define "three-tier.labels" -}}
app.kubernetes.io/part-of: three-tier
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* imagePullSecrets block (only if set) */}}
{{- define "three-tier.pullSecret" -}}
{{- if .Values.imagePullSecret }}
imagePullSecrets:
  - name: {{ .Values.imagePullSecret }}
{{- end }}
{{- end -}}
