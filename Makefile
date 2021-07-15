#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

INST_PREFIX ?= /usr
INST_LIBDIR ?= $(INST_PREFIX)/lib64/lua/5.1
INST_LUADIR ?= $(INST_PREFIX)/share/lua/5.1
INST_BINDIR ?= /usr/bin
INSTALL ?= install
UNAME ?= $(shell uname)
UNAME_MACHINE ?= $(shell uname -m)
OR_EXEC ?= $(shell which openresty || which nginx)
LUAROCKS ?= luarocks
LUAROCKS_VER ?= $(shell luarocks --version | grep -E -o  "luarocks [0-9]+.")
OR_PREFIX ?= $(shell $(OR_EXEC) -V 2>&1 | grep -Eo 'prefix=(.*)/nginx\s+' | grep -Eo '/.*/')
OPENSSL_PREFIX ?= $(addprefix $(OR_PREFIX), openssl)
HOMEBREW_PREFIX ?= /usr/local

# OpenResty 1.17.8 or higher version uses openssl111 as the openssl dirname.
ifeq ($(shell test -d $(addprefix $(OR_PREFIX), openssl111) && echo -n yes), yes)
	OPENSSL_PREFIX=$(addprefix $(OR_PREFIX), openssl111)
endif

ifeq ($(UNAME), Darwin)
ifeq ($(UNAME_MACHINE), arm64)
	HOMEBREW_PREFIX=/opt/homebrew
endif
LUAROCKS=luarocks --lua-dir=$(HOMEBREW_PREFIX)/opt/lua@5.1
ifeq ($(shell test -d $(HOMEBREW_PREFIX)/opt/openresty-openssl && echo yes), yes)
	OPENSSL_PREFIX=$(HOMEBREW_PREFIX)/opt/openresty-openssl
endif
ifeq ($(shell test -d $(HOMEBREW_PREFIX)/opt/openresty-openssl111 && echo yes), yes)
	OPENSSL_PREFIX=$(HOMEBREW_PREFIX)/opt/openresty-openssl111
endif
endif

LUAROCKS_SERVER_OPT =
ifneq ($(LUAROCKS_SERVER), )
	LUAROCKS_SERVER_OPT = --server ${LUAROCKS_SERVER}
endif

SHELL := /bin/bash -o pipefail

VERSION ?= latest
RELEASE_SRC = apache-apisix-${VERSION}-src

.PHONY: default
default:
ifeq ($(OR_EXEC), )
ifeq ("$(wildcard /usr/local/openresty-debug/bin/openresty)", "")
	@echo "WARNING: OpenResty not found. You have to install OpenResty and add the binary file to PATH before install Apache APISIX."
	exit 1
else
	OR_EXEC=/usr/local/openresty-debug/bin/openresty
endif
endif

LUAJIT_DIR ?= $(shell ${OR_EXEC} -V 2>&1 | grep prefix | grep -Eo 'prefix=(.*)/nginx\s+--' | grep -Eo '/.*/')luajit

### help:             Show Makefile rules
.PHONY: help
help: default
	@echo Makefile rules:
	@echo
	@grep -E '^### [-A-Za-z0-9_]+:' Makefile | sed 's/###/   /'


### deps:             Installation dependencies
.PHONY: deps
deps: default
ifeq ($(LUAROCKS_VER),luarocks 3.)
	mkdir -p ~/.luarocks
ifeq ($(shell whoami),root)
	$(LUAROCKS) config variables.OPENSSL_LIBDIR $(addprefix $(OPENSSL_PREFIX), /lib)
	$(LUAROCKS) config variables.OPENSSL_INCDIR $(addprefix $(OPENSSL_PREFIX), /include)
else
	$(LUAROCKS) config --local variables.OPENSSL_LIBDIR $(addprefix $(OPENSSL_PREFIX), /lib)
	$(LUAROCKS) config --local variables.OPENSSL_INCDIR $(addprefix $(OPENSSL_PREFIX), /include)
endif
	$(LUAROCKS) install rockspec/apisix-master-0.rockspec --tree=deps --only-deps --local $(LUAROCKS_SERVER_OPT)
else
	@echo "WARN: You're not using LuaRocks 3.x, please add the following items to your LuaRocks config file:"
	@echo "variables = {"
	@echo "    OPENSSL_LIBDIR=$(addprefix $(OPENSSL_PREFIX), /lib)"
	@echo "    OPENSSL_INCDIR=$(addprefix $(OPENSSL_PREFIX), /include)"
	@echo "}"
	luarocks install rockspec/apisix-master-0.rockspec --tree=deps --only-deps --local $(LUAROCKS_SERVER_OPT)
