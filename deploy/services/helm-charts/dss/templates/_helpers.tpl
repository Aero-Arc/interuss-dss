{{- define "datastoreImage" -}}
{{- if $.Values.cockroachdb.enabled -}}
{{ (printf "%s:%s" $.Values.cockroachdb.image.repository $.Values.cockroachdb.image.tag) }}
{{- else -}}
{{ (printf "%s:%s" $.Values.yugabyte.Image.repository $.Values.yugabyte.Image.tag) }}
{{- end -}}
{{- end -}}

{{- define "datastorePort" -}}
{{- if $.Values.cockroachdb.enabled -}}
26257
{{- else -}}
5433
{{- end -}}
{{- end -}}

{{- define "datastoreUser" -}}
{{- if $.Values.cockroachdb.enabled -}}
root
{{- else -}}
yugabyte
{{- end -}}
{{- end -}}


{{- define "datastoreHost" -}}
{{- if $.Values.cockroachdb.enabled -}}
{{- printf "%s-public.default" $.Values.cockroachdb.fullnameOverride -}}
{{- else -}}
{{- printf "yb-tservers.default" -}}
{{- end -}}
{{- end -}}

{{- define "dss.cockroachSchemaVersions" -}}
rid: "4.1.0"
scd: "3.4.0"
aux_: "1.1.0"
{{- end -}}

{{- define "dss.yugabyteSchemaVersions" -}}
rid: "1.0.1"
scd: "1.1.0"
aux_: "1.1.0"
{{- end -}}

{{- define "init-container-wait-for-http" -}}
- name: wait-for-{{.serviceName}}
  image: alpine:3.17.3
  command: [ 'sh', '-c', "until wget -nv {{.url}}; do echo waiting for {{.serviceName}}; sleep 2; done" ]
{{- end -}}

{{- define "init-container-wait-for-schema" -}}
{{/*For some reason, calling the template datastoreImage fails here.*/}}
- name: wait-for-schema-{{.schemaName}}
  image: {{.datastoreImage}}
  volumeMounts:
    {{- include "ca-certs:volumeMount" $ | nindent 4 }}
    {{- include "client-certs:volumeMount" $ | nindent 4 }}
  command:
    - sh
    - -c
{{ if .cockroachdbEnabled }}
    - "/cockroach/cockroach sql --certs-dir /cockroach/cockroach-certs/ --host {{.datastoreHost}} --port \"{{.datastorePort}}\" --format raw -e \"SELECT * FROM crdb_internal.databases where name = '{{.schemaName}}';\" | grep {{.schemaName}}"
{{ else }}
    - "ysqlsh --host {{.datastoreHost}} --port \"{{.datastorePort}}\" \"sslmode=require sslcert=/opt/yugabyte-certs/client.yugabyte.crt sslkey=/opt/yugabyte-certs/client.yugabyte.key sslrootcert=/opt/yugabyte-certs/ca.crt\" -c \"SELECT datname FROM pg_database where datname = '{{.schemaName}}';\" | grep {{.schemaName}}"
{{ end }}
{{- end -}}

{{/* Database existence does not mean that schema-manager has finished creating ranges. */}}
{{- define "init-container-wait-for-cockroach-migrations" -}}
- name: wait-for-cockroach-migrations
  image: {{.datastoreImage}}
  volumeMounts:
    {{- include "ca-certs:volumeMount" $ | nindent 4 }}
    {{- include "client-certs:volumeMount" $ | nindent 4 }}
  command:
    - sh
    - -c
    - |
      until /cockroach/cockroach sql --certs-dir /cockroach/cockroach-certs/ --host {{.datastoreHost}} --port "{{.datastorePort}}" --database rid --format raw -e "SELECT schema_version FROM schema_versions WHERE onerow_enforcer = TRUE;" | grep -qx "v{{.ridVersion}}"; do
        echo "waiting for RID migration to reach v{{.ridVersion}}"
        sleep 2
      done
      until /cockroach/cockroach sql --certs-dir /cockroach/cockroach-certs/ --host {{.datastoreHost}} --port "{{.datastorePort}}" --database scd --format raw -e "SELECT schema_version FROM schema_versions WHERE onerow_enforcer = TRUE;" | grep -qx "v{{.scdVersion}}"; do
        echo "waiting for SCD migration to reach v{{.scdVersion}}"
        sleep 2
      done
      until /cockroach/cockroach sql --certs-dir /cockroach/cockroach-certs/ --host {{.datastoreHost}} --port "{{.datastorePort}}" --database aux --format raw -e "SELECT schema_version FROM schema_versions WHERE onerow_enforcer = TRUE;" | grep -qx "v{{.auxVersion}}"; do
        echo "waiting for auxiliary migration to reach v{{.auxVersion}}"
        sleep 2
      done
{{- end -}}

{{/* node status reports every node, unlike a node-local metrics endpoint reached through the balanced service. */}}
{{- define "init-container-wait-for-cockroach-replication" -}}
- name: wait-for-cockroach-replication
  image: {{.datastoreImage}}
  volumeMounts:
    {{- include "ca-certs:volumeMount" $ | nindent 4 }}
    {{- include "client-certs:volumeMount" $ | nindent 4 }}
  command:
    - sh
    - -c
    - |
      consecutive_ready_checks=0
      while [ "$consecutive_ready_checks" -lt 2 ]; do
        if replication_status="$(/cockroach/cockroach node status --ranges --certs-dir /cockroach/cockroach-certs/ --host {{.datastoreHost}} --port "{{.datastorePort}}" --format tsv | awk -F '\t' '
          NR == 1 {
            for (i = 1; i <= NF; i++) {
              if ($i == "ranges_underreplicated") underreplicated_column = i
              if ($i == "ranges_unavailable") unavailable_column = i
            }
            next
          }
          {
            underreplicated += $(underreplicated_column)
            unavailable += $(unavailable_column)
          }
          END {
            if (!underreplicated_column || !unavailable_column) {
              print "unable to read CockroachDB range replication status"
              exit 2
            }
            print "CockroachDB ranges: underreplicated=" underreplicated " unavailable=" unavailable
            exit (underreplicated == 0 && unavailable == 0 ? 0 : 1)
          }
        ')"; then
          consecutive_ready_checks=$((consecutive_ready_checks + 1))
        else
          consecutive_ready_checks=0
        fi
        echo "$replication_status"
        if [ "$consecutive_ready_checks" -lt 2 ]; then sleep 2; fi
      done
{{- end -}}
