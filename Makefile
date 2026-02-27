# KOI-net local network orchestrator
# This Makefile automates clone/bootstrap/provision/run/query workflows.

SHELL := /bin/bash
.DEFAULT_GOAL := help

SUBDIRS = \
	koi-net-coordinator-node \
	koi-net-hackmd-sensor-node \
	koi-net-github-sensor-node \
	koi-net-text-normalizer-node \
	koi-net-text-search-node \
	koi-net-vector-search-node \
	koi-net-general-search-node

NODE_PORTS = 8080 8081 8082 8083 8084 8085 8086
LOG_DIR ?= logs
PID_DIR ?= .pids
LINES ?= 120
COORDINATOR_DELAY ?= 3
NODE_DELAY ?= 1
SENSOR_SETTLE_DELAY ?= 2
NORMALIZER_SETTLE_DELAY ?= 2
SEARCH_SETTLE_DELAY ?= 2
CONFIG_WAIT_SECONDS ?= 20
AUTO_RECLAIM_PORTS ?= 0
FINAL_SETTLE_DELAY ?= 5

# Query defaults
TYPE ?= hybrid
TOP_K ?= 10
TEXT_WEIGHT ?= 1.0
VECTOR_WEIGHT ?= 0.5
SIMILARITY_THRESHOLD ?= 0.0
TIMEOUT ?= 45

# Canonical repo URLs
REPO_COORDINATOR = https://github.com/BlockScience/koi-net-coordinator-node.git
REPO_HACKMD = https://github.com/BlockScience/koi-net-hackmd-sensor-node.git
REPO_GITHUB = https://github.com/BlockScience/koi-net-github-sensor-node.git
REPO_NORMALIZER = https://github.com/BlockScience/koi-net-text-normalizer-node.git
REPO_TEXT_SEARCH = https://github.com/BlockScience/koi-net-text-search-node.git
REPO_VECTOR_SEARCH = https://github.com/BlockScience/koi-net-vector-search-node.git
REPO_GENERAL_SEARCH = https://github.com/BlockScience/koi-net-general-search-node.git

.PHONY: help \
	clone env-init env-check set-shared-password configure-github configure-hackmd \
	sync-coordinator-contact sync-search-target-rids \
	preflight-ports \
	sync bootstrap \
	up ingest down stop restart status ports logs ps \
	query query-tail \
	coordinator hackmd github normalizer text vector general \
	lock clean

define clone_if_missing
	@if [ -d "$(1)/.git" ]; then \
		echo "SKIP  $(1) already cloned"; \
	else \
		echo "CLONE $(1)"; \
		git clone "$(2)" "$(1)"; \
	fi
endef

