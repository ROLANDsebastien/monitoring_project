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
ICINGA2_PORT=5665

.PHONY: help deploy check-deps cluster-up install-stack deploy-apps access clean destroy load-test k6-web ports scan

help:
	@echo "Usage: make deploy"
	@echo "Available commands:"
	@echo "  deploy      - Full setup (Cluster + Monitoring Stack + Apps + Access)"
	@echo "  access      - Establish port-forwards and open services in browser"
	@echo "  ports       - Display access URLs and credentials"
	@echo "  load-test   - Run performance validation with K6"
	@echo "  clean       - Stop the cluster"
	@echo "  destroy     - Remove all data and uninstall tools"

deploy: check-deps cluster-up install-stack deploy-apps access

check-deps:
	@echo "==> [1/7] Validating Dependencies..."
	@command -v brew >/dev/null 2>&1 || { echo >&2 "Installing Homebrew..."; /bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; }
	@command -v colima >/dev/null 2>&1 || { echo >&2 "Installing Colima..."; brew install colima; }
	@command -v docker >/dev/null 2>&1 || { echo >&2 "Installing Docker CLI..."; brew install docker; }
	@command -v kubectl >/dev/null 2>&1 || { echo >&2 "Installing Kubectl..."; brew install kubectl; }
	@command -v helm >/dev/null 2>&1 || { echo >&2 "Installing Helm..."; brew install helm; }
	@command -v k6 >/dev/null 2>&1 || { echo >&2 "Installing K6..."; brew install k6; }

cluster-up:
	@echo "==> [2/7] Initializing Kubernetes Cluster (ARM64 Optimized)..."
	@if colima status >/dev/null 2>&1; then \
		echo "Cluster is already active."; \
	else \
		colima start --kubernetes --cpu 3 --memory 6 --arch arm64; \
	fi

install-stack:
	@echo "==> [3/7] Deploying Monitoring Stack (PLG + Icinga2)..."
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	@helm repo add grafana https://grafana.github.io/helm-charts
	@helm repo update
	@helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		--namespace $(NAMESPACE_MONITORING) --create-namespace \
		-f k8s/monitoring/values.yaml
	@helm upgrade --install loki grafana/loki-stack \
		--namespace $(NAMESPACE_MONITORING) --create-namespace
	@helm upgrade --install tempo grafana/tempo \
		--namespace $(NAMESPACE_MONITORING) --create-namespace
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
	@kubectl rollout status deployment/icinga2 -n $(NAMESPACE_MONITORING) --timeout=300s
	@kubectl wait --for=condition=ready pod -l release=loki -n $(NAMESPACE_MONITORING) --timeout=300s

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
	@sleep 5
	@$(MAKE) ports
	@echo "Opening services in browser..."
	@open http://localhost:$(GRAFANA_PORT)
	@open http://localhost:$(PROMETHEUS_PORT)
	@open http://localhost:$(PODINFO_PORT)
	@open http://localhost:$(LOKI_PORT)/ready
	@open https://localhost:$(ICINGA2_PORT)/v1/status

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
	@echo "  - Pass: $$(kubectl exec -n monitoring $$(kubectl get pods -n monitoring -l app=icinga2 -o jsonpath='{.items[0].metadata.name}') -- grep -oP 'password = \"\K[^\"]+' /etc/icinga2/conf.d/api-users.conf 2>/dev/null || echo 'Retrieve failed')"
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
