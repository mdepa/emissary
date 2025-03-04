# A quick primer on GNU Make syntax
# =================================
#
# This tries to cover the syntax that is hard to ctrl-f for in
# <https://www.gnu.org/software/make/manual/make.html> (err, hard to
# C-s for in `M-: (info "Make")`).
#
#   At the core is a "rule":
#
#       target: dependency1 dependency2
#       	command to run
#
#   If `target` something that isn't a real file (like 'build', 'lint', or
#   'test'), then it should be marked as "phony":
#
#       target: dependency1 dependency2
#       	command to run
#       .PHONY: target
#
#   You can write reusable "pattern" rules:
#
#       %.o: %.c
#       	command to run
#
#   Of course, if you don't have variables for the inputs and outputs,
#   it's hard to write a "command to run" for a pattern rule.  The
#   variables that you should know are:
#
#       $@ = the target
#       $^ = the list of dependencies (space separated)
#       $< = the first (left-most) dependency
#       $* = the value of the % glob in a pattern rule
#
#       Each of these have $(@D) and $(@F) variants that are the
#       directory-part and file-part of each value, respectively.
#
#       I think those are easy enough to remember mnemonically:
#         - $@ is where you shoul direct the output at.
#         - $^ points up at the dependency list
#         - $< points at the left-most member of the dependency list
#         - $* is the % glob; "*" is well-known as the glob char in other languages
#
#   Make will do its best to guess whether to apply a pattern rule for a
#   given file.  Or, you can explicitly tell it by using a 3-field
#   (2-colon) version:
#
#       foo.o bar.o: %.o: %.c
#       	command to run
#
#   In a non-pattern rule, if there are multiple targets listed, then it
#   is as if rule were duplicated for each target:
#
#       target1 target2: deps
#       	command to run
#
#       # is the same as
#
#       target1: deps
#       	command to run
#       target2: deps
#       	command to run
#
#   Because of this, if you have a command that generates multiple,
#   outputs, it _must_ be a pattern rule:
#
#       %.c %.h: %.y
#       	command to run
#
#   Normally, Make crawls the entire tree of dependencies, updating a file
#   if any of its dependencies have been updated.  There's a really poorly
#   named feature called "order-only" dependencies:
#
#       target: normal-deps | order-only-deps
#
#   Dependencies after the "|" are created if they don't exist, but if
#   they already exist, then don't bother updating them.
#
# Tips:
# -----
#
#  - Use absolute filenames.  It's dumb, but it really does result in
#    fewer headaches.  Use $(OSS_HOME) and $(AES_HOME) to spell the
#    absolute filenames.
#
#  - If you have a multiple-output command where the output files have
#    dissimilar names, have % be just the directory (the above tip makes
#    this easier).
#
#  - It can be useful to use the 2-colon form of a pattern rule when
#    writing a rule for just one file; it lets you use % and $* to avoid
#    repeating yourself, which can be especially useful with long
#    filenames.

BUILDER_HOME := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

LCNAME := $(shell echo $(NAME) | tr '[:upper:]' '[:lower:]')
BUILDER_NAME ?= $(LCNAME)

.DEFAULT_GOAL = all
include $(OSS_HOME)/build-aux/prelude.mk
include $(OSS_HOME)/build-aux/colors.mk

docker.tag.local = $(BUILDER_NAME).local/$(*F)
docker.tag.remote = $(if $(DEV_REGISTRY),,$(error $(REGISTRY_ERR)))$(DEV_REGISTRY)/$(*F):$(shell docker image inspect --format='{{slice (index (split .Id ":") 1) 0 12}}' $$(cat $<))
include $(OSS_HOME)/build-aux/docker.mk

include $(OSS_HOME)/build-aux/teleproxy.mk

MODULES :=

module = $(eval MODULES += $(1))$(eval SOURCE_$(1)=$(abspath $(2)))

BUILDER = BUILDER_NAME=$(BUILDER_NAME) $(abspath $(BUILDER_HOME)/builder.sh)
DBUILD = $(abspath $(BUILDER_HOME)/dbuild.sh)
COPY_GOLD = $(abspath $(BUILDER_HOME)/copy-gold.sh)

AWS_S3_BUCKET = datawire-static-files

# the image used for running the Ingress v1 tests with KIND.
# the current, official image does not support Ingress v1, so we must build our own image with k8s 1.18.
# build this image with:
# 1. checkout the Kuberentes sources in a directory like "~/sources/kubernetes"
# 2. kind build node-image --kube-root ~/sources/kubernetes
# 3. docker tag kindest/node:latest docker.io/datawire/kindest-node:latest
# 4. docker push docker.io/datawire/kindest-node:latest
# This will not be necessary once the KIND images are built for a Kubernetes 1.18 and support Ingress v1beta1 improvements.
KIND_IMAGE ?= kindest/node:v1.18.0
#KIND_IMAGE ?= docker.io/datawire/kindest-node:latest
KIND_KUBECONFIG = /tmp/kind-kubeconfig

# The ingress conformance tests directory
# build this image with:
# 1. checkout https://github.com/kubernetes-sigs/ingress-controller-conformance
# 2. cd ingress-controller-conformance && make image
# 3. docker tag ingress-controller-conformance:latest docker.io/datawire/ingress-controller-conformance:latest
# 4. docker push docker.io/datawire/ingress-controller-conformance:latest
INGRESS_TEST_IMAGE ?= docker.io/datawire/ingress-controller-conformance:latest

# local ports for the Ingress conformance tests
INGRESS_TEST_LOCAL_PLAIN_PORT = 8000
INGRESS_TEST_LOCAL_TLS_PORT = 8443
INGRESS_TEST_LOCAL_ADMIN_PORT = 8877

# directory with the manifests for loading Ambassador for running the Ingress Conformance tests
# NOTE: these manifests can be slightly different to the regular ones asd they include
INGRESS_TEST_MANIF_DIR = $(BUILDER_HOME)/../manifests/emissary/
INGRESS_TEST_MANIFS = ambassador-crds.yaml ambassador.yaml

all: help
.PHONY: all

.NOTPARALLEL:

# the name of the Docker network
# note: use your local k3d/microk8s/kind network for running tests
DOCKER_NETWORK ?= $(BUILDER_NAME)

# local host IP address (and not 127.0.0.1)
ifneq ($(shell which ipconfig 2>/dev/null),)
  # macOS
  HOST_IP := $(shell ipconfig getifaddr $$(route get 1.1.1.1 | awk '/interface:/ {print $$2}'))
else ifneq ($(shell which ip 2>/dev/null),)
  # modern (iproute2) GNU/Linux
  #HOST_IP := $(shell ip --json route get to 1.1.1.1 | jq -r '.[0].prefsrc')
  HOST_IP := $(shell ip route get to 1.1.1.1 | sed -n '1s/.*src \([0-9.]\+\).*/\1/p')
else
  $(error I do not know how to get the host IP on this system; it has neither 'ipconfig' (macOS) nor 'ip' (modern GNU/Linux))
  # ...and I (lukeshu) couldn't figure out a good way to do it on old (net-tools) GNU/Linux.
endif

noop:
	@true
.PHONY: noop

RSYNC_ERR  = $(RED)ERROR: please update to a version of rsync with the --info option$(END)
GO_ERR     = $(RED)ERROR: please update to go 1.13 or newer$(END)
DOCKER_ERR = $(RED)ERROR: please update to a version of docker built with Go 1.13 or newer$(END)

preflight:
	@printf "$(CYN)==> $(GRN)Preflight checks$(END)\n"

	@echo "Checking that 'rsync' is installed and is new enough to support '--info'"
	@$(if $(shell rsync --help 2>/dev/null | grep -F -- --info),,printf '%s\n' $(call quote.shell,$(RSYNC_ERR)))

	@echo "Checking that 'go' is installed and is 1.13 or later"
	@$(if $(call _prelude.go.VERSION.HAVE,1.13),,printf '%s\n' $(call quote.shell,$(GO_ERR)))

	@echo "Checking that 'docker' is installed and supports the 'slice' function for '--format'"
	@$(if $(and $(shell which docker 2>/dev/null),\
	            $(call _prelude.go.VERSION.ge,$(patsubst go%,%,$(lastword $(shell go version $$(which docker)))),1.13)),\
	      ,\
	      printf '%s\n' $(call quote.shell,$(DOCKER_ERR)))
.PHONY: preflight