define start_node
	@mkdir -p "$(LOG_DIR)" "$(PID_DIR)"
	@if [ ! -d "$(1)" ]; then \
		echo "Missing repo '$(1)'. Run 'make clone' first."; \
		exit 1; \
	fi
	@if [ ! -f "$(1)/.env" ]; then \
		echo "Missing $(1)/.env. Run 'make env-init' and configure secrets."; \
		exit 1; \
	fi
	@if [ -f "$(PID_DIR)/$(1).pid" ] && kill -0 "$$(cat "$(PID_DIR)/$(1).pid")" 2>/dev/null; then \
		echo "SKIP  $(1) already running (pid $$(cat "$(PID_DIR)/$(1).pid"))"; \
	else \
		port_pids=$$(lsof -nP -iTCP:$(3) -sTCP:LISTEN -t 2>/dev/null || true); \
		if [ -n "$$port_pids" ]; then \
			if [ "$(AUTO_RECLAIM_PORTS)" = "1" ]; then \
				echo "RECLAIM port $(3) occupied by $$port_pids"; \
				kill $$port_pids 2>/dev/null || true; \
				sleep 0.5; \
				port_pids=$$(lsof -nP -iTCP:$(3) -sTCP:LISTEN -t 2>/dev/null || true); \
				if [ -n "$$port_pids" ]; then \
					echo "KILL  port $(3) occupied by $$port_pids"; \
					kill -9 $$port_pids 2>/dev/null || true; \
					sleep 0.2; \
				fi; \
			fi; \
		fi; \
		port_pids=$$(lsof -nP -iTCP:$(3) -sTCP:LISTEN -t 2>/dev/null || true); \
		if [ -n "$$port_pids" ]; then \
			echo "Port $(3) is still in use by $$port_pids; cannot start $(1)."; \
			echo "Run 'make down' or set AUTO_RECLAIM_PORTS=1"; \
			exit 1; \
		fi; \
		echo "START $(1) on port $(3)"; \
		( cd "$(1)" && env -u VIRTUAL_ENV UV_ENV_FILE=.env uv run python -m $(2) > "$(CURDIR)/$(LOG_DIR)/$(1).log" 2>&1 ) & \
		echo $$! > "$(CURDIR)/$(PID_DIR)/$(1).pid"; \
		sleep 0.8; \
		node_pid=$$(cat "$(CURDIR)/$(PID_DIR)/$(1).pid"); \
		if ! kill -0 "$$node_pid" 2>/dev/null; then \
			echo "$(1) exited during startup (pid $$node_pid)"; \
			if [ -f "$(CURDIR)/$(LOG_DIR)/$(1).log" ]; then \
				echo "--- $(1) log tail ---"; \
				tail -n 40 "$(CURDIR)/$(LOG_DIR)/$(1).log"; \
			fi; \
			exit 1; \
		fi; \
	fi
endef

help:
	@echo "KOI-net network orchestrator"
	@echo
	@echo "Bootstrap:"
	@echo "  make clone                Clone all node repos (idempotent)"
	@echo "  make env-init             Copy .env.example -> .env in each repo (idempotent)"
	@echo "  make set-shared-password PASSWORD='your-secret'"
	@echo "  make configure-github GITHUB_API_TOKEN=... GITHUB_REPOSITORIES='owner/repo,owner/repo'"
	@echo "  make configure-hackmd HACKMD_API_TOKEN=... [HACKMD_WORKSPACE_ID=...] [HACKMD_NOTE_IDS='id1,id2']"
	@echo "  make sync                 uv sync --refresh --reinstall in each repo"
	@echo "  make bootstrap            clone + env-init + sync"
	@echo
	@echo "Runtime:"
	@echo "  make up                   Start all nodes in protocol-safe order"
	@echo "                            Reclaims occupied listener ports in NODE_PORTS when AUTO_RECLAIM_PORTS=1"
	@echo "                            Automatically propagates COORDINATOR_RID/COORDINATOR_URL to all node .env files"
	@echo "                            Automatically propagates TEXT_SEARCH_NODE_RID/VECTOR_SEARCH_NODE_RID to general-search .env"
	@echo "                            Tunables: COORDINATOR_DELAY, SENSOR_SETTLE_DELAY, NORMALIZER_SETTLE_DELAY, SEARCH_SETTLE_DELAY, FINAL_SETTLE_DELAY, NODE_DELAY, AUTO_RECLAIM_PORTS"
	@echo "  make preflight-ports      Reclaim occupied listener ports before startup"
	@echo "  make sync-coordinator-contact  Sync coordinator RID/URL from coordinator config into node .env files"
	@echo "  make sync-search-target-rids   Sync text/vector node RIDs into general-search .env"
	@echo "  make down                 Stop all managed nodes"
	@echo "  make restart              down + up"
	@echo "  make status               Show expected listener status for ports 8080-8086"
	@echo "  make logs [LINES=120]     Tail all node logs"
	@echo
	@echo "Query:"
	@echo "  make query Q='search text' [TYPE=hybrid] [TOP_K=10] [TEXT_WEIGHT=1.0] [VECTOR_WEIGHT=0.5]"
	@echo "  make query-tail UUID='<query-uuid>'"
	@echo
	@echo "Foreground (single node):"
	@echo "  make coordinator | hackmd | github | normalizer | text | vector | general"

