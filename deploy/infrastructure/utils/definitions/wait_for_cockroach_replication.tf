variable "wait_for_cockroach_replication" {
  type        = bool
  description = "Enable a CockroachDB startup barrier that waits for DSS schema migrations and range replication before starting new core-service pods. Intended for benchmarks and other deployments that require a fully replicated datastore before accepting traffic."
  default     = false
}