preflight-cluster:
	@test -n "$(DEV_KUBECONFIG)" || (printf "$${KUBECONFIG_ERR}\n"; exit 1)
	@if [ "$(DEV_KUBECONFIG)" == '-skip-for-release-' ]; then \
		printf "$(CYN)==> $(RED)Skipping test cluster checks$(END)\n" ;\
	else \
		printf "$(CYN)==> $(GRN)Checking for test cluster$(END)\n" ;\
		success=; \
		for i in {1..5}; do \
			kubectl --kubeconfig $(DEV_KUBECONFIG) -n default get service kubernetes > /dev/null && success=true && break || sleep 15 ; \
		done; \
		if [ ! "$${success}" ] ; then { printf "$$KUBECTL_ERR\n" ; exit 1; } ; fi; \
	fi
.PHONY: preflight-cluster

sync: docker/container.txt
	@printf "${CYN}==> ${GRN}Syncing sources in to builder container${END}\n"
	@$(foreach MODULE,$(MODULES),$(BUILDER) sync $(MODULE) $(SOURCE_$(MODULE)) &&) true
	@if [ -n "$(DEV_KUBECONFIG)" ] && [ "$(DEV_KUBECONFIG)" != '-skip-for-release-' ]; then \
		kubectl --kubeconfig $(DEV_KUBECONFIG) config view --flatten | docker exec -i $$(cat $<) sh -c "cat > /buildroot/kubeconfig.yaml" ;\
	fi
	@if [ -e ~/.docker/config.json ]; then \
		cat ~/.docker/config.json | docker exec -i $$(cat $<) sh -c "mkdir -p /home/dw/.docker && cat > /home/dw/.docker/config.json" ; \
	fi
	@if [ -n "$(GCLOUD_CONFIG)" ]; then \
		printf "Copying gcloud config to builder container\n"; \
		docker cp $(GCLOUD_CONFIG) $$(cat $<):/home/dw/.config/; \
	fi
.PHONY: sync

builder:
	@$(BUILDER) builder
.PHONY: builder

version:
	@$(BUILDER) version
.PHONY: version

raw-version:
	@$(BUILDER) raw-version
.PHONY: raw-version

python/ambassador.version:
	$(BUILDER) raw-version > python/ambassador.version
.PHONY: python/ambassador.version

compile: sync
	@$(BUILDER) compile
.PHONY: compile

# For files that should only-maybe update when the rule runs, put ".stamp" on
# the left-side of the ":", and just go ahead and update it within the rule.
#
# ".stamp" should NEVER appear in a dependency list (that is, it
# should never be on the right-side of the ":"), save for in this rule
# itself.
%: %.stamp $(COPY_IFCHANGED)
	@$(COPY_IFCHANGED) $< $@

# Give Make a hint about which pattern rules to apply.  Honestly, I'm
# not sure why Make isn't figuring it out on its own, but it isn't.
_images = builder-base base-envoy $(LCNAME) $(LCNAME)-ea kat-client kat-server
$(foreach i,$(_images), docker/$i.docker.tag.local  ): docker/%.docker.tag.local : docker/%.docker
$(foreach i,$(_images), docker/$i.docker.tag.remote ): docker/%.docker.tag.remote: docker/%.docker

docker/builder-base.docker.stamp: FORCE preflight
	@printf "${CYN}==> ${GRN}Bootstrapping builder base image${END}\n"
	@$(BUILDER) build-builder-base >$@
docker/container.txt.stamp: %/container.txt.stamp: %/builder-base.docker.tag.local %/base-envoy.docker.tag.local FORCE
	@printf "${CYN}==> ${GRN}Bootstrapping builder container${END}\n"
	@($(BOOTSTRAP_EXTRAS) $(BUILDER) bootstrap > $@)

docker/base-envoy.docker.stamp: FORCE
	@set -e; { \
	  if docker image inspect $(ENVOY_DOCKER_TAG) --format='{{ .Id }}' >$@ 2>/dev/null; then \
	    printf "${CYN}==> ${GRN}Base Envoy image is already pulled${END}\n"; \
	  else \
	    printf "${CYN}==> ${GRN}Pulling base Envoy image${END}\n"; \
	    TIMEFORMAT="     (docker pull took %1R seconds)"; \
	    time docker pull $(ENVOY_DOCKER_TAG); \
	    unset TIMEFORMAT; \
	    docker image inspect $(ENVOY_DOCKER_TAG) --format='{{ .Id }}' >$@; \
	  fi; \
	}
docker/$(LCNAME).docker.stamp: %/$(LCNAME).docker.stamp: %/base-envoy.docker.tag.local %/builder-base.docker $(BUILDER_HOME)/Dockerfile FORCE
	@set -e; { \
	    printf "${CYN}==> ${GRN}Building image ${BLU}$(LCNAME)${END}\n"; \
	    printf "    ${BLU}envoy=$$(cat $*/base-envoy.docker)${END}\n"; \
	    printf "    ${BLU}builderbase=$$(cat $*/builder-base.docker)${END}\n"; \
	    TIMEFORMAT="     (docker build took %1R seconds)"; \
	    time ${DBUILD} -f ${BUILDER_HOME}/Dockerfile . \
	      --build-arg=envoy="$$(cat $*/base-envoy.docker)" \
	      --build-arg=builderbase="$$(cat $*/builder-base.docker)" \
	      --target=ambassador \
	      --iidfile=$@; \
	    unset TIMEFORMAT; \
	}

docker/$(LCNAME)-ea.docker.stamp: %/$(LCNAME)-ea.docker.stamp: %/$(LCNAME).docker FORCE
	@set -e; { \
	  printf "${CYN}==> ${GRN}Promoting ${BLU}$$(cat docker/$(LCNAME).docker)${END} to EA as ${BLU}$(LCNAME)-ea${END}\n"; \
	  cat docker/$(LCNAME).docker > $@; \
	}

docker/kat-client.docker.stamp: %/kat-client.docker.stamp: %/base-envoy.docker.tag.local %/builder-base.docker $(BUILDER_HOME)/Dockerfile FORCE
	@set -e; { \
	  printf "${CYN}==> ${GRN}Building image ${BLU}kat-client${END}\n"; \
	  TIMEFORMAT="     (kat-client build took %1R seconds)"; \
	  time ${DBUILD} -f ${BUILDER_HOME}/Dockerfile . \
	    --build-arg=envoy="$$(cat $*/base-envoy.docker)" \
	    --build-arg=builderbase="$$(cat $*/builder-base.docker)" \
	    --target=kat-client \
	    --iidfile=$@; \
	  unset TIMEFORMAT; \
	}
docker/kat-server.docker.stamp: %/kat-server.docker.stamp: %/base-envoy.docker.tag.local %/builder-base.docker $(BUILDER_HOME)/Dockerfile FORCE
	@set -e; { \
	  printf "${CYN}==> ${GRN}Building image ${BLU}kat-server${END}\n"; \
	  TIMEFORMAT="     (kat-server build took %1R seconds)"; \
	  time ${DBUILD} -f ${BUILDER_HOME}/Dockerfile . \
	    --build-arg=envoy="$$(cat $*/base-envoy.docker)" \
	    --build-arg=builderbase="$$(cat $*/builder-base.docker)" \
	    --target=kat-server \
	    --iidfile=$@; \
	  unset TIMEFORMAT; \
	}

REPO=$(BUILDER_NAME)

images: docker/$(LCNAME).docker.tag.local
images: docker/$(LCNAME)-ea.docker.tag.local
images: docker/kat-client.docker.tag.local
images: docker/kat-server.docker.tag.local
.PHONY: images

REGISTRY_ERR  = $(RED)
REGISTRY_ERR += $(NL)ERROR: please set the DEV_REGISTRY make/env variable to the docker registry
REGISTRY_ERR += $(NL)       you would like to use for development
REGISTRY_ERR += $(END)

push: docker/$(LCNAME).docker.push.remote
push: docker/$(LCNAME)-ea.docker.push.remote
push: docker/kat-client.docker.push.remote
push: docker/kat-server.docker.push.remote
.PHONY: push