clone:
	$(call clone_if_missing,koi-net-coordinator-node,$(REPO_COORDINATOR))
	$(call clone_if_missing,koi-net-hackmd-sensor-node,$(REPO_HACKMD))
	$(call clone_if_missing,koi-net-github-sensor-node,$(REPO_GITHUB))
	$(call clone_if_missing,koi-net-text-normalizer-node,$(REPO_NORMALIZER))
	$(call clone_if_missing,koi-net-text-search-node,$(REPO_TEXT_SEARCH))
	$(call clone_if_missing,koi-net-vector-search-node,$(REPO_VECTOR_SEARCH))
	$(call clone_if_missing,koi-net-general-search-node,$(REPO_GENERAL_SEARCH))

env-init:
	@for dir in $(SUBDIRS); do \
		if [ ! -d "$$dir" ]; then \
			echo "SKIP  $$dir (missing, run make clone first)"; \
			continue; \
		fi; \
		if [ ! -f "$$dir/.env.example" ]; then \
			echo "SKIP  $$dir/.env.example missing"; \
			continue; \
		fi; \
		if [ -f "$$dir/.env" ]; then \
			echo "SKIP  $$dir/.env exists"; \
		else \
			cp "$$dir/.env.example" "$$dir/.env"; \
			echo "INIT  $$dir/.env"; \
		fi; \
	done

env-check:
	@missing=0; \
	for dir in $(SUBDIRS); do \
		if [ ! -f "$$dir/.env" ]; then \
			echo "MISSING $$dir/.env"; \
			missing=1; \
			continue; \
		fi; \
		if ! grep -q '^PRIV_KEY_PASSWORD=' "$$dir/.env"; then \
			echo "MISSING PRIV_KEY_PASSWORD in $$dir/.env"; \
			missing=1; \
		fi; \
	done; \
	if [ "$$missing" -ne 0 ]; then \
		echo "One or more env files are missing required values."; \
		exit 1; \
	fi; \
	echo "All repos have .env files with PRIV_KEY_PASSWORD entries."

set-shared-password:
	@[ -n "$(PASSWORD)" ] || { \
		echo "Usage: make set-shared-password PASSWORD='your-secret'"; \
		exit 1; \
	}
	@for dir in $(SUBDIRS); do \
		if [ -f "$$dir/.env" ]; then \
			./scripts/set_env_var.sh "$$dir/.env" "PRIV_KEY_PASSWORD" "$(PASSWORD)"; \
			echo "SET   $$dir/.env PRIV_KEY_PASSWORD"; \
		else \
			echo "SKIP  $$dir/.env missing"; \
		fi; \
	done

configure-github:
	@[ -n "$(GITHUB_API_TOKEN)" ] || { \
		echo "Usage: make configure-github GITHUB_API_TOKEN=... GITHUB_REPOSITORIES='owner/repo,owner/repo'"; \
		exit 1; \
	}
	@[ -f "koi-net-github-sensor-node/.env" ] || { \
		echo "Missing koi-net-github-sensor-node/.env (run make env-init)"; \
		exit 1; \
	}
	@./scripts/set_env_var.sh "koi-net-github-sensor-node/.env" "GITHUB_API_TOKEN" "$(GITHUB_API_TOKEN)"
	@./scripts/set_env_var.sh "koi-net-github-sensor-node/.env" "GITHUB_REPOSITORIES" "$(GITHUB_REPOSITORIES)"
	@echo "SET   koi-net-github-sensor-node/.env github settings"

