
# Image URL to use all building/pushing image targets
IMAGE ?= amazon/aws-eks-nodeagent
VERSION ?= $(shell git describe --tags --always --dirty || echo "unknown")
IMAGE_NAME = $(IMAGE)$(IMAGE_ARCH_SUFFIX):$(VERSION)

# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.25.0

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: manifests generate fmt vet envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" go test ./... -coverprofile cover.out

##@ Build

.PHONY: build
build: manifests generate fmt vet ## Build manager binary.
	go build -o bin/manager main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

GO_ENV_EBPF =
GO_ENV_EBPF += CGO_ENABLED=1
GO_ENV_EBPF += GOOS=linux
GO_ENV_EBPF += CC=$(CMD_CLANG)
GO_ENV_EBPF += GOARCH=$(GO_ARCH)
GO_ENV_EBPF += CGO_CFLAGS=$(CUSTOM_CGO_CFLAGS)
GO_ENV_EBPF += CGO_LDFLAGS=$(CUSTOM_CGO_LDFLAGS)

# Build using the host's Go toolchain.
BUILD_MODE ?= -buildmode=pie
build-linux: BUILD_FLAGS = $(BUILD_MODE) -ldflags '-s -w $(LDFLAGS) -extldflags "-static"'
build-linux: build-bpf-artifacts  ## Build the controllerusing the host's Go toolchain.
	$(GO_ENV_EBPF) go build $(VENDOR_OVERRIDE_FLAG) $(BUILD_FLAGS) -tags netgo,ebpf,core -a -o controller main.go
#	$(GO_ENV_EBPF) go build $(VENDOR_OVERRIDE_FLAG) $(BUILD_FLAGS) -tags netgo,ebpf,core -a -o cmd cmd.go

build-bpf-artifacts: libbpf

CMD_MKDIR ?= mkdir
CMD_CLANG ?= clang
CMD_GIT ?= git
CMD_RM ?= rm

OUTPUT_DIR = ./build_artifacts

$(OUTPUT_DIR):
#
	@$(CMD_MKDIR) -p $@
	@$(CMD_MKDIR) -p $@/libbpf
	@$(CMD_MKDIR) -p $@/libbpf/src
	@$(CMD_MKDIR) -p $@/libbpf/obj

#
# libbpf
#

LIBBPF_CFLAGS = -g -O2 -Wall -fpie
LIBBPF_LDLAGS =
LIBBPF_SRC = $(abspath ./$(OUTPUT_DIR)/libbpf/src/src)

LIBBPF_OBJ = $(abspath ./$(OUTPUT_DIR)/libbpf/libbpf.a)
LIBBPF_OBJDIR = $(abspath ./$(OUTPUT)/libbpf/obj)
LIBBPF_HASH = 68e6f83f223ebf3fbf0d94c0f4592e5e6773f0c1

libbpf:
	$(CMD_RM) -rf $(abspath ./$(OUTPUT_DIR)/libbpf/src)
	$(CMD_GIT) clone --depth 1 --branch v1.0.0 https://github.com/libbpf/libbpf.git $(abspath ./$(OUTPUT_DIR)/libbpf/src)
	cd $(abspath ./$(OUTPUT_DIR)/libbpf/src)
	CC="$(CC)" CFLAGS="$(LIBBPF_CFLAGS)" LD_FLAGS="$(LIBBPF_LDFLAGS)" $(MAKE) -C $(LIBBPF_SRC) BUILD_STATIC_ONLY=1 DESTDIR=$(abspath ./$(OUTPUT_DIR)/libbpf/) \
		OBJDIR=$(abspath ./$(OUTPUT_DIR)/libbpf/obj) INCLUDEDIR= LIBDIR= UAPIDIR= prefix= libdir= \
		install install_uapi_headers

EBPF_DIR = ./pkg/ebpf/c
EBPF_OBJ_CORE_HEADERS = $(shell find pkg/ebpf/c -name *.h)
EBPF_OBJ_SRC = ./pkg/ebpf/c/xdpdrop.bpf.c
EBPF_OBJ_SRC_TC = ./pkg/ebpf/c/tc.bpf.c

vmlinuxh:
	bpftool btf dump file /sys/kernel/btf/vmlinux format c > $(abspath ./$(EBPF_DIR))/vmlinux.h

ARCH := $(shell uname -m | sed 's/x86_64/amd64/g; s/aarch64/arm64/g')

