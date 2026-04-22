# Makefile - Enterprise Monitoring Hub
# Goal: Advanced multi-environment management with PLG Stack (Prometheus, Loki, Grafana)
# Tools: Prometheus, Grafana, Loki, Icinga2, K6

CLUSTER_NAME=monitoring-cluster
NAMESPACE_MONITORING=monitoring
NAMESPACE_STAGING=staging
NAMESPACE_PRODUCTION=production

GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
LOKI_PORT=3100
K6_WEB_PORT=6565
PODINFO_PORT=9898
# OS/Arch Detection
OS := $(shell uname -s)
ARCH := $(shell uname -m)

ifeq ($(OS),Darwin)
    OPEN_CMD := open
else
    OPEN_CMD := xdg-open
endif

# Default arch for Colima
COLIMA_ARCH := $(shell echo $(ARCH) | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')

.PHONY: help deploy check-deps cluster-up install-stack deploy-apps access clean destroy load-test k6-web ports scan send-test-trap

help:
	@echo "Usage: make deploy"
	@echo "Detected Environment: $(OS) $(ARCH)"
	@echo "Available commands:"
	@echo "  deploy      - Full setup (Cluster + Monitoring Stack + Apps + Access)"
	@echo "  access      - Establish port-forwards and open services in browser"
	@echo "  ports       - Display access URLs and credentials"
	@echo "  load-test   - Run performance validation with K6"
	@echo "  send-test-trap - Simulate an SNMP Trap for testing"
	@echo "  clean       - Stop the cluster"
	@echo "  destroy     - Remove all data and uninstall tools"

deploy: check-deps cluster-up install-stack deploy-apps access

check-deps:
	@echo "==> [1/7] Validating Dependencies for $(OS) $(ARCH)..."
	@if [ "$(OS)" = "Darwin" ]; then \
		command -v brew >/dev/null 2>&1 || { echo >&2 "Installing Homebrew..."; /bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; }; \
	fi
	@command -v colima >/dev/null 2>&1 || { echo >&2 "Colima not found. Please install it (e.g. brew install colima)"; }
	@command -v docker >/dev/null 2>&1 || { echo >&2 "Docker CLI not found."; }
	@command -v kubectl >/dev/null 2>&1 || { echo >&2 "Kubectl not found."; }
	@command -v helm >/dev/null 2>&1 || { echo >&2 "Helm not found."; }
	@command -v snmptrap >/dev/null 2>&1 || { echo >&2 "Warning: 'snmp' tools not found locally. Using in-cluster test instead."; }

cluster-up:
	@echo "==> [2/7] Initializing Kubernetes Cluster ($(COLIMA_ARCH) Optimized)..."
	@if colima status >/dev/null 2>&1; then \
		echo "Cluster is already active."; \
	else \
		colima start --kubernetes --cpu 3 --memory 6 --arch $(COLIMA_ARCH); \
	fi

install-stack:
	@echo "==> [3/7] Deploying Monitoring Stack (PLG + OTel + SNMP + Icinga2)..."
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	@helm repo add grafana https://grafana.github.io/helm-charts
	@helm repo update
	@helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		--namespace $(NAMESPACE_MONITORING) --create-namespace \
		-f k8s/monitoring/values.yaml
	@helm upgrade --install loki grafana/loki-stack \
		--namespace $(NAMESPACE_MONITORING) --create-namespace \
		-f k8s/monitoring/loki-values.yaml
	@helm upgrade --install tempo grafana/tempo \
		--namespace $(NAMESPACE_MONITORING) --create-namespace \
		-f k8s/monitoring/tempo-values.yaml
	@echo "Applying DataSources consolidation (Loki + Prometheus + Tempo)..."
	@kubectl apply -f k8s/monitoring/tempo-fix.yaml -n $(NAMESPACE_MONITORING)
	@echo "Deploying OpenTelemetry Collector..."
	@kubectl apply -f k8s/monitoring/otel-collector.yaml -n $(NAMESPACE_MONITORING)
	@kubectl apply -f k8s/monitoring/otel-servicemonitor.yaml -n $(NAMESPACE_MONITORING)
	@kubectl apply -f k8s/monitoring/podinfo-servicemonitor.yaml -n $(NAMESPACE_MONITORING)
	@echo "Deploying SNMP Trap Receiver (Telegraf)..."
	@kubectl apply -f k8s/monitoring/snmp-trap-receiver.yaml -n $(NAMESPACE_MONITORING)
	@echo "Provisioning Dashboards..."
	@kubectl apply -f k8s/monitoring/podinfo-dashboard.yaml -n $(NAMESPACE_MONITORING)
	@kubectl apply -f k8s/monitoring/cluster-dashboard.yaml -n $(NAMESPACE_MONITORING)
	@kubectl apply -f k8s/monitoring/loki-dashboard.yaml -n $(NAMESPACE_MONITORING)
	@kubectl apply -f k8s/monitoring/tempo-dashboard.yaml -n $(NAMESPACE_MONITORING)
	@echo "Deploying Icinga2..."
	@kubectl apply -f k8s/monitoring/icinga2.yaml -n $(NAMESPACE_MONITORING)

deploy-apps:
	@echo "==> [4/7] Deploying Staging Environment..."
	@kubectl create namespace $(NAMESPACE_STAGING) --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f k8s/app/rbac.yaml -n $(NAMESPACE_STAGING)
	@kubectl apply -f k8s/app/podinfo.yaml -n $(NAMESPACE_STAGING)
	@echo "==> [5/7] Deploying Production Environment (Secured)..."
	@kubectl create namespace $(NAMESPACE_PRODUCTION) --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f k8s/app/rbac.yaml -n $(NAMESPACE_PRODUCTION)
	@kubectl apply -f k8s/app/podinfo.yaml -n $(NAMESPACE_PRODUCTION)
	@kubectl apply -f k8s/app/security-policy.yaml -n $(NAMESPACE_PRODUCTION)

wait-for-ready:
	@echo "==> [6/7] Waiting for services to stabilize..."
	@kubectl rollout status deployment/monitoring-grafana -n $(NAMESPACE_MONITORING) --timeout=300s
	@kubectl rollout status deployment/podinfo -n $(NAMESPACE_PRODUCTION) --timeout=300s
	@kubectl wait --for=condition=ready pod -l release=loki -n $(NAMESPACE_MONITORING) --timeout=300s
	@echo "Waiting 15s for secondary services (Icinga2, OTel, SNMP)..."
	@sleep 15

send-test-trap:
	@echo "==> Sending Test SNMP Trap..."
	@kubectl run snmp-gen --image=nicolaka/netshoot -n $(NAMESPACE_MONITORING) --rm -i --restart=Never -- \
		snmptrap -v 2c -c public telegraf-snmp:162 "" .1.3.6.1.4.1.2021.251.1 .1.3.6.1.4.1.2021.251.2 s "Test Trap for European Commission Interview"

access: wait-for-ready
	@echo "==> [7/7] Establishing port-forwards..."
	@pgrep -f "kubectl port-forward svc/monitoring-grafana $(GRAFANA_PORT):80" > /dev/null || \
		(nohup kubectl port-forward svc/monitoring-grafana $(GRAFANA_PORT):80 -n $(NAMESPACE_MONITORING) > /tmp/grafana-pf.log 2>&1 &)
	@pgrep -f "kubectl port-forward svc/monitoring-kube-prometheus-prometheus $(PROMETHEUS_PORT):9090" > /dev/null || \
		(nohup kubectl port-forward svc/monitoring-kube-prometheus-prometheus $(PROMETHEUS_PORT):9090 -n $(NAMESPACE_MONITORING) > /tmp/prometheus-pf.log 2>&1 &)
	@pgrep -f "kubectl port-forward svc/loki $(LOKI_PORT):3100" > /dev/null || \
		(nohup kubectl port-forward svc/loki $(LOKI_PORT):3100 -n $(NAMESPACE_MONITORING) > /tmp/loki-pf.log 2>&1 &)
	@pgrep -f "kubectl port-forward svc/podinfo $(PODINFO_PORT):9898" > /dev/null || \
		(nohup kubectl port-forward svc/podinfo $(PODINFO_PORT):9898 -n $(NAMESPACE_PRODUCTION) > /tmp/podinfo-pf.log 2>&1 &)
	@pgrep -f "kubectl port-forward svc/icinga2 $(ICINGA2_PORT):$(ICINGA2_PORT)" > /dev/null || \
		(nohup kubectl port-forward svc/icinga2 $(ICINGA2_PORT):$(ICINGA2_PORT) -n $(NAMESPACE_MONITORING) > /tmp/icinga2-pf.log 2>&1 &)
	@sleep 2
	@$(MAKE) ports
	@echo "Opening services in browser..."
	@$(OPEN_CMD) http://localhost:$(GRAFANA_PORT) || true
	@$(OPEN_CMD) http://localhost:$(PODINFO_PORT) || true

ports:
	@echo ""
	@echo "=============================================="
	@echo "           ACCESS URLS & CREDENTIALS"
	@echo "=============================================="
	@echo "GRAFANA (Visualizer):      http://localhost:$(GRAFANA_PORT)"
	@echo "  - User: admin"
	@echo "  - Pass: prom-operator"
	@echo ""
	@echo "PROMETHEUS (Metrics):     http://localhost:$(PROMETHEUS_PORT)"
	@echo ""
	@echo "LOKI (Logs Health):        http://localhost:$(LOKI_PORT)/ready"
	@echo ""
	@echo "ICINGA2 (External API):    https://localhost:$(ICINGA2_PORT)/v1/status"
	@echo "  - User: root"
		@echo "  - Pass: $$(kubectl exec -n $(NAMESPACE_MONITORING) $$(kubectl get pods -n $(NAMESPACE_MONITORING) -l app=icinga2 -o name | head -n 1) -- grep -oP 'password = \"\K[^\"]+' /etc/icinga2/conf.d/api-users.conf 2>/dev/null || echo 'Check logs for password')"

	@echo ""
	@echo "APP (Production):          http://localhost:$(PODINFO_PORT)"
	@echo "=============================================="
	@echo "Note: For Icinga2 (HTTPS), you must accept the self-signed certificate in your browser."
	@echo ""

load-test:
	@echo "==> Generating production workload..."
	@k6 run scripts/load-test.js

k6-web:
	@echo "==> Starting K6 Web UI..."
	@k6 run --web-port $(K6_WEB_PORT) scripts/load-test.js

clean:
	@colima stop

destroy:
	@colima delete -f

scan:
	@echo "==> Auditing Kubernetes Manifests with Trivy..."
	@docker run --rm -v $(PWD):/root aquasec/trivy config /root/k8s --severity HIGH,CRITICAL