configure-hackmd:
	@[ -n "$(HACKMD_API_TOKEN)" ] || { \
		echo "Usage: make configure-hackmd HACKMD_API_TOKEN=... [HACKMD_WORKSPACE_ID=...] [HACKMD_NOTE_IDS='id1,id2']"; \
		exit 1; \
	}
	@[ -f "koi-net-hackmd-sensor-node/.env" ] || { \
		echo "Missing koi-net-hackmd-sensor-node/.env (run make env-init)"; \
		exit 1; \
	}
	@./scripts/set_env_var.sh "koi-net-hackmd-sensor-node/.env" "HACKMD_API_TOKEN" "$(HACKMD_API_TOKEN)"
	@if [ -n "$(HACKMD_WORKSPACE_ID)" ]; then \
		./scripts/set_env_var.sh "koi-net-hackmd-sensor-node/.env" "HACKMD_WORKSPACE_ID" "$(HACKMD_WORKSPACE_ID)"; \
	fi
	@if [ -n "$(HACKMD_NOTE_IDS)" ]; then \
		./scripts/set_env_var.sh "koi-net-hackmd-sensor-node/.env" "HACKMD_NOTE_IDS" "$(HACKMD_NOTE_IDS)"; \
	fi
	@echo "SET   koi-net-hackmd-sensor-node/.env hackmd settings"

sync:
	@for dir in $(SUBDIRS); do \
		if [ ! -d "$$dir" ]; then \
			echo "SKIP  $$dir (missing, run make clone first)"; \
			continue; \
		fi; \
		echo "SYNC  $$dir"; \
		(cd "$$dir" && $(MAKE) sync) || exit 1; \
	done

bootstrap: clone env-init sync
	@echo "Bootstrap complete. Next: set secrets in .env files, then run 'make up'."

preflight-ports:
	@if [ "$(AUTO_RECLAIM_PORTS)" != "1" ]; then \
		echo "AUTO_RECLAIM_PORTS=$(AUTO_RECLAIM_PORTS), skipping preflight reclaim."; \
		exit 0; \
	fi
	@for port in $(NODE_PORTS); do \
		pids=$$(lsof -nP -iTCP:$$port -sTCP:LISTEN -t 2>/dev/null || true); \
		if [ -n "$$pids" ]; then \
			echo "RECLAIM preflight port $$port -> $$pids"; \
			kill $$pids 2>/dev/null || true; \
		fi; \
	done
	@sleep 0.5
	@for port in $(NODE_PORTS); do \
		pids=$$(lsof -nP -iTCP:$$port -sTCP:LISTEN -t 2>/dev/null || true); \
		if [ -n "$$pids" ]; then \
			echo "KILL  preflight port $$port -> $$pids"; \
			kill -9 $$pids 2>/dev/null || true; \
		fi; \
	done

