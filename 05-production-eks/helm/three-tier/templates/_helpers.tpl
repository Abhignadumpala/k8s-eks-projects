{{/* Common labels added to every object */}}
{{- define "three-tier.labels" -}}
app.kubernetes.io/part-of: three-tier
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Full image name: <registry>/<repository>:<tag>. Fails early if the registry is missing. */}}
{{- define "three-tier.image" -}}
{{- $registry := required "Set global.registry (your ECR registry) with --set" .root.Values.global.registry -}}
{{ $registry }}/{{ .image.repository }}:{{ .image.tag }}
{{- end -}}

{{/* Run on the app node group: nodeSelector + toleration for the taint */}}
{{- define "three-tier.scheduling" -}}
nodeSelector:
  {{- toYaml .Values.scheduling.nodeSelector | nindent 2 }}
tolerations:
  {{- toYaml .Values.scheduling.tolerations | nindent 2 }}
{{- end -}}

{{/* Spread Pods of one app across AZs and nodes (Step 09 explains it) */}}
{{- define "three-tier.spread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: {{ .app }}
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: {{ .app }}
{{- end -}}

{{/* Pod-level security (Step 05 explains every line) */}}
{{- define "three-tier.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: {{ .uid }}
  runAsGroup: {{ .uid }}
  fsGroup: {{ .uid }}
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{/* Container-level security (Step 05 explains every line) */}}
{{- define "three-tier.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
{{- end -}}