endif


### utils:            Installation tools
.PHONY: utils
utils:
ifeq ("$(wildcard utils/lj-releng)", "")
	wget -P utils https://raw.githubusercontent.com/iresty/openresty-devel-utils/master/lj-releng
	chmod a+x utils/lj-releng
endif
ifeq ("$(wildcard utils/reindex)", "")
	wget -P utils https://raw.githubusercontent.com/iresty/openresty-devel-utils/master/reindex
	chmod a+x utils/reindex
endif


### lint:             Lint source code
.PHONY: lint
lint: utils
	./utils/check-lua-code-style.sh
	./utils/check-test-code-style.sh


### init:             Initialize the runtime environment
.PHONY: init
init: default
	./bin/apisix init
	./bin/apisix init_etcd


### run:              Start the apisix server
.PHONY: run
run: default
	./bin/apisix start


### quit:             Stop the apisix server, exit gracefully
.PHONY: quit
quit: default
	./bin/apisix quit


### stop:             Stop the apisix server, exit immediately
.PHONY: stop
stop: default
	./bin/apisix stop


### verify:           Verify the configuration of apisix server
.PHONY: verify
verify: default
	$(OR_EXEC) -p $$PWD/ -c $$PWD/conf/nginx.conf -t


### clean:            Remove generated files
.PHONY: clean
clean:
	rm -rf logs/


### reload:           Reload the apisix server
.PHONY: reload
reload: default
	$(OR_EXEC) -p $$PWD/  -c $$PWD/conf/nginx.conf -s reload