sync-coordinator-contact:
	@cfg="koi-net-coordinator-node/config.yaml"; \
	logf="$(LOG_DIR)/koi-net-coordinator-node.log"; \
	pidf="$(PID_DIR)/koi-net-coordinator-node.pid"; \
	if [ ! -f "$$cfg" ]; then \
		echo "WAIT  coordinator config (up to $(CONFIG_WAIT_SECONDS)s)"; \
		waited=0; \
		while [ ! -f "$$cfg" ] && [ $$waited -lt $(CONFIG_WAIT_SECONDS) ]; do \
			if [ -f "$$pidf" ]; then \
				pid=$$(cat "$$pidf"); \
				if ! kill -0 "$$pid" 2>/dev/null; then \
					echo "Coordinator exited before generating $$cfg (pid $$pid)"; \
					if [ -f "$$logf" ]; then \
						echo "--- coordinator log tail ---"; \
						tail -n 40 "$$logf"; \
					fi; \
					exit 1; \
				fi; \
			fi; \
			sleep 1; \
			waited=$$((waited + 1)); \
		done; \
	fi; \
	if [ ! -f "$$cfg" ]; then \
		echo "Missing $$cfg after $(CONFIG_WAIT_SECONDS)s wait."; \
		if [ -f "$$logf" ]; then \
			echo "--- coordinator log tail ---"; \
			tail -n 40 "$$logf"; \
		fi; \
		exit 1; \
	fi; \
	coord_rid=$$(awk '/orn:koi-net.node:coordinator\+/{for(i=1;i<=NF;i++){if($$i ~ /^orn:koi-net.node:coordinator\+/){print $$i; exit}}}' "$$cfg"); \
	if [ -z "$$coord_rid" ]; then \
		echo "Could not parse coordinator RID from $$cfg"; \
		if [ -f "$$logf" ]; then \
			echo "--- coordinator log tail ---"; \
			tail -n 40 "$$logf"; \
		fi; \
		exit 1; \
	fi; \
	coord_url=$$(awk '/^[[:space:]]*base_url:[[:space:]]*http/{print $$2; exit}' "$$cfg"); \
	if [ -z "$$coord_url" ]; then \
		coord_url="http://127.0.0.1:8080/koi-net"; \
	fi; \
	for env_file in \
		"koi-net-hackmd-sensor-node/.env" \
		"koi-net-github-sensor-node/.env" \
		"koi-net-text-normalizer-node/.env" \
		"koi-net-text-search-node/.env" \
		"koi-net-vector-search-node/.env" \
		"koi-net-general-search-node/.env"; do \
		if [ -f "$$env_file" ]; then \
			./scripts/set_env_var.sh "$$env_file" "COORDINATOR_RID" "$$coord_rid"; \
			./scripts/set_env_var.sh "$$env_file" "COORDINATOR_URL" "$$coord_url"; \
			echo "SET   $$env_file coordinator contact"; \
		else \
			echo "SKIP  $$env_file missing"; \
		fi; \
	done; \
	echo "Coordinator contact propagated: RID=$$coord_rid URL=$$coord_url"

sync-search-target-rids:
	@text_cfg="koi-net-text-search-node/config.yaml"; \
	vector_cfg="koi-net-vector-search-node/config.yaml"; \
	general_env="koi-net-general-search-node/.env"; \
	text_log="$(LOG_DIR)/koi-net-text-search-node.log"; \
	vector_log="$(LOG_DIR)/koi-net-vector-search-node.log"; \
	text_pidf="$(PID_DIR)/koi-net-text-search-node.pid"; \
	vector_pidf="$(PID_DIR)/koi-net-vector-search-node.pid"; \
	waited=0; \
	while [ $$waited -lt $(CONFIG_WAIT_SECONDS) ]; do \
		ok=1; \
		if [ ! -f "$$text_cfg" ]; then ok=0; fi; \
		if [ ! -f "$$vector_cfg" ]; then ok=0; fi; \
		if [ "$$ok" -eq 1 ]; then break; fi; \
		if [ -f "$$text_pidf" ]; then \
			pid=$$(cat "$$text_pidf"); \
			if ! kill -0 "$$pid" 2>/dev/null; then \
				echo "text-search exited before generating $$text_cfg (pid $$pid)"; \
				if [ -f "$$text_log" ]; then echo "--- text-search log tail ---"; tail -n 40 "$$text_log"; fi; \
				exit 1; \
			fi; \
		fi; \
		if [ -f "$$vector_pidf" ]; then \
			pid=$$(cat "$$vector_pidf"); \
			if ! kill -0 "$$pid" 2>/dev/null; then \
				echo "vector-search exited before generating $$vector_cfg (pid $$pid)"; \
				if [ -f "$$vector_log" ]; then echo "--- vector-search log tail ---"; tail -n 40 "$$vector_log"; fi; \
				exit 1; \
			fi; \
		fi; \
		sleep 1; \
		waited=$$((waited + 1)); \
	done; \
	if [ ! -f "$$text_cfg" ]; then \
		echo "Missing $$text_cfg after $(CONFIG_WAIT_SECONDS)s wait."; \
		exit 1; \
	fi; \
	if [ ! -f "$$vector_cfg" ]; then \
		echo "Missing $$vector_cfg after $(CONFIG_WAIT_SECONDS)s wait."; \
		exit 1; \
	fi; \
	if [ ! -f "$$general_env" ]; then \
		echo "Missing $$general_env. Run make env-init first."; \
		exit 1; \
	fi; \
	text_rid=$$(awk '/orn:koi-net.node:text_search\+/{for(i=1;i<=NF;i++){if($$i ~ /^orn:koi-net.node:text_search\+/){print $$i; exit}}}' "$$text_cfg"); \
	vector_rid=$$(awk '/orn:koi-net.node:vector_search\+/{for(i=1;i<=NF;i++){if($$i ~ /^orn:koi-net.node:vector_search\+/){print $$i; exit}}}' "$$vector_cfg"); \
	if [ -z "$$text_rid" ]; then \
		echo "Could not parse text-search RID from $$text_cfg"; \
		exit 1; \
	fi; \
	if [ -z "$$vector_rid" ]; then \
		echo "Could not parse vector-search RID from $$vector_cfg"; \
		exit 1; \
	fi; \
	./scripts/set_env_var.sh "$$general_env" "TEXT_SEARCH_NODE_RID" "$$text_rid"; \
	./scripts/set_env_var.sh "$$general_env" "VECTOR_SEARCH_NODE_RID" "$$vector_rid"; \
	echo "General search targets propagated: TEXT_SEARCH_NODE_RID=$$text_rid VECTOR_SEARCH_NODE_RID=$$vector_rid"

