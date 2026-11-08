COMPOSE ?= docker compose
WAIT_TIMEOUT ?= 300

.PHONY: up test test-fast down shell-client

## Build, start, and wait until bootstrap has finished and services are healthy.
up:
	$(COMPOSE) build
	$(COMPOSE) run --rm --no-deps bootstrap pki
	$(COMPOSE) rm -sf step-ca
	@$(COMPOSE) up -d --wait --wait-timeout $(WAIT_TIMEOUT) || { \
	  echo "lab failed to start; bootstrap log:"; $(COMPOSE) logs --no-log-prefix bootstrap; exit 1; }
	@code=$$($(COMPOSE) ps -a --format '{{.ExitCode}}' bootstrap); \
	if [ "$$code" != "0" ]; then \
	  echo "bootstrap failed (exit $$code)"; $(COMPOSE) logs --no-log-prefix bootstrap; exit 1; \
	fi
	@echo "lab is up"

## Run every acceptance test; exits non-zero if any fails.
test:
	tests/run.sh

## Same, without tests that wait for certificates to expire.
test-fast:
	tests/run.sh --fast

## Remove containers, volumes (and with them every generated key and token).
down:
	@# Leftovers of an interrupted AC-05 run (tests/ac/05-no-admin.sh).
	@docker rm -f -v lampson-lab-step-ca-policy-probe >/dev/null 2>&1 || true
	@# ... and of EP-11 (tests/ac/23-session-limit.sh), on the lab network.
	@docker rm -f -v lampson-lab-session-probe >/dev/null 2>&1 || true
	$(COMPOSE) down -v --remove-orphans
	@docker network rm lampson-lab-policy-probe >/dev/null 2>&1 || true
	@# Also volumes compose no longer declares (renamed or dropped in an older
	@# version of this lab), so no key outlives `make down`.
	@docker volume ls -q --filter label=com.docker.compose.project=lampson-lab | xargs -r docker volume rm

shell-client:
	$(COMPOSE) exec client bash