BPF_VCPU = v2
# Build BPF
CLANG_INCLUDE := -I../../.
EBPF_SOURCE := ./pkg/ebpf/c/xdpdrop.bpf.c
EBPF_BINARY := ./pkg/ebpf/c/xdpdrop.bpf.o
EBPF_SOURCE_TC := ./pkg/ebpf/c/tc.bpf.c
EBPF_BINARY_TC := ./pkg/ebpf/c/tc.bpf.o
EBPF_SOURCE_INGRESS_TC := ./pkg/ebpf/c/tc.ingress.bpf.c
EBPF_BINARY_INGRESS_TC := ./pkg/ebpf/c/tc.ingress.bpf.o
EBPF_SOURCE_EGRESS_TC := ./pkg/ebpf/c/tc.egress.bpf.c
EBPF_BINARY_EGRESS_TC := ./pkg/ebpf/c/tc.egress.bpf.o
EBPF_SOURCE_XDP_ELF := ./pkg/ebpf/c/xdp_fw.c
EBPF_BINARY_XDP_ELF := ./pkg/ebpf/c/xdp_fw.elf
build-bpf: ## Build BPF.
	$(CMD_CLANG) $(CLANG_INCLUDE) -g -O2 -Wall -fpie -target bpf -DCORE -D__BPF_TRACING__ -march=bpf -D__TARGET_ARCH_$(ARCH) -c $(EBPF_SOURCE) -o $(EBPF_BINARY)
	$(CMD_CLANG) $(CLANG_INCLUDE) -g -O2 -Wall -fpie -target bpf -DCORE -D__BPF_TRACING__ -march=bpf -D__TARGET_ARCH_$(ARCH) -c $(EBPF_SOURCE_TC) -o $(EBPF_BINARY_TC)
	$(CMD_CLANG) $(CLANG_INCLUDE) -g -O2 -Wall -fpie -target bpf -DCORE -D__BPF_TRACING__ -march=bpf -D__TARGET_ARCH_$(ARCH) -c $(EBPF_SOURCE_INGRESS_TC) -o $(EBPF_BINARY_INGRESS_TC)
	$(CMD_CLANG) $(CLANG_INCLUDE) -g -O2 -Wall -fpie -target bpf -DCORE -D__BPF_TRACING__ -march=bpf -D__TARGET_ARCH_$(ARCH) -c $(EBPF_SOURCE_EGRESS_TC) -o $(EBPF_BINARY_EGRESS_TC)
	$(CMD_CLANG) $(CLANG_INCLUDE) -g -O2 -Wall -fpie -target bpf -DCORE -D__BPF_TRACING__ -march=bpf -D__TARGET_ARCH_$(ARCH) -c $(EBPF_SOURCE_XDP_ELF) -o $(EBPF_BINARY_XDP_ELF)

build-bpf-artifacts: libbpf

# If you wish built the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64 ). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
#docker-build: test ## Build docker image with the manager.
#	docker build -t ${IMAGE_NAME} .
docker-build: ## Build docker image with the manager.
	docker build -t ${IMAGE_NAME} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	docker push ${IMAGE_NAME}

# PLATFORMS defines the target platforms for  the manager image be build to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - able to use docker buildx . More info: https://docs.docker.com/build/buildx/
# - have enable BuildKit, More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image for your registry (i.e. if you do not inform a valid value via IMG=<myregistry/image:<tag>> then the export will fail)
# To properly provided solutions that supports more than one platform you should use this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: test ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	- docker buildx create --name project-v3-builder
	docker buildx use project-v3-builder
	- docker buildx build --push --platform=$(PLATFORMS) --tag ${IMG} -f Dockerfile.cross .
	- docker buildx rm project-v3-builder
	rm Dockerfile.cross

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

##@ Build Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest

## Tool Versions
KUSTOMIZE_VERSION ?= v3.8.7
CONTROLLER_TOOLS_VERSION ?= v0.11.1

KUSTOMIZE_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary. If wrong version is installed, it will be removed before downloading.
$(KUSTOMIZE): $(LOCALBIN)
	@if test -x $(LOCALBIN)/kustomize && ! $(LOCALBIN)/kustomize version | grep -q $(KUSTOMIZE_VERSION); then \
		echo "$(LOCALBIN)/kustomize version is not expected $(KUSTOMIZE_VERSION). Removing it before installing."; \
		rm -rf $(LOCALBIN)/kustomize; \
	fi
	test -s $(LOCALBIN)/kustomize || { curl -Ss $(KUSTOMIZE_INSTALL_SCRIPT) | bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(LOCALBIN); }

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary. If wrong version is installed, it will be overwritten.
$(CONTROLLER_GEN): $(LOCALBIN)
	test -s $(LOCALBIN)/controller-gen && $(LOCALBIN)/controller-gen --version | grep -q $(CONTROLLER_TOOLS_VERSION) || \
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)

.PHONY: envtest
envtest: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST): $(LOCALBIN)
	test -s $(LOCALBIN)/setup-envtest || GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