push-dev: docker/$(LCNAME).docker.tag.local docker/$(LCNAME)-ea.docker.tag.local
	@set -e; { \
		if [ -n "$(IS_DIRTY)" ]; then \
			echo "push-dev: tree must be clean" >&2 ;\
			exit 1 ;\
		fi; \
		check=$$(echo $(BUILD_VERSION) | grep -c -e -dev || true) ;\
		if [ $$check -lt 1 ]; then \
			printf "$(RED)push-dev: BUILD_VERSION $(BUILD_VERSION) is not a dev version$(END)\n" >&2 ;\
			exit 1 ;\
		fi ;\
		suffix=$$(echo $(BUILD_VERSION) | sed -e 's/\+/-/') ;\
		chartsuffix=$${suffix#*-} ; \
		for image in $(LCNAME) $(LCNAME)-ea; do \
			tag="$(DEV_REGISTRY)/$$image:$${suffix}" ;\
			printf "$(CYN)==> $(GRN)pushing $(BLU)$$image$(GRN) as $(BLU)$$tag$(GRN)...$(END)\n" ;\
			docker tag $$(cat docker/$$image.docker) $$tag && \
			docker push $$tag ;\
		done ;\
		commit=$$(git rev-parse HEAD) ;\
		printf "$(CYN)==> $(GRN)recording $(BLU)$$commit$(GRN) => $(BLU)$$suffix$(GRN) in S3...$(END)\n" ;\
		echo "$$suffix" | aws s3 cp - s3://$(AWS_S3_BUCKET)/dev-builds/$$commit ;\
		$(MAKE) \
			CHART_VERSION_SUFFIX=-$$chartsuffix \
			IMAGE_TAG=$${suffix} \
			IMAGE_REPO="$(DEV_REGISTRY)/$(LCNAME)" \
			chart-push-ci ; \
		$(MAKE) update-yaml --always-make; \
		$(MAKE) VERSION_OVERRIDE=$$suffix push-manifests  ; \
		$(MAKE) clean-manifests ; \
	}
.PHONY: push-dev

push-nightly: docker/$(LCNAME).docker.tag.local docker/$(LCNAME)-ea.docker.tag.local
	@set -e; { \
		if [ -n "$(IS_DIRTY)" ]; then \
			echo "push-nightly: tree must be clean" >&2 ;\
			exit 1 ;\
		fi; \
		now=$$(date +"%Y%m%dT%H%M%S") ;\
		today=$$(date +"%Y%m%d") ;\
		base_version=$$(echo $(BUILD_VERSION) | cut -d- -f1) ;\
		for image in $(LCNAME) $(LCNAME)-ea; do \
			for suffix in "$$now" "$$today"; do \
				tag="$(DEV_REGISTRY)/$$image:$${base_version}-nightly.$${suffix}" ;\
				printf "$(CYN)==> $(GRN)pushing $(BLU)$$image$(GRN) as $(BLU)$$tag$(GRN)...$(END)\n" ;\
				docker tag $$(cat docker/$$image.docker) $$tag && \
				docker push $$tag ;\
			done ;\
		done ;\
		CHART_VERSION_SUFFIX=-nightly.$$today ;\
		IMAGE_TAG=$${base_version}$${CHART_VERSION_SUFFIX} ;\
		$(MAKE) \
			CHART_VERSION_SUFFIX="$${CHART_VERSION_SUFFIX}" \
			IMAGE_TAG="$${IMAGE_TAG}" \
			IMAGE_REPO="$(DEV_REGISTRY)/$(LCNAME)" \
			chart-push-ci ; \
		$(MAKE) update-yaml --always-make; \
		$(MAKE) VERSION_OVERRIDE=$${base_version}-nightly.$${suffix} push-manifests  ; \
		$(MAKE) clean-manifests ; \
	}
.PHONY: push-nightly

export KUBECONFIG_ERR=$(RED)ERROR: please set the $(BLU)DEV_KUBECONFIG$(RED) make/env variable to the cluster\n       you would like to use for development. Note this cluster must have access\n       to $(BLU)DEV_REGISTRY$(RED) (currently $(BLD)$(DEV_REGISTRY)$(END)$(RED))$(END)
export KUBECTL_ERR=$(RED)ERROR: preflight kubectl check failed$(END)

test-ready: push preflight-cluster
.PHONY: test-ready

PYTEST_ARGS ?=
export PYTEST_ARGS

PYTEST_GOLD_DIR ?= $(abspath python/tests/gold)

# Internal target for running a bash shell.
_bash:
	@PS1="\u:\w $$ " /bin/bash
.PHONY: _bash

# Internal runner target that executes an entrypoint after setting up the user's UID/GUID etc.
_runner:
	@printf "$(CYN)==>$(END) * Creating group $(BLU)$$INTERACTIVE_GROUP$(END) with GID $(BLU)$$INTERACTIVE_GID$(END)\n"
	@addgroup -g $$INTERACTIVE_GID $$INTERACTIVE_GROUP
	@printf "$(CYN)==>$(END) * Creating user $(BLU)$$INTERACTIVE_USER$(END) with UID $(BLU)$$INTERACTIVE_UID$(END)\n"
	@adduser -u $$INTERACTIVE_UID -G $$INTERACTIVE_GROUP $$INTERACTIVE_USER -D
	@printf "$(CYN)==>$(END) * Adding user $(BLU)$$INTERACTIVE_USER$(END) to $(BLU)/etc/sudoers$(END)\n"
	@echo "$$INTERACTIVE_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers
	@printf "$(CYN)==>$(END) * Switching to user $(BLU)$$INTERACTIVE_USER$(END) with shell $(BLU)/bin/bash$(END)\n"
	@su -s /bin/bash $$INTERACTIVE_USER -c "$$ENTRYPOINT"
.PHONY: _runner

# This target is a convenience alias for running the _bash target.
docker/shell: docker/run/_bash
.PHONY: docker/shell

# This target runs any existing target inside of the builder base docker image.
docker/run/%: docker/builder-base.docker
	docker run --net=host \
		-e INTERACTIVE_UID=$$(id -u) \
		-e INTERACTIVE_GID=$$(id -g) \
		-e INTERACTIVE_USER=$$(id -u -n) \
		-e INTERACTIVE_GROUP=$$(id -g -n) \
		-e PYTEST_ARGS="$$PYTEST_ARGS" \
		-e AMBASSADOR_DOCKER_IMAGE="$$AMBASSADOR_DOCKER_IMAGE" \
		-e KAT_CLIENT_DOCKER_IMAGE="$$KAT_CLIENT_DOCKER_IMAGE" \
		-e KAT_SERVER_DOCKER_IMAGE="$$KAT_SERVER_DOCKER_IMAGE" \
		-e DEV_KUBECONFIG="$$DEV_KUBECONFIG" \
		-v /etc/resolv.conf:/etc/resolv.conf \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v $${DEV_KUBECONFIG}:$${DEV_KUBECONFIG} \
		-v $${PWD}:$${PWD} \
		-it \
		--init \
		--cap-add=NET_ADMIN \
		--entrypoint /bin/bash \
		$$(cat docker/builder-base.docker) -c "cd $$PWD && ENTRYPOINT=make\ $* make --quiet _runner"

# Don't try running 'make shell' from within docker. That target already tries to run a builder shell.
# Instead, quietly define 'docker/run/shell' to be an alias for 'docker/shell'.
docker/run/shell:
	$(MAKE) --quiet docker/shell

setup-envoy: extract-bin-envoy

pytest: setup-diagd setup-envoy $(OSS_HOME)/bin/kubestatus proxy
	@printf "$(CYN)==> $(GRN)Running $(BLU)py$(GRN) tests$(END)\n"
	@echo "AMBASSADOR_DOCKER_IMAGE=$$AMBASSADOR_DOCKER_IMAGE"
	@echo "KAT_CLIENT_DOCKER_IMAGE=$$KAT_CLIENT_DOCKER_IMAGE"
	@echo "KAT_SERVER_DOCKER_IMAGE=$$KAT_SERVER_DOCKER_IMAGE"
	@echo "DEV_KUBECONFIG=$$DEV_KUBECONFIG"
	. $(OSS_HOME)/venv/bin/activate; \
		$(OSS_HOME)/builder/builder.sh pytest-local
.PHONY: pytest

pytest-integration:
	@printf "$(CYN)==> $(GRN)Running $(BLU)py$(GRN) integration tests$(END)\n"
	$(MAKE) pytest PYTEST_ARGS="$$PYTEST_ARGS python/tests/integration"
.PHONY: pytest-integration

pytest-kat:
	@printf "$(CYN)==> $(GRN)Running $(BLU)py$(GRN) kat tests$(END)\n"
	$(MAKE) pytest PYTEST_ARGS="$$PYTEST_ARGS python/tests/kat"
.PHONY: pytest-kat

extract-bin-envoy:
	@mkdir -p $(OSS_HOME)/bin/
	@rm -f $(OSS_HOME)/bin/envoy
	@printf "Extracting envoy binary to $(OSS_HOME)/bin/envoy\n"
	# Note that the call to `id -u` and `id -g` below are run in _this_ shell, not the docker container.
	# That has the desired effect of chown'ing the output binary to the calling user/group.
	@docker run -v $(OSS_HOME)/bin/:/output/ --rm -it --entrypoint /bin/bash $$AMBASSADOR_DOCKER_IMAGE -c "cp /usr/local/bin/envoy /output/envoy && chown $$(id -u):$$(id -g) /output/envoy"
.PHONY: extract-bin-envoy

$(OSS_HOME)/bin/kubestatus:
	@(cd $(OSS_HOME) && mkdir -p bin && go build -o bin/kubestatus ./cmd/busyambassador)

pytest-builder: test-ready
	$(MAKE) pytest-builder-only
.PHONY: pytest-builder

pytest-envoy:
	$(MAKE) pytest KAT_RUN_MODE=envoy
.PHONY: pytest-envoy

pytest-envoy-builder:
	$(MAKE) pytest-builder KAT_RUN_MODE=envoy
.PHONY: pytest-envoy-builder

pytest-envoy-v2:
	$(MAKE) pytest KAT_RUN_MODE=envoy AMBASSADOR_ENVOY_API_VERSION=V2
.PHONY: pytest-envoy-v2

pytest-envoy-v2-builder:
	$(MAKE) pytest-builder KAT_RUN_MODE=envoy AMBASSADOR_ENVOY_API_VERSION=V2
.PHONY: pytest-envoy-v2-builder

pytest-builder-only: sync preflight-cluster | docker/$(LCNAME).docker.push.remote docker/kat-client.docker.push.remote docker/kat-server.docker.push.remote
	@printf "$(CYN)==> $(GRN)Running $(BLU)py$(GRN) tests in builder shell$(END)\n"
	docker exec \
		-e AMBASSADOR_DOCKER_IMAGE=$$(sed -n 2p docker/$(LCNAME).docker.push.remote) \
		-e AMBASSADOR_EA_DOCKER_IMAGE=$$(sed -n 2p docker/$(LCNAME)-ea.docker.push.remote) \
		-e KAT_CLIENT_DOCKER_IMAGE=$$(sed -n 2p docker/kat-client.docker.push.remote) \
		-e KAT_SERVER_DOCKER_IMAGE=$$(sed -n 2p docker/kat-server.docker.push.remote) \
		-e KAT_IMAGE_PULL_POLICY=Always \
		-e DOCKER_NETWORK=$(DOCKER_NETWORK) \
		-e KAT_REQ_LIMIT \
		-e KAT_RUN_MODE \
		-e KAT_VERBOSE \
		-e PYTEST_ARGS \
		-e TEST_SERVICE_REGISTRY \
		-e TEST_SERVICE_VERSION \
		-e DEV_USE_IMAGEPULLSECRET \
		-e DEV_REGISTRY \
		-e DOCKER_BUILD_USERNAME \
		-e DOCKER_BUILD_PASSWORD \
		-e AMBASSADOR_ENVOY_API_VERSION \
		-e AMBASSADOR_LEGACY_MODE \
		-e AMBASSADOR_FAST_RECONFIGURE \
		-e AWS_SECRET_ACCESS_KEY \
		-e AWS_ACCESS_KEY_ID \
		-e AWS_SESSION_TOKEN \
		-it $(shell $(BUILDER)) /buildroot/builder.sh pytest-internal ; test_exit=$$? ; \
		[ -n "$(TEST_XML_DIR)" ] && docker cp $(shell $(BUILDER)):/tmp/test-data/pytest.xml $(TEST_XML_DIR) ; exit $$test_exit
.PHONY: pytest-builder-only

pytest-gold:
	sh $(COPY_GOLD) $(PYTEST_GOLD_DIR)

mypy-server-stop: sync
	docker exec -it $(shell $(BUILDER)) /buildroot/builder.sh mypy-internal stop
.PHONY: mypy

mypy-server: sync
	docker exec -it $(shell $(BUILDER)) /buildroot/builder.sh mypy-internal start
.PHONY: mypy

mypy: mypy-server
	docker exec -it $(shell $(BUILDER)) /buildroot/builder.sh mypy-internal check
.PHONY: mypy

GOTEST_PKGS = github.com/datawire/ambassador/...
GOTEST_MODDIRS = $(OSS_HOME)
export GOTEST_PKGS
export GOTEST_MODDIRS

GOTEST_ARGS ?= -race -count=1
export GOTEST_ARGS

create-venv:
	[[ -d $(OSS_HOME)/venv ]] || python3 -m venv $(OSS_HOME)/venv
.PHONY: create-venv

# If we're setting up within Alpine linux, make sure to pin pip and pip-tools
# to something that is still PEP517 compatible. This allows us to set _manylinux.py
# and convince pip to install prebuilt wheels. We do this because there's no good
# rust toolchain to build orjson within Alpine itself.
setup-venv:
	@set -e; { \
		if [ -f /etc/issue ] && grep "Alpine Linux" < /etc/issue ; then \
			pip3 install -U pip==20.2.4 pip-tools==5.3.1; \
			echo 'manylinux1_compatible = True' > venv/lib/python3.8/site-packages/_manylinux.py; \
			pip install orjson==3.3.1; \
			rm -f venv/lib/python3.8/site-packages/_manylinux.py; \
		else \
			pip install orjson; \
		fi; \
		pip install -r $(OSS_HOME)/builder/requirements.txt; \
		pip install -e $(OSS_HOME)/python; \
	}
.PHONY: setup-orjson

setup-diagd: create-venv
	. $(OSS_HOME)/venv/bin/activate && $(MAKE) setup-venv
.PHONY: setup-diagd

gotest: setup-diagd
	@printf "$(CYN)==> $(GRN)Running $(BLU)go$(GRN) tests$(END)\n"
	. $(OSS_HOME)/venv/bin/activate; \
		EDGE_STACK=$(GOTEST_AES_ENABLED) \
		$(OSS_HOME)/builder/builder.sh gotest-local
.PHONY: gotest

# Ingress v1 conformance tests, using KIND and the Ingress Conformance Tests suite.
ingresstest: | docker/$(LCNAME).docker.push.remote
	@printf "$(CYN)==> $(GRN)Running $(BLU)Ingress v1$(GRN) tests$(END)\n"
	@[ -n "$(INGRESS_TEST_IMAGE)" ] || { printf "$(RED)ERROR: no INGRESS_TEST_IMAGE defined$(END)\n"; exit 1; }
	@[ -n "$(INGRESS_TEST_MANIF_DIR)" ] || { printf "$(RED)ERROR: no INGRESS_TEST_MANIF_DIR defined$(END)\n"; exit 1; }
	@[ -d "$(INGRESS_TEST_MANIF_DIR)" ] || { printf "$(RED)ERROR: $(INGRESS_TEST_MANIF_DIR) does not seem a valid directory$(END)\n"; exit 1; }
	@[ -n "$(HOST_IP)" ] || { printf "$(RED)ERROR: no IP obtained for host$(END)\n"; ip addr ; exit 1; }

	@printf "$(CYN)==> $(GRN)Creating/recreating KIND cluster with image $(KIND_IMAGE)$(END)\n"
	@for i in {1..5} ; do \
		kind delete cluster 2>/dev/null || true ; \
		kind create cluster --image $(KIND_IMAGE) && break || sleep 10 ; \
	done

	@printf "$(CYN)==> $(GRN)Saving KUBECONFIG at $(KIND_KUBECONFIG)$(END)\n"
	@kind get kubeconfig > $(KIND_KUBECONFIG)
	@sleep 10

	@APISERVER_IP=`docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kind-control-plane` ; \
		[ -n "$$APISERVER_IP" ] || { printf "$(RED)ERROR: no IP obtained for API server$(END)\n"; docker ps ; docker inspect kind-control-plane ; exit 1; } ; \
		printf "$(CYN)==> $(GRN)API server at $$APISERVER_IP. Fixing server in $(KIND_KUBECONFIG).$(END)\n" ; \
		sed -i -e "s|server: .*|server: https://$$APISERVER_IP:6443|g" $(KIND_KUBECONFIG)

	@printf "$(CYN)==> $(GRN)Showing some cluster info:$(END)\n"
	@kubectl --kubeconfig=$(KIND_KUBECONFIG) cluster-info || { printf "$(RED)ERROR: kubernetes cluster not ready $(END)\n"; exit 1 ; }
	@kubectl --kubeconfig=$(KIND_KUBECONFIG) version || { printf "$(RED)ERROR: kubernetes cluster not ready $(END)\n"; exit 1 ; }

	@printf "$(CYN)==> $(GRN)Loading Ambassador (from the Ingress conformance tests) with image=$$(sed -n 2p docker/$(LCNAME).docker.push.remote)$(END)\n"
	@for f in $(INGRESS_TEST_MANIFS) ; do \
		printf "$(CYN)==> $(GRN)... $$f $(END)\n" ; \
		cat $(INGRESS_TEST_MANIF_DIR)/$$f | sed -e "s|image:.*ambassador\:.*|image: $$(sed -n 2p docker/$(LCNAME).docker.push.remote)|g" | tee /dev/tty | kubectl apply -f - ; \
	done

	@printf "$(CYN)==> $(GRN)Waiting for Ambassador to be ready$(END)\n"
	@kubectl --kubeconfig=$(KIND_KUBECONFIG) wait --for=condition=available --timeout=180s deployment/ambassador || { \
		printf "$(RED)ERROR: Ambassador was not ready after 3 mins $(END)\n"; \
		kubectl --kubeconfig=$(KIND_KUBECONFIG) get services --all-namespaces ; \
		exit 1 ; }

	@printf "$(CYN)==> $(GRN)Exposing Ambassador service$(END)\n"
	@kubectl --kubeconfig=$(KIND_KUBECONFIG) expose deployment ambassador --type=LoadBalancer --name=ambassador

	@printf "$(CYN)==> $(GRN)Starting the tests container (in the background)$(END)\n"
	@docker stop -t 3 ingress-tests 2>/dev/null || true && docker rm ingress-tests 2>/dev/null || true
	@docker run -d --rm --name ingress-tests -e KUBECONFIG=/opt/.kube/config --mount type=bind,source=$(KIND_KUBECONFIG),target=/opt/.kube/config \
		--entrypoint "/bin/sleep" $(INGRESS_TEST_IMAGE) 600

	@printf "$(CYN)==> $(GRN)Loading the Ingress conformance tests manifests$(END)\n"
	@docker exec -ti ingress-tests \
		/opt/ingress-controller-conformance apply --api-version=networking.k8s.io/v1beta1 --ingress-controller=getambassador.io/ingress-controller --ingress-class=ambassador
	@sleep 10

	@printf "$(CYN)==> $(GRN)Forwarding traffic to Ambassador service$(END)\n"
	@kubectl --kubeconfig=$(KIND_KUBECONFIG) port-forward --address=$(HOST_IP) svc/ambassador \
		$(INGRESS_TEST_LOCAL_PLAIN_PORT):8080 $(INGRESS_TEST_LOCAL_TLS_PORT):8443 $(INGRESS_TEST_LOCAL_ADMIN_PORT):8877 &
	@sleep 10

	@for url in "http://$(HOST_IP):$(INGRESS_TEST_LOCAL_PLAIN_PORT)" "https://$(HOST_IP):$(INGRESS_TEST_LOCAL_TLS_PORT)" "http://$(HOST_IP):$(INGRESS_TEST_LOCAL_ADMIN_PORT)/ambassador/v0/check_ready" ; do \
		printf "$(CYN)==> $(GRN)Waiting until $$url is ready...$(END)\n" ; \
		until curl --silent -k "$$url" ; do printf "$(CYN)==> $(GRN)... still waiting.$(END)\n" ; sleep 2 ; done ; \
		printf "$(CYN)==> $(GRN)... $$url seems to be ready.$(END)\n" ; \
	done
	@sleep 30

	@printf "$(CYN)==> $(GRN)Running the Ingress conformance tests against $(HOST_IP)$(END)\n"
	@docker exec -ti ingress-tests \
		/opt/ingress-controller-conformance verify \
			--api-version=networking.k8s.io/v1beta1 \
			--use-insecure-host=$(HOST_IP):$(INGRESS_TEST_LOCAL_PLAIN_PORT) \
			--use-secure-host=$(HOST_IP):$(INGRESS_TEST_LOCAL_TLS_PORT)

	@printf "$(CYN)==> $(GRN)Cleaning up...$(END)\n"
	-@pkill kubectl -9
	@docker stop -t 3 ingress-tests 2>/dev/null || true && docker rm ingress-tests 2>/dev/null || true

	@if [ -n "$(CLEANUP)" ] ; then \
		printf "$(CYN)==> $(GRN)We are done. Destroying the cluster now.$(END)\n"; kind delete cluster || true; \
	else \
		printf "$(CYN)==> $(GRN)We are done. You should destroy the cluster with 'kind delete cluster'.$(END)\n"; \
	fi

test: ingresstest gotest pytest e2etest
.PHONY: test

# Empty stub; 'e2etest' is AES-only
e2etest:
.PHONY: e2etest

shell: docker/container.txt
	@printf "$(CYN)==> $(GRN)Launching interactive shell...$(END)\n"
	@$(BUILDER) shell
.PHONY: shell

AMB_IMAGE_RC=$(RELEASE_REGISTRY)/$(REPO):$(RELEASE_VERSION)
AMB_IMAGE_RC_LATEST=$(RELEASE_REGISTRY)/$(REPO):$(BUILD_VERSION)-rc-latest
AMB_IMAGE_RELEASE=$(RELEASE_REGISTRY)/$(REPO):$(BUILD_VERSION)

export RELEASE_REGISTRY_ERR=$(RED)ERROR: please set the RELEASE_REGISTRY make/env variable to the docker registry\n       you would like to use for release$(END)

RELEASE_TYPE=$$($(BUILDER) release-type)
RELEASE_VERSION=$$($(BUILDER) release-version)
BUILD_VERSION=$$($(BUILDER) version)
IS_DIRTY=$$($(BUILDER) is-dirty)

# 'rc' is a deprecated alias for 'release/bits', kept around for the
# moment to avoid pain with needing to update apro.git in lockstep.
rc: release/bits
.PHONY: rc

release/bits: images
	@test -n "$(RELEASE_REGISTRY)" || (printf "$${RELEASE_REGISTRY_ERR}\n"; exit 1)
	@printf "$(CYN)==> $(GRN)Pushing $(BLU)$(REPO)$(GRN) Docker image$(END)\n"
	docker tag $$(cat docker/$(LCNAME).docker) $(AMB_IMAGE_RC)
	docker push $(AMB_IMAGE_RC)
.PHONY: release/bits

release/promote-oss/.main:
	@[[ "$(RELEASE_VERSION)"      =~ ^[0-9]+\.[0-9]+\.[0-9]+(-.*)?$$ ]] || (echo "MUST SET RELEASE_VERSION"; exit 1)
	@[[ -n "$(PROMOTE_FROM_VERSION)" ]] || (echo "MUST SET PROMOTE_FROM_VERSION"; exit 1)
	@[[ '$(PROMOTE_TO_VERSION)'   =~ ^[0-9]+\.[0-9]+\.[0-9]+(-.*)?$$ ]] || (echo "MUST SET PROMOTE_TO_VERSION" ; exit 1)
	@set -e; { \
		case "$(PROMOTE_CHANNEL)" in \
			""|wip|early|test) true ;; \
			*) echo "Unknown PROMOTE_CHANNEL $(PROMOTE_CHANNEL)" >&2 ; exit 1;; \
		esac ; \
		printf "$(CYN)==> $(GRN)Promoting $(BLU)%s$(GRN) to $(BLU)%s$(GRN) (channel=$(BLU)%s$(GRN))$(END)\n" '$(PROMOTE_FROM_VERSION)' '$(PROMOTE_TO_VERSION)' '$(PROMOTE_CHANNEL)' ; \
		pullregistry=$(PROMOTE_FROM_REPO) ; \
		if [[ -z "$${pullregistry}" ]] ; then \
			pullregistry=$(RELEASE_REGISTRY) ;\
		fi ; \
		if [[ -z "$${pullregistry}" ]] ; then \
			echo "Must set PROMOTE_FROM_REPO or RELEASE_REGISTRY" ; \
			exit 1; \
		fi ; \
		printf '  $(CYN)$${pullregistry}/$(REPO):$(PROMOTE_FROM_VERSION)$(END)\n' ; \
		docker pull $${pullregistry}/$(REPO):$(PROMOTE_FROM_VERSION) && \
		docker tag $${pullregistry}/$(REPO):$(PROMOTE_FROM_VERSION) $(RELEASE_REGISTRY)/$(REPO):$(PROMOTE_TO_VERSION) && \
		docker push $(RELEASE_REGISTRY)/$(REPO):$(PROMOTE_TO_VERSION) ;\
	}

	@printf '  $(CYN)https://s3.amazonaws.com/$(AWS_S3_BUCKET)/emissary-ingress/$(PROMOTE_CHANNEL)stable.txt$(END)\n'
	printf '%s' "$(RELEASE_VERSION)" | aws s3 cp - s3://$(AWS_S3_BUCKET)/emissary-ingress/$(PROMOTE_CHANNEL)stable.txt

	@printf '  $(CYN)s3://scout-datawire-io/emissary-ingress/$(PROMOTE_CHANNEL)app.json$(END)\n'
	printf '{"application":"emissary","latest_version":"%s","notices":[]}' "$(RELEASE_VERSION)" | aws s3 cp - s3://scout-datawire-io/emissary-ingress/$(PROMOTE_CHANNEL)app.json
