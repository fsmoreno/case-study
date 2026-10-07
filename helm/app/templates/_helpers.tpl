{{- define "app.name" -}}estuda-api{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "app.dbEnv" -}}
- name: DB_NAME
  valueFrom: { secretKeyRef: { name: {{ .Values.existingSecret }}, key: DB_NAME } }
- name: DB_USER
  valueFrom: { secretKeyRef: { name: {{ .Values.existingSecret }}, key: DB_USER } }
- name: DB_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ .Values.existingSecret }}, key: DB_PASSWORD } }
{{- end -}}
