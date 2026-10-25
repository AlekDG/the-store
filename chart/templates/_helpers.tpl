{{- define "the-store.labels" -}}
helm.sh/chart: {{ .root.Chart.Name }}-{{ .root.Chart.Version }}
{{ include "the-store.selectorLabels" . }}
app.kubernetes.io/owner: retail-store-sample
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{- define "the-store.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .name }}
app.kubernetes.io/component: service
{{- end }}

{{- define "the-store.image" -}}
{{ .root.Values.image.registry }}{{ .root.Values.image.prefix }}{{ .svc.image }}:{{ .root.Values.image.tag }}
{{- end }}