### install:          Install the apisix (only for luarocks)
.PHONY: install
install: default
	$(INSTALL) -d /usr/local/apisix/
	$(INSTALL) -d /usr/local/apisix/logs/
	$(INSTALL) -d /usr/local/apisix/conf/cert
	$(INSTALL) conf/mime.types /usr/local/apisix/conf/mime.types
	$(INSTALL) conf/config.yaml /usr/local/apisix/conf/config.yaml
	$(INSTALL) conf/config-default.yaml /usr/local/apisix/conf/config-default.yaml
	$(INSTALL) conf/debug.yaml /usr/local/apisix/conf/debug.yaml
	$(INSTALL) conf/cert/* /usr/local/apisix/conf/cert/

	$(INSTALL) -d $(INST_LUADIR)/apisix
	$(INSTALL) apisix/*.lua $(INST_LUADIR)/apisix/

	$(INSTALL) -d $(INST_LUADIR)/apisix/admin
	$(INSTALL) apisix/admin/*.lua $(INST_LUADIR)/apisix/admin/

	$(INSTALL) -d $(INST_LUADIR)/apisix/balancer
	$(INSTALL) apisix/balancer/*.lua $(INST_LUADIR)/apisix/balancer/

	$(INSTALL) -d $(INST_LUADIR)/apisix/control
	$(INSTALL) apisix/control/*.lua $(INST_LUADIR)/apisix/control/

	$(INSTALL) -d $(INST_LUADIR)/apisix/core
	$(INSTALL) apisix/core/*.lua $(INST_LUADIR)/apisix/core/

	$(INSTALL) -d $(INST_LUADIR)/apisix/core/dns
	$(INSTALL) apisix/core/dns/*.lua $(INST_LUADIR)/apisix/core/dns

	$(INSTALL) -d $(INST_LUADIR)/apisix/cli
	$(INSTALL) apisix/cli/*.lua $(INST_LUADIR)/apisix/cli/

	$(INSTALL) -d $(INST_LUADIR)/apisix/discovery
	$(INSTALL) apisix/discovery/*.lua $(INST_LUADIR)/apisix/discovery/

	$(INSTALL) -d $(INST_LUADIR)/apisix/http
	$(INSTALL) apisix/http/*.lua $(INST_LUADIR)/apisix/http/

	$(INSTALL) -d $(INST_LUADIR)/apisix/http/router
	$(INSTALL) apisix/http/router/*.lua $(INST_LUADIR)/apisix/http/router/

	$(INSTALL) -d $(INST_LUADIR)/apisix/plugins
	$(INSTALL) apisix/plugins/*.lua $(INST_LUADIR)/apisix/plugins/

	$(INSTALL) -d $(INST_LUADIR)/apisix/plugins/ext-plugin
	$(INSTALL) apisix/plugins/ext-plugin/*.lua $(INST_LUADIR)/apisix/plugins/ext-plugin/

	$(INSTALL) -d $(INST_LUADIR)/apisix/plugins/grpc-transcode
	$(INSTALL) apisix/plugins/grpc-transcode/*.lua $(INST_LUADIR)/apisix/plugins/grpc-transcode/

	$(INSTALL) -d $(INST_LUADIR)/apisix/plugins/ip-restriction
	$(INSTALL) apisix/plugins/ip-restriction/*.lua $(INST_LUADIR)/apisix/plugins/ip-restriction/

	$(INSTALL) -d $(INST_LUADIR)/apisix/plugins/limit-conn
	$(INSTALL) apisix/plugins/limit-conn/*.lua $(INST_LUADIR)/apisix/plugins/limit-conn/

	$(INSTALL) -d $(INST_LUADIR)/apisix/plugins/limit-count
	$(INSTALL) apisix/plugins/limit-count/*.lua $(INST_LUADIR)/apisix/plugins/limit-count/

	$(INSTALL) -d $(INST_LUADIR)/apisix/plugins/prometheus
	$(INSTALL) apisix/plugins/prometheus/*.lua $(INST_LUADIR)/apisix/plugins/prometheus/

	$(INSTALL) -d $(INST_LUADIR)/apisix/plugins/serverless
	$(INSTALL) apisix/plugins/serverless/*.lua $(INST_LUADIR)/apisix/plugins/serverless/

	$(INSTALL) -d $(INST_LUADIR)/apisix/plugins/zipkin
	$(INSTALL) apisix/plugins/zipkin/*.lua $(INST_LUADIR)/apisix/plugins/zipkin/

	$(INSTALL) -d $(INST_LUADIR)/apisix/ssl/router
	$(INSTALL) apisix/ssl/router/*.lua $(INST_LUADIR)/apisix/ssl/router/

	$(INSTALL) -d $(INST_LUADIR)/apisix/stream/plugins
	$(INSTALL) apisix/stream/plugins/*.lua $(INST_LUADIR)/apisix/stream/plugins/

	$(INSTALL) -d $(INST_LUADIR)/apisix/stream/router
	$(INSTALL) apisix/stream/router/*.lua $(INST_LUADIR)/apisix/stream/router/

	$(INSTALL) -d $(INST_LUADIR)/apisix/utils
	$(INSTALL) apisix/utils/*.lua $(INST_LUADIR)/apisix/utils/

	$(INSTALL) README.md $(INST_CONFDIR)/README.md
	$(INSTALL) bin/apisix $(INST_BINDIR)/apisix

	$(INSTALL) -d $(INST_LUADIR)/apisix/plugins/slslog
	$(INSTALL) apisix/plugins/slslog/*.lua $(INST_LUADIR)/apisix/plugins/slslog/


### test:             Run the test case
.PHONY: test
test:
	git submodule update --init --recursive
	prove -I../test-nginx/lib -I./ -r -s t/

### license-check:    Check Lua source code for Apache License
.PHONY: license-check
license-check:
ifeq ("$(wildcard ci/openwhisk-utilities/scancode/scanCode.py)", "")
	git clone https://github.com/apache/openwhisk-utilities.git ci/openwhisk-utilities
	cp ci/ASF* ci/openwhisk-utilities/scancode/
endif
	ci/openwhisk-utilities/scancode/scanCode.py --config ci/ASF-Release.cfg ./

.PHONY: release-src
release-src: compress-tar
	gpg --batch --yes --armor --detach-sig $(RELEASE_SRC).tgz
	shasum -a 512 $(RELEASE_SRC).tgz > $(RELEASE_SRC).tgz.sha512

	mkdir -p release
	mv $(RELEASE_SRC).tgz release/$(RELEASE_SRC).tgz
	mv $(RELEASE_SRC).tgz.asc release/$(RELEASE_SRC).tgz.asc
	mv $(RELEASE_SRC).tgz.sha512 release/$(RELEASE_SRC).tgz.sha512

.PHONY: compress-tar
compress-tar:
	tar -zcvf $(RELEASE_SRC).tgz \
	./apisix \
	./bin \
	./conf \
	./rockspec/apisix-$(VERSION)-*.rockspec \
	./rockspec/apisix-master-0.rockspec \
	LICENSE \
	Makefile \
	NOTICE \
	*.md
