#!/bin/sh

set -eu

pids=''

cleanup() {
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

start_node() {
  node_id="$1"
  sql_port="$2"
  http_port="$3"

  /cockroach/cockroach start \
    --insecure \
    --listen-addr="127.0.0.1:${sql_port}" \
    --http-addr="127.0.0.1:${http_port}" \
    --advertise-addr="127.0.0.1:${sql_port}" \
    --join=127.0.0.1:26257 \
    --store="/tmp/cockroach-${node_id}" \
    --cache=64MiB \
    --max-sql-memory=64MiB \
    >"/tmp/cockroach-${node_id}.log" 2>&1 &
  pids="$pids $!"
}

check_replication() {
  /cockroach/cockroach node status \
    --ranges \
    --insecure \
    --host 127.0.0.1 \
    --port 26257 \
    --format tsv | awk -F '\t' '
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
    '
}

start_node 1 26257 8080

init_attempts=0
until /cockroach/cockroach init --insecure --host 127.0.0.1 --port 26257 >/dev/null 2>&1; do
  init_attempts=$((init_attempts + 1))
  if [ "$init_attempts" -ge 60 ]; then
    echo 'Timed out initializing the first CockroachDB node.'
    cat /tmp/cockroach-1.log
    exit 1
  fi
  sleep 1
done

until /cockroach/cockroach sql --insecure --host 127.0.0.1 --port 26257 -e 'SELECT 1' >/dev/null 2>&1; do
  sleep 1
done

/cockroach/cockroach sql --insecure --host 127.0.0.1 --port 26257 -e "
  CREATE DATABASE rid;
  CREATE DATABASE scd;
  CREATE DATABASE aux;
  CREATE TABLE rid.schema_versions (onerow_enforcer BOOL PRIMARY KEY, schema_version STRING NOT NULL);
  CREATE TABLE scd.schema_versions (onerow_enforcer BOOL PRIMARY KEY, schema_version STRING NOT NULL);
  CREATE TABLE aux.schema_versions (onerow_enforcer BOOL PRIMARY KEY, schema_version STRING NOT NULL);
  INSERT INTO rid.schema_versions VALUES (TRUE, 'v4.1.0');
  INSERT INTO scd.schema_versions VALUES (TRUE, 'v3.4.0');
  INSERT INTO aux.schema_versions VALUES (TRUE, 'v1.1.0');
  ALTER TABLE rid.schema_versions CONFIGURE ZONE USING num_replicas = 3;
  ALTER TABLE scd.schema_versions CONFIGURE ZONE USING num_replicas = 3;
  ALTER TABLE aux.schema_versions CONFIGURE ZONE USING num_replicas = 3;
" >/dev/null

for schema_and_version in rid:4.1.0 scd:3.4.0 aux:1.1.0; do
  schema="${schema_and_version%%:*}"
  version="${schema_and_version#*:}"
  /cockroach/cockroach sql --insecure --host 127.0.0.1 --port 26257 \
    --database "$schema" --format raw \
    -e 'SELECT schema_version FROM schema_versions WHERE onerow_enforcer = TRUE;' \
    | grep -qx "v${version}"
done
echo 'Migration-version checks passed for rid, scd, and aux.'

precondition_attempts=0
while pre_replication_status="$(check_replication)"; do
  precondition_attempts=$((precondition_attempts + 1))
  if [ "$precondition_attempts" -ge 30 ]; then
    echo 'Expected the single-node cluster to become under-replicated, but it remained ready.'
    exit 1
  fi
  sleep 1
done
echo "Gate correctly blocked before peers joined: ${pre_replication_status}"

start_node 2 26258 8081
start_node 3 26259 8082

consecutive_ready_checks=0
replication_attempts=0
while [ "$consecutive_ready_checks" -lt 2 ]; do
  replication_attempts=$((replication_attempts + 1))
  if replication_status="$(check_replication)"; then
    consecutive_ready_checks=$((consecutive_ready_checks + 1))
  else
    consecutive_ready_checks=0
  fi
  echo "$replication_status"
  if [ "$replication_attempts" -ge 120 ]; then
    echo 'Timed out waiting for three-node range replication.'
    exit 1
  fi
  if [ "$consecutive_ready_checks" -lt 2 ]; then sleep 1; fi
done

echo "Gate passed after all peers joined and replication settled (${replication_attempts} polls)."
