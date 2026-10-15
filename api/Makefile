.PHONY: generate check test install uninstall

# Rebuild apis/postgrescluster/composition.yaml from composition.tmpl.yaml + src/
generate:
	go run ./hack/generate

# Fail if composition.yaml is stale
check:
	go run ./hack/generate --check

# Offline render + schema validation tests (needs Go, crossplane CLI + Docker/podman)
test:
	tests/render/run.sh

install:
	install/install.sh

uninstall:
	install/uninstall.sh
