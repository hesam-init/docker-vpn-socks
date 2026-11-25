# Builds the images with plain `docker build` and runs the compose stacks.
# `docker compose build` is not used: Compose builds through bake, which refuses the
# templates' `network: host` unless it is explicitly allowed.
#
#   make                      ovpn-client:latest, openconnect-client:latest (same as `make build`)
#   make build-no-cache       same, ignoring the build cache
#   make ARGS=...             pass extra flags to docker build
#   make clean                remove the ovpn-client and openconnect-client images
#
#   Build mirrors (DOCKER_REGISTRY, ALPINE_APK_MIRROR) and optional default profiles
#   (COMPOSE_PROFILES) are read from .env, see .env.example;
#   unset or empty mirrors mean Docker Hub and the Alpine CDN
#
#   make up                   start the selected profile(s) in the background (default P=vpnbaz)
#   make down                 stop and remove containers (all profiles when P is empty)
#   make restart              restart containers for the selected profile(s)
#   make logs                 follow container logs (all profiles when P is empty)
#   make ps                   list containers (all profiles when P is empty)
#   make config               validate and print the resolved compose file
#   make profiles             list available profiles in the selected stack
#   STACK=...                 main|test (default main)
#   P=...                     comma- or space-separated profiles, e.g. `make up P="vpnbaz openconnect"`
#   S=...                     limit up/restart/logs to some services, e.g. `make logs P=bridge S=tci-bridge`
#
#   Compose: the `docker compose` v2 plugin when it exists, else legacy `docker-compose`
#   (e.g. 1.29 on Debian 12). Force one with COMPOSE_BIN=..., e.g. `make up COMPOSE_BIN=docker-compose`

# Compose resolves `context: ${PWD}/docker` from the environment; pin it to this directory (make -C safe)
export PWD := $(CURDIR)

# Optional build mirrors and profile defaults, plain KEY=value lines without quotes
-include .env
export DOCKER_REGISTRY ALPINE_APK_MIRROR

ARGS ?=
IMAGES := ovpn-client:latest openconnect-client:latest
DOCKER_DIR := docker
COMPOSE_DIR := $(DOCKER_DIR)/compose
DOCKER_BUILD := docker build --network host \
	--build-arg DOCKER_REGISTRY=$(DOCKER_REGISTRY) --build-arg ALPINE_APK_MIRROR=$(ALPINE_APK_MIRROR) $(ARGS)

STACK ?= main
P ?=
S ?=
DEFAULT_PROFILE ?= vpnbaz
COMMA := ,
STACK_FILE_main := docker-compose.yml
STACK_FILE_test := $(COMPOSE_DIR)/docker-compose.test.yml
STACK_FILE := $(STACK_FILE_$(STACK))
# v2 plugin if present, else v1; recursive, so it is only probed when a compose target runs
COMPOSE_BIN ?= $(shell docker compose version >/dev/null 2>&1 && echo 'docker compose' || echo docker-compose)
# Pinned here, not with a top-level `name:` in the compose files, which Compose v1 rejects
COMPOSE_PROJECT ?= docker-ovpn-socks
# Lazy, so an unknown STACK only errors when a compose target runs
COMPOSE = $(COMPOSE_BIN) -p $(COMPOSE_PROJECT) -f $(or $(STACK_FILE),$(error unknown STACK '$(STACK)', use main|test))

# Explicit --profile flags override .env COMPOSE_PROFILES; when P is unset, `up`/`restart`
# respect COMPOSE_PROFILES if set in .env and otherwise fall back to DEFAULT_PROFILE.
PROFILE_FLAGS = $(if $(strip $(P)),$(foreach p,$(subst $(COMMA), ,$(P)),--profile $(p)))
UP_PROFILE_FLAGS = $(if $(strip $(P)),$(PROFILE_FLAGS),$(if $(strip $(COMPOSE_PROFILES)),,--profile $(DEFAULT_PROFILE)))
ALL_PROFILE_FLAGS = $(if $(strip $(P)),$(PROFILE_FLAGS),--profile all --profile bridge --profile test)

.PHONY: all build build-no-cache clean up down restart logs ps config profiles

all: build

build:
	$(DOCKER_BUILD) -f $(DOCKER_DIR)/Dockerfile --target ovpn -t $(word 1,$(IMAGES)) $(CURDIR)/$(DOCKER_DIR)
	$(DOCKER_BUILD) -f $(DOCKER_DIR)/Dockerfile --target openconnect -t $(word 2,$(IMAGES)) $(CURDIR)/$(DOCKER_DIR)

build-no-cache:
	$(MAKE) build ARGS="$(ARGS) --no-cache"

# Fails for an image that a container still uses; `make down` first
clean:
	docker image rm $(IMAGES)

up:
	$(COMPOSE) $(UP_PROFILE_FLAGS) up -d $(S)

# No $(S): `down SERVICE` needs a newer Compose than some supported hosts ship
down:
	$(COMPOSE) $(ALL_PROFILE_FLAGS) down

restart:
	$(COMPOSE) $(UP_PROFILE_FLAGS) restart $(S)

logs:
	$(COMPOSE) $(ALL_PROFILE_FLAGS) logs -f $(S)

ps:
	$(COMPOSE) $(ALL_PROFILE_FLAGS) ps

config:
	$(COMPOSE) $(ALL_PROFILE_FLAGS) config

profiles:
	@$(COMPOSE) config --profiles 2>/dev/null || awk '/^[[:space:]]*profiles:/ { in_p=1; sub(/^[[:space:]]*profiles:[[:space:]]*/, ""); if ($$0 ~ /^\[/) { gsub(/[][ "]/, ""); n=split($$0,a,","); for(i=1;i<=n;i++) if(a[i]!="") print a[i]; in_p=0 } next } in_p && /^[[:space:]]*-[[:space:]]+/ { sub(/^[[:space:]]*-[[:space:]]+/, ""); gsub(/[" ]/, ""); if($$0!="") print $$0; next } in_p { in_p=0 }' $(STACK_FILE) | sort -u