up:
	$(call start_node,koi-net-coordinator-node,koi_net_coordinator_node,8080)
	@echo "WAIT  coordinator $(COORDINATOR_DELAY)s"
	@sleep $(COORDINATOR_DELAY)
	@$(MAKE) sync-coordinator-contact
	$(call start_node,koi-net-hackmd-sensor-node,koi_net_hackmd_sensor_node,8081)
	@sleep $(NODE_DELAY)
	$(call start_node,koi-net-github-sensor-node,koi_net_github_sensor_node,8082)
	@echo "WAIT  sensors settle $(SENSOR_SETTLE_DELAY)s"
	@sleep $(SENSOR_SETTLE_DELAY)
	$(call start_node,koi-net-text-normalizer-node,koi_net_text_normalizer_node,8083)
	@echo "WAIT  normalizer settle $(NORMALIZER_SETTLE_DELAY)s"
	@sleep $(NORMALIZER_SETTLE_DELAY)
	$(call start_node,koi-net-text-search-node,koi_net_text_search_node,8084)
	@sleep $(NODE_DELAY)
	$(call start_node,koi-net-vector-search-node,koi_net_vector_search_node,8085)
	@echo "WAIT  search nodes settle $(SEARCH_SETTLE_DELAY)s"
	@sleep $(SEARCH_SETTLE_DELAY)
	@$(MAKE) sync-search-target-rids
	$(call start_node,koi-net-general-search-node,koi_net_general_search_node,8086)
	@echo "WAIT  final stabilization $(FINAL_SETTLE_DELAY)s"
	@sleep $(FINAL_SETTLE_DELAY)
	@$(MAKE) status

ingest: up