.PHONY: release/promote-oss/.main

# To be run from a checkout at the tag you are promoting _from_.
# At present, this is to be run by-hand.
release/promote-oss/to-ea-latest:
	@test -n "$(RELEASE_REGISTRY)" || (printf "$${RELEASE_REGISTRY_ERR}\n"; exit 1)
	@[[ "$(RELEASE_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+-ea\.[0-9]+$$ ]] || (printf '$(RED)ERROR: RELEASE_VERSION=%s does not look like an EA tag\n' "$(RELEASE_VERSION)"; exit 1)
	@{ $(MAKE) release/promote-oss/.main \
	  PROMOTE_FROM_VERSION="$(RELEASE_VERSION)" \
	  PROMOTE_TO_VERSION="$$(echo "$(RELEASE_VERSION)" | sed 's/-ea.*/-ea-latest/')" \
	  PROMOTE_CHANNEL=early \
	; }
.PHONY: release/promote-oss/to-ea-latest

release/promote-oss/dev-to-rc:
	@test -n "$(RELEASE_REGISTRY)" || (printf "$${RELEASE_REGISTRY_ERR}\n"; exit 1)
	@[[ "$(RELEASE_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$$ ]] || (printf '$(RED)ERROR: RELEASE_VERSION=%s does not look like an RC tag\n' "$(RELEASE_VERSION)"; exit 1)
	@set -e; { \
		if [ -n "$(IS_DIRTY)" ]; then \
			echo "release/promote-oss/dev-to-rc: tree must be clean" >&2 ;\
			exit 1 ;\
		fi; \
		commit=$$(git rev-parse HEAD) ;\
		dev_version=$$(aws s3 cp s3://$(AWS_S3_BUCKET)/dev-builds/$$commit -) ;\
		if [ -z "$$dev_version" ]; then \
			printf "$(RED)==> found no dev version for $$commit in S3...$(END)\n" ;\
			exit 1 ;\
		fi ;\
		printf "$(CYN)==> $(GRN)found version $(BLU)$$dev_version$(GRN) for $(BLU)$$commit$(GRN) in S3...$(END)\n" ;\
		veroverride=$(RELEASE_VERSION); \
		$(MAKE) release/promote-oss/.main \
			PROMOTE_FROM_VERSION="$$dev_version" \
			PROMOTE_FROM_REPO=$(DEV_REGISTRY) \
			PROMOTE_TO_VERSION=$(RELEASE_VERSION) \
			PROMOTE_CHANNEL=test ; \
		chartsuffix=$(RELEASE_VERSION) ; \
		chartsuffix=$${chartsuffix#*-} ; \
		$(MAKE) \
			CHART_VERSION_SUFFIX=-$$chartsuffix \
			IMAGE_TAG=$${veroverride} \
			IMAGE_REPO="$(RELEASE_REGISTRY)/$(LCNAME)" \
			chart-push-ci ; \
		$(MAKE) update-yaml --always-make; \
		$(MAKE) VERSION_OVERRIDE=$${veroverride} push-manifests  ; \
		$(MAKE) VERSION_OVERRIDE=$${veroverride} publish-docs-yaml ; \
		$(MAKE) clean-manifests ; \
	}
.PHONY: release/promote-oss/dev-to-rc

release/print-test-artifacts:
	@set -e; { \
		manifest_ver=$(RELEASE_VERSION) ; \
		manifest_ver=$${manifest_ver%"-dirty"} ; \
		echo "export AMBASSADOR_MANIFEST_URL=https://app.getambassador.io/yaml/emissary/$$manifest_ver" ; \
		echo "export HELM_CHART_VERSION=`grep 'version' $(OSS_HOME)/charts/emissary-ingress/Chart.yaml | awk '{ print $$2 }'`" ; \
	}
.PHONY: release/print-test-artifacts

# just push the commit hash to s3
# this should only happen if all tests have passed at a certain commit
release/promote-oss/dev-to-passed-ci:
	@set -e; { \
		commit=$$(git rev-parse HEAD) ;\
		dev_version=$$(aws s3 cp s3://$(AWS_S3_BUCKET)/dev-builds/$$commit -) ;\
		if [ -z "$$dev_version" ]; then \
			printf "$(RED)==> found no dev version for $$commit in S3...$(END)\n" ;\
			exit 1 ;\
		fi ;\
		printf "$(CYN)==> $(GRN)Promoting $(BLU)$$commit$(GRN) => $(BLU)$$dev_version$(GRN) in S3...$(END)\n" ;\
		echo "$$dev_version" | aws s3 cp - s3://$(AWS_S3_BUCKET)/passed-builds/$$commit ;\
	}
.PHONY: release/promote-oss/dev-to-passed-ci

# To be run from a checkout at the tag you are promoting _from_.
# This is normally run from CI by creating the GA tag.
release/promote-oss/to-ga:
	@test -n "$(RELEASE_REGISTRY)" || (printf "$${RELEASE_REGISTRY_ERR}\n"; exit 1)
	@[[ "$(RELEASE_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-ea)?$$ ]] || (printf '$(RED)ERROR: RELEASE_VERSION=%s does not look like a GA tag\n' "$(RELEASE_VERSION)"; exit 1)
	@set -e; { \
      commit=$$(git rev-parse HEAD) ;\
	  $(OSS_HOME)/releng/release-wait-for-commit --commit $$commit --s3-key passed-builds ; \
	  dev_version=$$(aws s3 cp s3://$(AWS_S3_BUCKET)/passed-builds/$$commit -) ;\
	  if [ -z "$$dev_version" ]; then \
		  printf "$(RED)==> found no passed dev version for $$commit in S3...$(END)\n" ;\
		  exit 1 ;\
      fi ;\
 	  printf "$(CYN)==> $(GRN)found version $(BLU)$$dev_version$(GRN) for $(BLU)$$commit$(GRN) in S3...$(END)\n" ;\
	  $(MAKE) release/promote-oss/.main \
	    PROMOTE_FROM_VERSION="$$dev_version" \
		PROMOTE_FROM_REPO=$(DEV_REGISTRY) \
	    PROMOTE_TO_VERSION="$(RELEASE_VERSION)" \
	    ; \
	}
.PHONY: release/promote-oss/to-ga

VERSIONS_YAML_VER := $(shell grep 'version:' $(OSS_HOME)/docs/yaml/versions.yml | awk '{ print $$2 }')
VERSIONS_YAML_VER_STRIPPED := $(subst -ea,,$(VERSIONS_YAML_VER))
RC_NUMBER ?= 0

release/prep-rc:
	@test -n "$(VERSIONS_YAML_VER)" || (printf "version not found in versions.yml\n"; exit 1)
	@test -n "$(RELEASE_REGISTRY)" || (printf "RELEASE_REGISTRY must be set\n"; exit 1)
	@[[ "$(VERSIONS_YAML_VER)" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-ea)?$$ ]] || (printf '$(RED)ERROR: Version in versions.yml %s does not look like a GA tag\n' "$(VERSIONS_YAML_VER)"; exit 1)
	@[[ -z "$(IS_DIRTY)" ]] || (printf '$(RED)ERROR: tree must be clean\n'; exit 1)
	@AWS_S3_BUCKET=$(AWS_S3_BUCKET) RELEASE_REGISTRY=$(RELEASE_REGISTRY) IMAGE_NAME=$(LCNAME) \
		$(OSS_HOME)/releng/01-release-prep-rc $(VERSIONS_YAML_VER_STRIPPED)-rc.$(RC_NUMBER)
.PHONY: release/prep-rc

release/go:
	@test -n "$(VERSIONS_YAML_VER)" || (printf "version not found in versions.yml\n"; exit 1)
	@test -n "$${RC_NUMBER}" || (printf "RC_NUMBER must be set.\n"; exit 1)
	@[[ "$(VERSIONS_YAML_VER)" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-ea)?$$ ]] || (printf '$(RED)ERROR: RELEASE_VERSION=%s does not look like a GA tag\n' "$(VERSIONS_YAML_VER)"; exit 1)
	@[[ -z "$(IS_DIRTY)" ]] || (printf '$(RED)ERROR: tree must be clean\n'; exit 1)
	@RELEASE_REGISTRY=$(RELEASE_REGISTRY) IMAGE_NAME=$(LCNAME) $(OSS_HOME)/releng/02-release-ga $(VERSIONS_YAML_VER)
.PHONY: release/go

release/manifests:
	@test -n "$(VERSIONS_YAML_VER)" || (printf "version not found in versions.yml\n"; exit 1)
	@[[ "$(VERSIONS_YAML_VER)" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-ea)?$$ ]] || (printf '$(RED)ERROR: RELEASE_VERSION=%s does not look like a GA tag\n' "$(VERSIONS_YAML_VER)"; exit 1)
	@$(OSS_HOME)/releng/release-manifest-image-update --oss-version $(VERSIONS_YAML_VER)
.PHONY: release/manifests

release/repatriate:
	@$(OSS_HOME)/releng/release-repatriate $(VERSIONS_YAML_VER)
.PHONY: release/repatriate

release/ga-mirror:
	@test -n "$(VERSIONS_YAML_VER)" || (printf "$(RED)ERROR: version not found in versions.yml\n"; exit 1)
	@[[ "$(VERSIONS_YAML_VER)" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-ea)?$$ ]] || (printf '$(RED)ERROR: RELEASE_VERSION=%s does not look like a GA tag\n' "$(VERSIONS_YAML_VER)"; exit 1)
	@test -n "$(RELEASE_REGISTRY)" || (printf "$(RED)ERROR: RELEASE_REGISTRY not set\n"; exit 1)
	@$(OSS_HOME)/releng/release-mirror-images --ga-version $(VERSIONS_YAML_VER) --source-registry $(RELEASE_REGISTRY) --image-name $(LCNAME)

release/create-gh-release:
	@test -n "$(VERSIONS_YAML_VER)" || (printf "$(RED)ERROR: version not found in versions.yml\n"; exit 1)
	@[[ "$(VERSIONS_YAML_VER)" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-ea)?$$ ]] || (printf '$(RED)ERROR: RELEASE_VERSION=%s does not look like a GA tag\n' "$(VERSIONS_YAML_VER)"; exit 1)
	@$(OSS_HOME)/releng/release-create-github $(VERSIONS_YAML_VER)

release/ga-check:
	@$(OSS_HOME)/releng/release-ga-check --ga-version $(VERSIONS_YAML_VER) --source-registry $(RELEASE_REGISTRY) --image-name $(LCNAME)

release/start:
	@test -n "$(VERSION)" || (printf "VERSION is required\n"; exit 1)
	@$(OSS_HOME)/releng/start-sanity-check --quiet $(VERSION)
	@$(OSS_HOME)/releng/00-release-start --next-version $(VERSION)
.PHONY: release/start

release/hotfix/start:
	@test -n "$(VERSION)" || (printf "VERSION is required\n"; exit 1)
	@$(OSS_HOME)/releng/start-sanity-check --quiet $(VERSION)
	@$(OSS_HOME)/releng/00-release-start --next-version $(VERSION) --hotfix
.PHONY: release/hotfix/start

clean:
	@rm -f $(OSS_HOME)/bin/*
	@$(BUILDER) clean
.PHONY: clean

clobber:
	@$(BUILDER) clobber
.PHONY: clobber

CURRENT_CONTEXT=$(shell kubectl --kubeconfig=$(DEV_KUBECONFIG) config current-context)
CURRENT_NAMESPACE=$(shell kubectl config view -o=jsonpath="{.contexts[?(@.name==\"$(CURRENT_CONTEXT)\")].context.namespace}")

AMBASSADOR_DOCKER_IMAGE = $(shell sed -n 2p docker/$(LCNAME).docker.push.remote 2>/dev/null)
export AMBASSADOR_DOCKER_IMAGE
AMBASSADOR_EA_DOCKER_IMAGE = $(shell sed -n 2p docker/$(LCNAME)-ea.docker.push.remote 2>/dev/null)
export AMBASSADOR_EA_DOCKER_IMAGE
KAT_CLIENT_DOCKER_IMAGE = $(shell sed -n 2p docker/kat-client.docker.push.remote 2>/dev/null)
export KAT_CLIENT_DOCKER_IMAGE
KAT_SERVER_DOCKER_IMAGE = $(shell sed -n 2p docker/kat-server.docker.push.remote 2>/dev/null)
export KAT_SERVER_DOCKER_IMAGE

_user-vars  = BUILDER_NAME
_user-vars += DEV_KUBECONFIG
_user-vars += DEV_REGISTRY
_user-vars += RELEASE_REGISTRY
_user-vars += AMBASSADOR_DOCKER_IMAGE
_user-vars += AMBASSADOR_EA_DOCKER_IMAGE
_user-vars += KAT_CLIENT_DOCKER_IMAGE
_user-vars += KAT_SERVER_DOCKER_IMAGE
env:
	@printf '$(BLD)%s$(END)=$(BLU)%s$(END)\n' $(foreach v,$(_user-vars), $v $(call quote.shell,$(call quote.shell,$($v))) )
.PHONY: env

export:
	@printf 'export %s=%s\n' $(foreach v,$(_user-vars), $v $(call quote.shell,$(call quote.shell,$($v))) )
.PHONY: export

help:
	@printf '%s\n' $(call quote.shell,$(_help.intro))
.PHONY: help

targets:
	@printf '%s\n' $(call quote.shell,$(HELP_TARGETS))
.PHONY: help

define HELP_TARGETS
$(BLD)Targets:$(END)

$(_help.targets)

$(BLD)Codebases:$(END)
  $(foreach MODULE,$(MODULES),$(NL)  $(BLD)$(SOURCE_$(MODULE)) ==> $(BLU)$(MODULE)$(END))

endef

# Style note: _help.intro
# - is wrapped to 72 columns (after stripping the ANSI color codes)
# - has sentences separated with 2 spaces
# - uses bold blue ("$(BLU)") when introducing a new variable
# - uses bold ("$(BLD)") for variables that have already been introduced
# - uses bold ("$(BLD)") when you would use `backticks` in markdown
define _help.intro
This Makefile builds Ambassador using a standard build environment
inside a Docker container.  The $(BLD)$(REPO)$(END), $(BLD)kat-server$(END), and $(BLD)kat-client$(END)
images are created from this container after the build stage is
finished.

The build works by maintaining a running build container in the
background.  It gets source code into that container via $(BLD)rsync$(END).  The
$(BLD)/home/dw$(END) directory in this container is a Docker volume, which allows
files (e.g. the Go build cache and $(BLD)pip$(END) downloads) to be cached across
builds.

This arrangement also permits building multiple codebases.  This is
useful for producing builds with extended functionality.  Each external
codebase is synced into the container at the $(BLD)/buildroot/<name>$(END) path.

You can control the name of the container and the images it builds by
setting $(BLU)$$BUILDER_NAME$(END), which defaults to $(BLD)$(LCNAME)$(END).  Note well that if
you want to make multiple clones of this repo and build in more than one
of them at the same time, you $(BLD)must$(END) set $(BLD)$$BUILDER_NAME$(END) so that each clone
has its own builder!  If you do not do this, your builds will collide
with confusing results.

The build system doesn't try to magically handle all dependencies.  In
general, if you change something that is not pure source code, you will
likely need to do a $(BLD)$(MAKE) clean$(END) in order to see the effect.  For example,
Python code only gets set up once, so if you change $(BLD)setup.py$(END), then you
will need to do a clean build to see the effects.  Assuming you didn't
$(BLD)$(MAKE) clobber$(END), this shouldn't take long due to the cache in the Docker
volume.

All targets that deploy to a cluster by way of $(BLU)$$DEV_REGISTRY$(END) can be made
to have the cluster use an imagePullSecret to pull from $(BLD)$$DEV_REGISTRY$(END),
by setting $(BLU)$$DEV_USE_IMAGEPULLSECRET$(END) to a non-empty value.  The
imagePullSecret will be constructed from $(BLD)$$DEV_REGISTRY$(END),
$(BLU)$$DOCKER_BUILD_USERNAME$(END), and $(BLU)$$DOCKER_BUILD_PASSWORD$(END).

By default, the base builder image is (as an optimization) pulled from
$(BLU)$$BASE_REGISTRY$(END) instead of being built locally; where $(BLD)$$BASE_REGISTRY$(END)
defaults to $(BLD)$$DEV_REGISTRY$(END) or else $(BLD)$${BUILDER_NAME}.local$(END).  If that pull
fails (as it will if trying to pull from a $(BLD).local$(END) registry, or if the
image does not yet exist), then it falls back to building the base image
locally.  If $(BLD)$$BASE_REGISTRY$(END) is equal to $(BLD)$$DEV_REGISTRY$(END), then it will
proceed to push the built image back to the $(BLD)$$BASE_REGISTRY$(END).

Use $(BLD)$(MAKE) $(BLU)targets$(END) for help about available $(BLD)make$(END) targets.
endef

define _help.targets
  $(BLD)$(MAKE) $(BLU)help$(END)         -- displays the main help message.

  $(BLD)$(MAKE) $(BLU)targets$(END)      -- displays this message.

  $(BLD)$(MAKE) $(BLU)env$(END)          -- display the value of important env vars.

  $(BLD)$(MAKE) $(BLU)export$(END)       -- display important env vars in shell syntax, for use with $(BLD)eval$(END).

  $(BLD)$(MAKE) $(BLU)preflight$(END)    -- checks dependencies of this makefile.

  $(BLD)$(MAKE) $(BLU)sync$(END)         -- syncs source code into the build container.

  $(BLD)$(MAKE) $(BLU)version$(END)      -- display source code version.

  $(BLD)$(MAKE) $(BLU)compile$(END)      -- syncs and compiles the source code in the build container.

  $(BLD)$(MAKE) $(BLU)images$(END)       -- creates images from the build container.

  $(BLD)$(MAKE) $(BLU)push$(END)         -- pushes images to $(BLD)$$DEV_REGISTRY$(END). ($(DEV_REGISTRY))

  $(BLD)$(MAKE) $(BLU)test$(END)         -- runs Go and Python tests inside the build container.

    The tests require a Kubernetes cluster and a Docker registry in order to
    function. These must be supplied via the $(BLD)$(MAKE)$(END)/$(BLD)env$(END) variables $(BLD)$$DEV_KUBECONFIG$(END)
    and $(BLD)$$DEV_REGISTRY$(END).

  $(BLD)$(MAKE) $(BLU)gotest$(END)       -- runs just the Go tests inside the build container.

    Use $(BLD)$$GOTEST_PKGS$(END) to control which packages are passed to $(BLD)gotest$(END). ($(GOTEST_PKGS))
    Use $(BLD)$$GOTEST_ARGS$(END) to supply additional non-package arguments. ($(GOTEST_ARGS))
    Example: $(BLD)$(MAKE) gotest GOTEST_PKGS=./cmd/entrypoint GOTEST_ARGS=-v$(END)  # run entrypoint tests verbosely

  $(BLD)$(MAKE) $(BLU)pytest$(END)       -- runs just the Python tests inside the build container.

    Use $(BLD)$$KAT_RUN_MODE=envoy$(END) to force the Python tests to ignore local caches, and run everything
    in the cluster.

    Use $(BLD)$$KAT_RUN_MODE=local$(END) to force the Python tests to ignore the cluster, and only run tests
    with a local cache.

    Use $(BLD)$$PYTEST_ARGS$(END) to pass args to $(BLD)pytest$(END). ($(PYTEST_ARGS))

    Example: $(BLD)$(MAKE) pytest KAT_RUN_MODE=envoy PYTEST_ARGS="-k Lua"$(END)  # run only the Lua test, with a real Envoy

  $(BLD)$(MAKE) $(BLU)pytest-gold$(END)  -- update the gold files for the pytest cache

    $(BLD)$(MAKE) $(BLU)pytest$(END) uses a local cache to speed up tests. $(BLD)ONCE YOU HAVE SUCCESSFULLY
    RUN TESTS WITH $(BLU)KAT_RUN_MODE=envoy$(END), you can use $(BLD)$(MAKE) $(BLU)pytest-gold$(END) to update the
    caches for the passing tests.

    $(BLD)DO NOT$(END) run $(BLD)$(MAKE) $(BLU)pytest-gold$(END) if you have failing tests.

  $(BLD)$(MAKE) $(BLU)shell$(END)        -- starts a shell in the build container

  $(BLD)$(MAKE) $(BLU)release/bits$(END) -- do the 'push some bits' part of a release

    The current commit must be tagged for this to work, and your tree must be clean.
    If the tag is of the form 'vX.Y.Z-(ea|rc).[0-9]*'.

  $(BLD)$(MAKE) $(BLU)release/promote-oss/to-ea-latest$(END) -- promote an early-access '-ea.N' release to '-ea-latest'

    The current commit must be tagged for this to work, and your tree must be clean.
    Additionally, the tag must be of the form 'vX.Y.Z-ea.N'. You must also have previously
    built an EA for the same tag using $(BLD)release/bits$(END).

  $(BLD)$(MAKE) $(BLU)release/promote-oss/to-rc-latest$(END) -- promote a release candidate '-rc.N' release to '-rc-latest'

    The current commit must be tagged for this to work, and your tree must be clean.
    Additionally, the tag must be of the form 'vX.Y.Z-rc.N'. You must also have previously
    built an RC for the same tag using $(BLD)release/bits$(END).

  $(BLD)$(MAKE) $(BLU)release/promote-oss/to-ga$(END) -- promote a release candidate to general availability

    The current commit must be tagged for this to work, and your tree must be clean.
    Additionally, the tag must be of the form 'vX.Y.Z'. You must also have previously
    built and promoted the RC that will become GA, using $(BLD)release/bits$(END) and
    $(BLD)release/promote-oss/to-rc-latest$(END).

  $(BLD)$(MAKE) $(BLU)clean$(END)     -- kills the build container.

  $(BLD)$(MAKE) $(BLU)clobber$(END)   -- kills the build container and the cache volume.

  $(BLD)$(MAKE) $(BLU)generate$(END)  -- update generated files that get checked in to Git.

    1. Use $(BLD)$$ENVOY_COMMIT$(END) to update the vendored gRPC protobuf files ('api/envoy').
    2. Run 'protoc' to generate things from the protobuf files (both those from
       Envoy, and those from 'api/kat').
    3. Use $(BLD)$$ENVOY_GO_CONTROL_PLANE_COMMIT$(END) to update the vendored+patched copy of
       envoyproxy/go-control-plane ('pkg/envoy-control-plane/').
    4. Use the Go CRD definitions in 'pkg/api/getambassador.io/' to generate YAML
       (and a few 'zz_generated.*.go' files).

  $(BLD)$(MAKE) $(BLU)update-yaml$(END) -- like $(BLD)make generate$(END), but skips the slow Envoy stuff.

  $(BLD)$(MAKE) $(BLU)go-mod-tidy$(END) -- 'go mod tidy', but plays nice with 'make generate'

  $(BLD)$(MAKE) $(BLU)guess-envoy-go-control-plane-commit$(END) -- Make a suggestion for setting ENVOY_GO_CONTROL_PLANE_COMMIT= in generate.mk

  $(BLD)$(MAKE) $(BLU)lint$(END)        -- runs golangci-lint.

  $(BLD)$(MAKE) $(BLU)format$(END)      -- runs golangci-lint with --fix.

endef
