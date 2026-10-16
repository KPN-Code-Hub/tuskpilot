# Configure a cluster

Every setting below is a field of the `PostgresCluster` spec; the portal's form sets the same
fields. The [API reference](../api.md) lists all of them, with their defaults and rules.

## Size

`spec.size` picks a size from the platform's catalog. A size gives each instance its CPU and memory,
plus PostgreSQL settings tuned to that memory (`shared_buffers`, `effective_cache_size`,
`work_mem`, `maintenance_work_mem`, `max_connections`).

| Size | CPU | Memory | Suggested data / WAL volume |
|---|---|---|---|
| `xs` | 500m | 1Gi | 10Gi / – |
| `s` | 1 | 4Gi | 20Gi / 5Gi |
| `m` | 2 | 8Gi | 50Gi / 10Gi |
| `l` | 4 | 16Gi | 100Gi / 20Gi |
| `xl` | 8 | 32Gi | 250Gi / 50Gi |

- Settings in `spec.postgresql.parameters` override the size's.
- Instead of a size you can set `spec.resources` (CPU and memory of your own), not both.
- `status.sizing` shows what the instances run with. Changing the size restarts the instances one by
  one, the primary last (a switchover), so the database stays available.
- Volumes are separate (`spec.storage`, `spec.walStorage`): they can grow, not shrink. A separate WAL
  volume is worth it for busy databases.

## Workload profile

`spec.profile` tunes the cluster for a kind of workload: `general` (default) or `vector` for
embeddings and AI search. See [Vector & RAG](vector-rag.md).

## Extensions

`spec.database.extensions` lists the extensions created in the application database, e.g.
`[vector, pg_trgm]`; `spec.databases[].extensions` does the same for extra databases. Only
extensions in the platform's catalog are allowed; the portal lists them.

- Some extensions need a library loaded at startup: adding or removing one restarts the instances
  one by one.
- Removing an extension from the list leaves it installed: dropping it would also drop the columns
  and indexes that use it. Drop it with `psql` if you mean it.
- VectorChord and pg_search are mounted from images and need PostgreSQL 18.

## High availability

| Field | Default | Meaning |
|---|---|---|
| `instances` | 3 | 1 primary + standbys. Use 3 or more for production. |
| `highAvailability.podAntiAffinityType` | `preferred` | `required` never puts two instances on one node. |
| `highAvailability.zoneSpread` | `true` | Spread the instances over availability zones. |
| `highAvailability.synchronousReplicas` | 0 | Standbys that confirm each commit: no data loss when the primary fails. |
| `highAvailability.synchronousDataDurability` | `preferred` | `required` stops writes when too few standbys confirm. |

CloudNativePG fails over to a standby by itself when the primary is lost.

## Connection pooling

`pooler.enabled` puts PgBouncer in front of the cluster (`<name>-pooler-rw`); `pooler.readOnly` adds
one for the standbys (`<name>-pooler-ro`). `poolMode` is `transaction` (default) or `session`. Use it
for applications with many short-lived connections.

## Backups

`backup.enabled` archives the WAL continuously and takes a base backup on `backup.schedule`, kept for
`backup.retentionPolicy` (default 30 days). Without a destination of its own, the cluster uses its
Project's backup bucket. See [Backups and restore](backup-restore.md).

## Monitoring and auditing

- Metrics, the CloudNativePG alerts and a Grafana dashboard are on by default (`monitoring`). The
  dashboard is in your Project's Grafana and on the cluster's **Monitoring** tab.
- `monitoring.prometheusRule.excludeRules` drops alerts you don't want.
- Audit logging (pgaudit) records the statements of the classes in
  `postgresql.parameters["pgaudit.log"]`, e.g. `ddl, role`. The portal has a switch for it.

## Changing a running cluster

Everything can change in place except `postgresVersion` (forward only: a major upgrade), the
`database` name and owner, `restore` and the storage classes. Size and CPU/memory changes, and
extensions that load a library, restart the instances one by one, the primary last.
