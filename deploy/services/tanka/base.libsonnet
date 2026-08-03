local util = import 'util.libsonnet';
local volumes = import 'volumes.libsonnet';
local resolvedSchemaVersion(version, latestVersion) =
  if std.asciiLower(version) == 'latest' then latestVersion else version;

{
  _Object(apiVersion, kind, metadata, name):: {
    apiVersion: apiVersion,
    kind: kind,
    metadata: {
      name: name,
      namespace: metadata.namespace,
      labels: {
        name: std.join('-', std.split(name, ':')),
      },
    },
  },

  _RoleRelated(kind, metadata, name): $._Object('rbac.authorization.k8s.io/v1', kind, metadata, name) {
    local rr = self,
    app:: "",
    metadata+: {
      labels+: if rr.app != "" then {
        app: rr.app,
      } else {},
    },
  },

  RoleBinding(metadata, name): $._RoleRelated('RoleBinding', metadata, name) {

  },

  ClusterRole(metadata, name): $._RoleRelated('ClusterRole', metadata, name) {
    metadata+: {
      namespace: null,
    },
  },

  ClusterRoleBinding(metadata, name): $._RoleRelated('ClusterRoleBinding', metadata, name) {
    metadata+: {
      namespace: null,
    },
  },

  Role(metadata, name): $._RoleRelated('Role', metadata, name) {

  },

  Namespace(metadata, name): $._Object('v1', 'Namespace', metadata, name) {
    metadata+: {
      namespace: null,
    },
  },

  ServiceAccount(metadata, name): $._Object('v1', 'ServiceAccount', metadata, name) {

  },

  PodDisruptionBudget(metadata, name): $._Object('policy/v1', 'PodDisruptionBudget', metadata, name) {
    local pdb = self,
    app:: error "must specify app",
    metadata+: {
      labels: {
        app: pdb.app,
      },
    },
    spec: {
      selector: {
        matchLabels: {
          app: pdb.app,
        },
      },
      maxUnavailable: 1,
    },
  },

  ManagedCert(metadata, name): $._Object('networking.gke.io/v1', 'ManagedCertificate', metadata, name) {

  },

  Ingress(metadata, name): $._Object('networking.k8s.io/v1', 'Ingress', metadata, name) {

  },

  Deployment(metadata, name): $._Object('apps/v1', 'Deployment', metadata, name) {
    local deployment = self,

    spec: {
      selector: {
        matchLabels: {
          app: name,
        },
      },
      template: {
        metadata+: {
          labels+: {
            app: name,
          },
        },
        spec: $.PodSpec(metadata),
      },

      strategy: {
        type: 'RollingUpdate',

        rollingUpdate: {
          maxSurge: '25%',  // rounds up
          maxUnavailable: '25%',  // rounds down
        },
      },

      minReadySeconds: 30,

      replicas: std.length(if metadata.datastore == 'cockroachdb' then metadata.cockroach.nodeIPs else metadata.yugabyte.masterNodeIPs),
      assert self.replicas >= 1,
    },
  },

  ConfigMap(metadata, name): $._Object('v1', 'ConfigMap', metadata, name),

  Service(metadata, name): $._Object('v1', 'Service', metadata, name) {
    local service = self,
    app:: error "must specify app",
    # Helper when a service has only 1 port
    port:: error "must specify port",
    enable_monitoring:: false,
    type:: 'ClusterIP',
    metadata+: {
      labels+: {
        app: service.app,
      },
      annotations: if service.enable_monitoring then {
        'prometheus.io/scrape': 'true',
        'prometheus.io/port': std.toString(service.port),
      } else {},
    },
    spec: {
      selector: {
        app: service.app,
      },
      ports: [
        {
          port: service.port,
          targetPort: service.port,
          name: name,
        },
      ],
      type: service.type,
    },
  },

  StatefulSet(metadata, name): $._Object('apps/v1', 'StatefulSet', metadata, name) {
    local sset = self,

    spec: {
      serviceName: name,

      updateStrategy: {
        type: 'RollingUpdate',
        rollingUpdate: {
          partition: 0,
        },
      },

      template: {
        spec: $.PodSpec(metadata),
        metadata: {
          labels: {
            app: name,
          },
          annotations: {},
        },
      },

      selector: {
        matchLabels: sset.spec.template.metadata.labels,
      },

      volumeClaimTemplates_:: {},
      volumeClaimTemplates: [
        // StatefulSet is overly fussy about "changes" (even when
        // they're no-ops).
        // In particular annotations={} is apparently a "change",
        // since the comparison is ignorant of defaults.
        std.prune($.PersistentVolumeClaim($.hyphenate(kv[0])) + { apiVersion:: null, kind:: null } + kv[1])
        for kv in util.objectItems(self.volumeClaimTemplates_)
      ],

      replicas: std.length(if metadata.datastore == 'cockroachdb' then metadata.cockroach.nodeIPs else metadata.yugabyte.masterNodeIPs),
      assert self.replicas >= 1,
    },
  },

  Job(metadata, name): $._Object('batch/v1', 'Job', metadata, name) {
    local job = self,
    local hash = std.md5(std.toString(self.spec.template.spec)),
    local uniqueName = name + '-' + hash,

    metadata+: {
      name: uniqueName,
      labels: {
        name: std.join('-', std.split(uniqueName, ':')),
      },
    },

    spec: {
      template: {
        metadata+: {
          labels: job.metadata.labels,
        },
        spec: $.PodSpec(metadata) {
          restartPolicy: 'OnFailure',
        },
      },
      completions: 1,
      parallelism: 1,
    },
  },

  CronJob(metadata, name): $._Object('batch/v1', 'CronJob', metadata, name) {
    metadata+: {
      name: name,
      labels: {
        name: name,
      },
    },
  },

  Container(name): {
    name: name,
    image: error 'container image value required',
    imagePullPolicy: if std.endsWith(self.image, ':latest') then 'Always' else 'IfNotPresent',

    args_:: {},
    args: util.makeArgs(self.args_),

    stdin: false,
    tty: false,
    assert !self.tty || self.stdin : 'tty=true requires stdin=true',
  },

  PodSpec(metadata): {
    soloContainer:: error 'must have at least one container',
    containers: [self.soloContainer],
    volumes_:: {},
    volumes: util.mapToList(self.volumes_),

    terminationGracePeriodSeconds: 30,

    assert std.length(self.containers) > 0 : 'must have at least one container',

    imagePullSecrets: if (metadata.image_pull_secret != '') then [{name: metadata.image_pull_secret}] else [],
  },

  // Reusable cloud provider specific resources
  AWSLoadBalancer(metadata, name, ipNames, subnet): $.Service(metadata, name) {
    type:: 'LoadBalancer',
    metadata+: {
      annotations+: {
        'service.beta.kubernetes.io/aws-load-balancer-type': 'external',
        'service.beta.kubernetes.io/aws-load-balancer-nlb-target-type': 'ip',
        'service.beta.kubernetes.io/aws-load-balancer-scheme': 'internet-facing',
        'service.beta.kubernetes.io/aws-load-balancer-eip-allocations': std.join(',', ipNames),
        'service.beta.kubernetes.io/aws-load-balancer-subnets': metadata.subnet,
      },
    },
    spec+: {
      loadBalancerClass: "service.k8s.aws/nlb",
    },
  },

  AWSLoadBalancerWithManagedCert(metadata, name, ipNames, subnet, certARN): $.AWSLoadBalancer(metadata, name, ipNames, subnet) {
    metadata+: {
      annotations+: {
          'service.beta.kubernetes.io/aws-load-balancer-ssl-ports': '443',
          'service.beta.kubernetes.io/aws-load-balancer-ssl-cert': certARN,
      },
    },
  },

  GoogleFrontendConfig(metadata, name, sslPolicy): $._Object('networking.gke.io/v1beta1', 'FrontendConfig', metadata, name) {
    metadata+: {
      name: name
    },
    spec+: {
      sslPolicy: sslPolicy
    }
  },

  Secret(metadata, name): $._Object('v1', 'Secret', metadata, name) {
  },

  WaitForDatastore(metadata): {
    name: "wait-for-datastore",
    image: "alpine:3.17.3",
    command: [
      'sh',
      '-c',
      if metadata.datastore == "cockroachdb" then
        "until wget -nv http://cockroachdb-balanced." + metadata.namespace + ":8080/health; do echo waiting for datastore; sleep 2; done" else
        "until wget -nv http://yb-tservers." + metadata.namespace + ":9000/status; do echo waiting for datastore; sleep 2; done"
    ]
  },

  WaitForSchema(metadata, table): {
    name: "wait-for-schema-" + table,
    image: if metadata.datastore == "cockroachdb" then metadata.cockroach.image else metadata.yugabyte.image,
    command: [
      'sh',
      '-c',
      if metadata.datastore == "cockroachdb" then
        "/cockroach/cockroach sql --certs-dir /cockroach/cockroach-certs/ --host cockroachdb-balanced." + metadata.namespace + " --port \"" + metadata.cockroach.grpc_port + "\" --format raw -e \"SELECT * FROM crdb_internal.databases where name = '" + table + "';\" | grep " + table else
        "ysqlsh --host yb-tservers." + metadata.namespace + " --port \"5433\" \"sslmode=require sslcert=/opt/yugabyte-certs/client.yugabyte.crt sslkey=/opt/yugabyte-certs/client.yugabyte.key sslrootcert=/opt/yugabyte-certs/ca.crt\" -c \"SELECT datname FROM pg_database where datname = '" + table + "';\" | grep " + table
    ],
    volumeMounts: volumes.all(metadata).backendMounts,
  },

  // Database existence does not mean that the schema-manager job has finished
  // creating tables and indexes, each of which may create new ranges.
  WaitForCockroachMigrations(metadata): {
    local datastoreHost = 'cockroachdb-balanced.' + metadata.namespace,
    local waitForSchema(schema, label, version) = |||
      until /cockroach/cockroach sql --certs-dir /cockroach/cockroach-certs/ --host %s --port "%s" --database %s --format raw -e "SELECT schema_version FROM schema_versions WHERE onerow_enforcer = TRUE;" | grep -qx "v%s"; do
        echo "waiting for %s migration to reach v%s"
        sleep 2
      done
    ||| % [
      datastoreHost,
      metadata.cockroach.grpc_port,
      schema,
      version,
      label,
      version,
    ],
    local ridVersion = resolvedSchemaVersion(metadata.schema_manager.desired_rid_db_version, metadata.schema_manager.latest_cockroach_rid_db_version),
    local scdVersion = resolvedSchemaVersion(metadata.schema_manager.desired_scd_db_version, metadata.schema_manager.latest_cockroach_scd_db_version),
    local auxVersion = resolvedSchemaVersion(metadata.schema_manager.desired_aux_db_version, metadata.schema_manager.latest_cockroach_aux_db_version),
    name: 'wait-for-cockroach-migrations',
    image: metadata.cockroach.image,
    command: [
      'sh',
      '-c',
      std.join('\n',
        [waitForSchema('rid', 'RID', ridVersion)] +
        (if metadata.enableScd then [waitForSchema('scd', 'SCD', scdVersion)] else []) +
        [waitForSchema('aux', 'auxiliary', auxVersion)]),
    ],
    volumeMounts: volumes.all(metadata).schemaMounts,
  },

  // `node status --ranges` reports every node, unlike a node-local metrics
  // endpoint reached through the balanced service.
  WaitForCockroachReplication(metadata): {
    name: 'wait-for-cockroach-replication',
    image: metadata.cockroach.image,
    command: [
      'sh',
      '-c',
      |||
        consecutive_ready_checks=0
        while [ "$consecutive_ready_checks" -lt 2 ]; do
          if replication_status="$(/cockroach/cockroach node status --ranges --certs-dir /cockroach/cockroach-certs/ --host %s --port "%s" --format tsv | awk -F '\t' '
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
      ||| % [
        'cockroachdb-balanced.' + metadata.namespace,
        metadata.cockroach.grpc_port,
      ],
    ],
    volumeMounts: volumes.all(metadata).schemaMounts,
  },
}
