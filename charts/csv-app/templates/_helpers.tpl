{{/* Standard name/label helpers. */}}

{{- define "csv-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "csv-app.fullname" -}}
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

{{- define "csv-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "csv-app.labels" -}}
helm.sh/chart: {{ include "csv-app.chart" . }}
{{ include "csv-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "csv-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "csv-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Selector labels for the dev-only MinIO deployment.

These MUST NOT overlap with csv-app.selectorLabels. The application Service
selects on name+instance alone, so if MinIO shared those labels the Service
would match the MinIO pod too and load-balance application traffic onto it.
Adding a distinguishing label to MinIO only would not help — a selector
matches on a subset, so the app's Service would still match the MinIO pod.
The name itself has to differ.
*/}}
{{- define "csv-app.minioSelectorLabels" -}}
app.kubernetes.io/name: {{ include "csv-app.name" . }}-minio
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "csv-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "csv-app.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "csv-app.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{/* Name of the Secret holding S3 credentials, if any is in play. */}}
{{- define "csv-app.secretName" -}}
{{- if .Values.s3.existingSecret -}}
{{- .Values.s3.existingSecret -}}
{{- else -}}
{{- include "csv-app.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "csv-app.hasStaticCredentials" -}}
{{- if or .Values.s3.existingSecret (and .Values.s3.accessKeyId .Values.s3.secretAccessKey) -}}true{{- end -}}
{{- end -}}

{{/*
Default nginx configuration.

Two jobs: serve /static straight off the shared emptyDir volume (never
proxying it to the app), and reverse-proxy everything else to the app on
127.0.0.1 — same pod, so this is a loopback hop, not a network one.

Ansible overrides this wholesale via .Values.nginx.config so that application
configuration is owned by Ansible rather than baked into the chart.
*/}}
{{- define "csv-app.nginxConfig" -}}
{{- if .Values.nginx.config -}}
{{ .Values.nginx.config }}
{{- else -}}
#
# Chart fallback — NOT the Ansible-managed configuration.
#
# Reaching this means nginx.config was not supplied, so ansible/build/
# values.generated.yaml was not passed to Helm. Deploy with `make deploy`
# (or `devspace dev`, which renders it first) to get the managed config.
# This fallback exists only so `helm install` works standalone.
#
worker_processes auto;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Writable paths must live under /tmp: the container runs with a
    # read-only root filesystem.
    client_body_temp_path /tmp/client_body;
    proxy_temp_path       /tmp/proxy;
    fastcgi_temp_path     /tmp/fastcgi;
    uwsgi_temp_path       /tmp/uwsgi;
    scgi_temp_path        /tmp/scgi;

    log_format json escape=json '{"time":"$time_iso8601","method":"$request_method",'
        '"uri":"$request_uri","status":$status,"bytes":$body_bytes_sent,'
        '"upstream":"$upstream_addr","duration":$request_time}';
    access_log /dev/stdout json;

    sendfile      on;
    tcp_nopush    on;
    server_tokens off;
    keepalive_timeout 65;

    gzip on;
    gzip_types text/css application/javascript image/svg+xml application/json;
    gzip_min_length 512;

    # Uploads flow through this proxy, so the limit must be at least the
    # application's own limit or nginx rejects the request first.
    client_max_body_size {{ div (.Values.app.maxUploadBytes | int64) 1048576 }}m;

    upstream app {
        server 127.0.0.1:{{ .Values.app.port }};
        keepalive 16;
    }

    server {
        listen {{ .Values.nginx.port }};
        server_name _;

        # Static assets come from the volume shared with the app container.
        location /static/ {
            alias {{ .Values.sharedStatic.mountPath }}/;
            access_log off;
            expires 1h;
            add_header Cache-Control "public";
            add_header X-Served-By "nginx-shared-volume" always;
            try_files $uri =404;
        }

        location / {
            proxy_pass http://app;
            proxy_http_version 1.1;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Connection        "";
            proxy_read_timeout 60s;
            proxy_request_buffering off;
        }
    }
}
{{- end -}}
{{- end -}}