down stop:
	@mkdir -p "$(PID_DIR)"
	@for pidf in "$(PID_DIR)"/*.pid; do \
		[ -e "$$pidf" ] || continue; \
		pid=$$(cat "$$pidf"); \
		if kill -0 "$$pid" 2>/dev/null; then \
			echo "STOP  pid $$pid ($$pidf)"; \
			kill "$$pid" 2>/dev/null || true; \
		fi; \
	done
	@sleep 0.5
	@for pidf in "$(PID_DIR)"/*.pid; do \
		[ -e "$$pidf" ] || continue; \
		pid=$$(cat "$$pidf"); \
		if kill -0 "$$pid" 2>/dev/null; then \
			echo "KILL  pid $$pid ($$pidf)"; \
			kill -9 "$$pid" 2>/dev/null || true; \
		fi; \
		rm -f "$$pidf"; \
	done
	@for port in $(NODE_PORTS); do \
		pids=$$(lsof -ti tcp:$$port 2>/dev/null); \
		if [ -n "$$pids" ]; then \
			echo "STOP  port $$port -> $$pids"; \
			kill $$pids 2>/dev/null || true; \
		fi; \
	done
	@sleep 0.3
	@for port in $(NODE_PORTS); do \
		pids=$$(lsof -ti tcp:$$port 2>/dev/null); \
		if [ -n "$$pids" ]; then \
			echo "KILL  port $$port -> $$pids"; \
			kill -9 $$pids 2>/dev/null || true; \
		fi; \
	done

restart: down up

ports status:
	@missing=0; \
	for port in $(NODE_PORTS); do \
		listener=$$(lsof -nP -iTCP:$$port -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $$1 " (pid " $$2 ")"}'); \
		if [ -n "$$listener" ]; then \
			echo "OK      $$port -> $$listener"; \
		else \
			echo "MISSING $$port"; \
			missing=1; \
		fi; \
	done; \
	if [ "$$missing" -ne 0 ]; then \
		echo "One or more required ports are not listening."; \
		exit 1; \
	fi; \
	echo "All node ports are listening."

ps:
	@for pidf in "$(PID_DIR)"/*.pid; do \
		[ -e "$$pidf" ] || continue; \
		pid=$$(cat "$$pidf"); \
		if kill -0 "$$pid" 2>/dev/null; then \
			echo "RUNNING $$pidf -> pid $$pid"; \
		else \
			echo "STALE   $$pidf -> pid $$pid"; \
		fi; \
	done

logs:
	@mkdir -p "$(LOG_DIR)"
	@tail -n $(LINES) -f "$(LOG_DIR)"/*.log

query:
	@[ -n "$(Q)" ] || { \
		echo "Usage: make query Q='what is koi?' [TYPE=hybrid] [TOP_K=10]"; \
		exit 1; \
	}
	@./scripts/run_query.sh \
		--query "$(Q)" \
		--type "$(TYPE)" \
		--top-k "$(TOP_K)" \
		--text-weight "$(TEXT_WEIGHT)" \
		--vector-weight "$(VECTOR_WEIGHT)" \
		--similarity-threshold "$(SIMILARITY_THRESHOLD)" \
		--timeout "$(TIMEOUT)"

query-tail:
	@[ -n "$(UUID)" ] || { \
		echo "Usage: make query-tail UUID='<query-uuid>'"; \
		exit 1; \
	}
	@cat "koi-net-general-search-node/results/$(UUID).json"

coordinator:
	(cd koi-net-coordinator-node && $(MAKE) run)

hackmd:
	(cd koi-net-hackmd-sensor-node && $(MAKE) run)

github:
	(cd koi-net-github-sensor-node && $(MAKE) run)

normalizer:
	(cd koi-net-text-normalizer-node && $(MAKE) run)

text:
	(cd koi-net-text-search-node && $(MAKE) run)

vector:
	(cd koi-net-vector-search-node && $(MAKE) run)

general:
	(cd koi-net-general-search-node && $(MAKE) run)

lock:
	@for dir in $(SUBDIRS); do \
		if [ -d "$$dir" ]; then \
			rm -f "$$dir/uv.lock"; \
			echo "RM    $$dir/uv.lock"; \
		fi; \
	done

clean:
	@for dir in $(SUBDIRS); do \
		if [ -d "$$dir" ]; then \
			(cd "$$dir" && $(MAKE) clean) || exit 1; \
		fi; \
	done
	@rm -rf "$(LOG_DIR)" "$(PID_DIR)"
