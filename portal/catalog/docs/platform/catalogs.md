# Catalogs

What teams can choose is set by EnvironmentConfigs on the control plane. `api/install/install.sh`
installs them once and never overwrites them: after that, the objects on the control plane are the
catalogs, and you edit them there (`kubectl edit environmentconfig <name>`, or GitOps).

| Catalog | Holds | Read by |
|---|---|---|
| `postgres-sizes` | Sizes: CPU, memory, tuned PostgreSQL settings, suggested volumes, per-profile settings | function, size admission policy, portal |
| `postgres-extensions` | Extensions clusters may add, their settings, preloads, images | function, extension admission policy, portal |
| `project-defaults` | Ingress hosts, remote write, COSI driver and access class | Project composition |

The shipped versions are in `api/apis/postgrescluster/sizes.yaml` and `extensions.yaml`, with every
key documented in their header.

## Sizes

```yaml
- name: m
  displayName: M
  description: General purpose production
  resources:
    requests: {cpu: "2", memory: 8Gi}
    limits: {memory: 8Gi}            # memory request == limit
  parameters:                        # tuned to the memory
    shared_buffers: 2GB
    effective_cache_size: 6GB
    work_mem: 16MB
    maintenance_work_mem: 512MB
    max_connections: "200"
  profiles:
    vector:                          # over the parameters, for profile: vector
      parameters:
        maintenance_work_mem: 1536MB
        max_parallel_maintenance_workers: "2"
  storage: {size: 50Gi, walSize: 10Gi}   # what the portal suggests
```

- **Changing a size resizes every cluster of that size**: CNPG restarts their instances one by one,
  the primary last. Do it in a quiet hour.
- **Removing a size** only stops new clusters from picking it. Clusters that have it keep running with
  what `status.sizing` recorded, also when the catalog can't be read.
- Values are strings. Keep `shared_buffers` around 25% and `effective_cache_size` around 75% of the
  memory.

## Extensions

```yaml
- name: vchord
  displayName: VectorChord
  description: Fast vector indexes for large embedding collections
  requires: [vector]                 # created first in every database that lists it
  sharedPreloadLibraries: [vchord]   # adding or removing it restarts the instances
  image:                             # not in the PostgreSQL image: mounted (PostgreSQL 18+)
    reference: ghcr.io/tensorchord/vchord-scratch:pg18-v1.1.1@sha256:...
  extensionControlPath: [usr/share/postgresql/18]
  dynamicLibraryPath: [usr/lib/postgresql/18/lib]
```

- Without `image`, only list extensions every image in the image catalog ships (contrib, pgvector,
  pgaudit in the standard images).
- With `image`: build it for the image catalog's PostgreSQL major and OS (trixie), pin a digest, and
  check that the locations support image volumes. Changing the digest rolls the instances out.
- **Removing an extension** only blocks clusters from adding it. Databases keep it, and a cluster keeps
  mounting an image extension it still uses.
- Check the license of what you add: VectorChord is AGPLv3 or ELv2, pg_search AGPLv3.

## Profiles

Profiles (`general`, `vector`) are part of the API, not a catalog; their tuning comes from the sizes'
`profiles` entries. A size without an entry for a profile runs that profile with the size's own
settings.

## Admission

Two ValidatingAdmissionPolicies take the catalogs as their parameter: a new cluster (or a change of
size or extensions) must name what's in them, and an image extension needs PostgreSQL 18. Without a
catalog the policies let everything through, and the function reports what it can't resolve in the
cluster's `status.message`.
