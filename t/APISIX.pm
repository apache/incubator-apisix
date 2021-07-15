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
package t::APISIX;

use lib 'lib';
use Cwd qw(cwd);
use Test::Nginx::Socket::Lua::Stream -Base;

repeat_each(1);
log_level('info');
no_long_string();
no_shuffle();
no_root_location(); # avoid generated duplicate 'location /'
worker_connections(128);
master_on();

my $apisix_home = $ENV{APISIX_HOME} || cwd();
my $nginx_binary = $ENV{'TEST_NGINX_BINARY'} || 'nginx';
$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

sub read_file($) {
    my $infile = shift;
    open my $in, "$apisix_home/$infile"
        or die "cannot open $infile for reading: $!";
    my $data = do { local $/; <$in> };
    close $in;
    $data;
}

sub local_dns_resolver() {
    open my $in, "/etc/resolv.conf" or die "cannot open /etc/resolv.conf";
    my @lines =  <$in>;
    my @dns_addrs = ();
    foreach my $line (@lines){
        $line =~ m/^nameserver\s+(\d+[.]\d+[.]\d+[.]\d+)\s*$/;
        if ($1) {
            push(@dns_addrs, $1);
        }
    }
    close($in);
    return @dns_addrs
}


my $dns_addrs_str = "";
my $dns_addrs_tbl_str = "";
my $enable_local_dns = $ENV{"ENABLE_LOCAL_DNS"};
if ($enable_local_dns) {
    my @dns_addrs = local_dns_resolver();
    $dns_addrs_tbl_str = "{";
    foreach my $addr (@dns_addrs){
        $dns_addrs_str = "$dns_addrs_str $addr";
        $dns_addrs_tbl_str = "$dns_addrs_tbl_str\"$addr\", ";
    }
    $dns_addrs_tbl_str = "$dns_addrs_tbl_str}";
} else {
    $dns_addrs_str = "8.8.8.8 114.114.114.114";
    $dns_addrs_tbl_str = "{\"8.8.8.8\", \"114.114.114.114\"}";
}
my $custom_dns_server = $ENV{"CUSTOM_DNS_SERVER"};
if ($custom_dns_server) {
    $dns_addrs_tbl_str = "{\"$custom_dns_server\"}";
}


my $default_yaml_config = read_file("conf/config-default.yaml");
# enable example-plugin as some tests require it
$default_yaml_config =~ s/#- example-plugin/- example-plugin/;
$default_yaml_config =~ s/enable_export_server: true/enable_export_server: false/;

my $user_yaml_config = read_file("conf/config.yaml");
my $ssl_crt = read_file("t/certs/apisix.crt");
my $ssl_key = read_file("t/certs/apisix.key");
my $ssl_ecc_crt = read_file("t/certs/apisix_ecc.crt");
my $ssl_ecc_key = read_file("t/certs/apisix_ecc.key");
my $test2_crt = read_file("t/certs/test2.crt");
my $test2_key = read_file("t/certs/test2.key");
my $test_50x_html = read_file("t/error_page/50x.html");
$user_yaml_config = <<_EOC_;
apisix:
  node_listen: 1984
  stream_proxy:
    tcp:
      - 9100
  admin_key: null
  enable_resolv_search_opt: false
_EOC_

my $etcd_enable_auth = $ENV{"ETCD_ENABLE_AUTH"} || "false";

if ($etcd_enable_auth eq "true") {
    $user_yaml_config .= <<_EOC_;
etcd:
  user: root
  password: 5tHkHhYkjr6cQY
_EOC_
}

my $custom_hmac_auth = $ENV{"CUSTOM_HMAC_AUTH"} || "false";
if ($custom_hmac_auth eq "true") {
    $user_yaml_config .= <<_EOC_;
plugin_attr:
  hmac-auth:
    signature_key: X-APISIX-HMAC-SIGNATURE
    algorithm_key: X-APISIX-HMAC-ALGORITHM
    date_key: X-APISIX-DATE
    access_key: X-APISIX-HMAC-ACCESS-KEY
    signed_headers_key: X-APISIX-HMAC-SIGNED-HEADERS
_EOC_
}


my $profile = $ENV{"APISIX_PROFILE"};


my $apisix_file;
my $debug_file;
my $config_file;
if ($profile) {
    $apisix_file = "apisix-$profile.yaml";
    $debug_file = "debug-$profile.yaml";
    $config_file = "config-$profile.yaml";
} else {
    $apisix_file = "apisix.yaml";
    $debug_file = "debug.yaml";
    $config_file = "config.yaml";
}


my $dubbo_upstream = "";
my $dubbo_location = "";
my $version = eval { `$nginx_binary -V 2>&1` };
if ($version =~ m/\/mod_dubbo/) {
    $dubbo_upstream = <<_EOC_;
    upstream apisix_dubbo_backend {
        server 0.0.0.1;

        balancer_by_lua_block {
            apisix.http_balancer_phase()
        }

        multi 1;
        keepalive 320;
    }

_EOC_

    $dubbo_location = <<_EOC_;
        location \@dubbo_pass {
            access_by_lua_block {
                apisix.dubbo_access_phase()
            }

            dubbo_pass_all_headers on;
            dubbo_pass_body on;
            dubbo_pass \$dubbo_service_name \$dubbo_service_version \$dubbo_method apisix_dubbo_backend;

            header_filter_by_lua_block {
                apisix.http_header_filter_phase()
            }

            body_filter_by_lua_block {
                apisix.http_body_filter_phase()
            }

            log_by_lua_block {
                apisix.http_log_phase()
            }
        }

_EOC_
}

my $grpc_location = <<_EOC_;
        location \@grpc_pass {
            access_by_lua_block {
                apisix.grpc_access_phase()
            }

            grpc_set_header   Content-Type application/grpc;
            grpc_socket_keepalive on;
            grpc_pass         \$upstream_scheme://apisix_backend;

            header_filter_by_lua_block {
                apisix.http_header_filter_phase()
            }

            body_filter_by_lua_block {
                apisix.http_body_filter_phase()
            }

            log_by_lua_block {
                apisix.http_log_phase()
            }
        }
_EOC_

my $a6_ngx_directives = "";
if ($version =~ m/\/apisix-nginx-module/) {
    $a6_ngx_directives = <<_EOC_;
    apisix_delay_client_max_body_check on;
_EOC_
}

add_block_preprocessor(sub {
    my ($block) = @_;
    my $wait_etcd_sync = $block->wait_etcd_sync // 0.1;

    if ($block->apisix_yaml && (!defined $block->yaml_config)) {
        $user_yaml_config = <<_EOC_;
apisix:
    node_listen: 1984
    config_center: yaml
    enable_admin: false
_EOC_
    }

    my $lua_deps_path = <<_EOC_;
    lua_package_path "$apisix_home/?.lua;$apisix_home/?/init.lua;$apisix_home/deps/share/lua/5.1/?/init.lua;$apisix_home/deps/share/lua/5.1/?.lua;$apisix_home/apisix/?.lua;$apisix_home/t/?.lua;;";
    lua_package_cpath "$apisix_home/?.so;$apisix_home/deps/lib/lua/5.1/?.so;$apisix_home/deps/lib64/lua/5.1/?.so;;";
_EOC_

    my $main_config = $block->main_config // <<_EOC_;
worker_rlimit_core  500M;
env ENABLE_ETCD_AUTH;
env APISIX_PROFILE;
env PATH; # for searching external plugin runner's binary
env TEST_NGINX_HTML_DIR;
_EOC_

    # set default `timeout` to 5sec
    my $timeout = $block->timeout // 5;
    $block->set_value("timeout", $timeout);

    my $stream_tls_request = $block->stream_tls_request;
    if ($stream_tls_request) {
        # generate a springboard to send tls stream request
        $block->set_value("stream_conf_enable", 1);
        $block->set_value("request", "GET /stream_tls_request");

        my $sni = "nil";
        if ($block->stream_sni) {
            $sni = '"' . $block->stream_sni . '"';
        }
        chomp $stream_tls_request;

        my $repeat = "1";
        if (defined $block->stream_session_reuse) {
            $repeat = "2";
        }

        my $config = <<_EOC_;
            location /stream_tls_request {
                content_by_lua_block {
                    local sess
                    for _ = 1, $repeat do
                        local sock = ngx.socket.tcp()
                        local ok, err = sock:connect("127.0.0.1", 2005)
                        if not ok then
                            ngx.say("failed to connect: ", err)
                            return
                        end

                        sess, err = sock:sslhandshake(sess, $sni, false)
                        if not sess then
                            ngx.say("failed to do SSL handshake: ", err)
                            return
                        end

                        local bytes, err = sock:send("$stream_tls_request")
                        if not bytes then
                            ngx.say("send stream request error: ", err)
                            return
                        end
                        local data, err = sock:receive("*a")
                        if not data then
                            sock:close()
                            ngx.say("receive stream response error: ", err)
                            return
                        end
                        ngx.print(data)
                        sock:close()
                    end
                }
            }
_EOC_
        $block->set_value("config", $config)
    }

    my $stream_enable = $block->stream_enable;
    my $stream_conf_enable = $block->stream_conf_enable;
    my $extra_stream_config = $block->extra_stream_config // '';
    my $stream_upstream_code = $block->stream_upstream_code // <<_EOC_;
            local sock = ngx.req.socket()
            local data = sock:receive("1")
            ngx.say("hello world")
_EOC_

    my $stream_config = $block->stream_config // <<_EOC_;
    $lua_deps_path
    lua_socket_log_errors off;

    lua_shared_dict lrucache-lock-stream 10m;
    lua_shared_dict plugin-limit-conn-stream 10m;

    upstream apisix_backend {
        server 127.0.0.1:1900;
        balancer_by_lua_block {
            apisix.stream_balancer_phase()
        }
    }
_EOC_

    my $stream_init_by_lua_block = $block->stream_init_by_lua_block // <<_EOC_;
        if os.getenv("APISIX_ENABLE_LUACOV") == "1" then
            require("luacov.runner")("t/apisix.luacov")
            jit.off()
        end

        require "resty.core"

        apisix = require("apisix")
        local args = {
            dns_resolver = $dns_addrs_tbl_str,
        }
        apisix.stream_init(args)
_EOC_

    $stream_config .= <<_EOC_;
    init_by_lua_block {
        $stream_init_by_lua_block
    }
    init_worker_by_lua_block {
        apisix.stream_init_worker()
    }

    $extra_stream_config

    # fake server, only for test
    server {
        listen 1995;

        content_by_lua_block {
            $stream_upstream_code
        }
    }
_EOC_

    if (defined $stream_enable) {
        $block->set_value("stream_config", $stream_config);
    }

    my $stream_server_config = $block->stream_server_config // <<_EOC_;
    listen 2005 ssl;
    ssl_certificate             cert/apisix.crt;
    ssl_certificate_key         cert/apisix.key;
    lua_ssl_trusted_certificate cert/apisix.crt;

    ssl_certificate_by_lua_block {
        apisix.stream_ssl_phase()
    }

    preread_by_lua_block {
        -- wait for etcd sync
        ngx.sleep($wait_etcd_sync)
        apisix.stream_preread_phase()
    }

    proxy_pass apisix_backend;

    log_by_lua_block {
        apisix.stream_log_phase()
    }
_EOC_

    if (defined $stream_enable) {
        $block->set_value("stream_server_config", $stream_server_config);
    }

    if (defined $stream_conf_enable) {
        $main_config .= <<_EOC_;
stream {
$stream_config
    server {
        listen 1985;
        $stream_server_config
    }
}
_EOC_
    }

    $block->set_value("main_config", $main_config);

    my $extra_init_by_lua = $block->extra_init_by_lua // "";
    my $init_by_lua_block = $block->init_by_lua_block // <<_EOC_;
    if os.getenv("APISIX_ENABLE_LUACOV") == "1" then
        require("luacov.runner")("t/apisix.luacov")
        jit.off()
    end

    require "resty.core"

    apisix = require("apisix")
    local args = {
        dns_resolver = $dns_addrs_tbl_str,
    }
    apisix.http_init(args)
    $extra_init_by_lua
_EOC_

    my $extra_init_worker_by_lua = $block->extra_init_worker_by_lua // "";

    my $http_config = $block->http_config // '';
    $http_config .= <<_EOC_;
    $lua_deps_path

    lua_shared_dict plugin-limit-req 10m;
    lua_shared_dict plugin-limit-count 10m;
    lua_shared_dict plugin-limit-conn 10m;
    lua_shared_dict prometheus-metrics 10m;
    lua_shared_dict internal-status 10m;
    lua_shared_dict upstream-healthcheck 32m;
    lua_shared_dict worker-events 10m;
    lua_shared_dict lrucache-lock 10m;
    lua_shared_dict balancer-ewma 1m;
    lua_shared_dict balancer-ewma-locks 1m;
    lua_shared_dict balancer-ewma-last-touched-at 1m;
    lua_shared_dict plugin-limit-count-redis-cluster-slot-lock 1m;
    lua_shared_dict tracing_buffer 10m;    # plugin skywalking
    lua_shared_dict access-tokens 1m;    # plugin authz-keycloak
    lua_shared_dict discovery 1m;    # plugin authz-keycloak
    lua_shared_dict plugin-api-breaker 10m;
    lua_capture_error_log 1m;    # plugin error-log-logger
    lua_shared_dict etcd-cluster-health-check 10m; # etcd health check

    proxy_ssl_name \$upstream_host;
    proxy_ssl_server_name on;

    resolver $dns_addrs_str;
    resolver_timeout 5;

    underscores_in_headers on;
    lua_socket_log_errors off;
    client_body_buffer_size 8k;

    error_page 500 \@50x.html;

    variables_hash_bucket_size 128;

    upstream apisix_backend {
        server 0.0.0.1;
_EOC_

    if ($version =~ m/\/apisix-nginx-module/) {
    $http_config .= <<_EOC_;
        keepalive 32;

        balancer_by_lua_block {
            apisix.http_balancer_phase()
        }
_EOC_
    } else {
    $http_config .= <<_EOC_;
        balancer_by_lua_block {
            apisix.http_balancer_phase()
        }

        keepalive 32;
_EOC_
    }

    $http_config .= <<_EOC_;
    }

    $dubbo_upstream

    init_by_lua_block {
        $init_by_lua_block
    }

    init_worker_by_lua_block {
        require("apisix").http_init_worker()
        $extra_init_worker_by_lua
    }
_EOC_

    if ($version !~ m/\/1.17.8/) {
    $http_config .= <<_EOC_;
    exit_worker_by_lua_block {
        require("apisix").http_exit_worker()
    }
_EOC_
    }

    $http_config .= <<_EOC_;
    log_format main escape=default '\$remote_addr - \$remote_user [\$time_local] \$http_host "\$request" \$status \$body_bytes_sent \$request_time "\$http_referer" "\$http_user_agent" \$upstream_addr \$upstream_status \$upstream_response_time "\$upstream_scheme://\$upstream_host\$upstream_uri"';

    # fake server, only for test
    server {
        listen 1980;
        listen 1981;
        listen 1982;
        listen 5044;

_EOC_

    if (defined $block->upstream_server_config) {
        $http_config .= $block->upstream_server_config;
    }

    my $ipv6_fake_server = "";
    if (defined $block->listen_ipv6) {
        $ipv6_fake_server = "listen \[::1\]:1980;";
    }

    $http_config .= <<_EOC_;
        $ipv6_fake_server
        server_tokens off;

        location / {
            content_by_lua_block {
                require("lib.server").go()
            }

            more_clear_headers Date;
        }

        location \@50x.html {
            set \$from_error_page 'true';
            try_files /50x.html \$uri;
            header_filter_by_lua_block {
                apisix.http_header_filter_phase()
            }

            log_by_lua_block {
                apisix.http_log_phase()
            }
        }
    }

    $a6_ngx_directives

    server {
        listen 1983 ssl;
        ssl_certificate             cert/apisix.crt;
        ssl_certificate_key         cert/apisix.key;
        lua_ssl_trusted_certificate cert/apisix.crt;
_EOC_

    if (defined $block->upstream_server_config) {
        $http_config .= $block->upstream_server_config;
    }

    $http_config .= <<_EOC_;
        server_tokens off;

        ssl_certificate_by_lua_block {
            local ngx_ssl = require "ngx.ssl"
            ngx.log(ngx.WARN, "Receive SNI: ", ngx_ssl.server_name())
        }

        location / {
            content_by_lua_block {
                require("lib.server").go()
            }

            more_clear_headers Date;
        }
    }

_EOC_

    $block->set_value("http_config", $http_config);

    my $TEST_NGINX_HTML_DIR = $ENV{TEST_NGINX_HTML_DIR} ||= html_dir();
    my $ipv6_listen_conf = '';
    if (defined $block->listen_ipv6) {
        $ipv6_listen_conf = "listen \[::1\]:12345;"
    }

    my $config = $block->config // '';
    $config .= <<_EOC_;
        $ipv6_listen_conf

        listen 1994 ssl;
        ssl_certificate             cert/apisix.crt;
        ssl_certificate_key         cert/apisix.key;
        lua_ssl_trusted_certificate cert/apisix.crt;

        ssl_certificate_by_lua_block {
            apisix.http_ssl_phase()
        }

        set \$dubbo_service_name          '';
        set \$dubbo_service_version       '';
        set \$dubbo_method                '';

        location = /apisix/nginx_status {
            allow 127.0.0.0/24;
            access_log off;
            stub_status;
        }

        location /apisix/admin {
            set \$upstream_scheme             'http';
            set \$upstream_host               \$http_host;
            set \$upstream_uri                '';

            content_by_lua_block {
                apisix.http_admin()
            }
        }

        location \@50x.html {
            set \$from_error_page 'true';
            try_files /50x.html \$uri;
            header_filter_by_lua_block {
                apisix.http_header_filter_phase()
            }

            log_by_lua_block {
                apisix.http_log_phase()
            }
        }

        location /v1/ {
            content_by_lua_block {
                apisix.http_control()
            }
        }

        location / {
            set \$upstream_mirror_host        '';
            set \$upstream_upgrade            '';
            set \$upstream_connection         '';

            set \$upstream_scheme             'http';
            set \$upstream_host               \$http_host;
            set \$upstream_uri                '';
            set \$ctx_ref                     '';
            set \$from_error_page             '';

            set \$upstream_cache_zone            off;
            set \$upstream_cache_key             '';
            set \$upstream_cache_bypass          '';
            set \$upstream_no_cache              '';

            proxy_cache                         \$upstream_cache_zone;
            proxy_cache_valid                   any 10s;
            proxy_cache_min_uses                1;
            proxy_cache_methods                 GET HEAD;
            proxy_cache_lock_timeout            5s;
            proxy_cache_use_stale               off;
            proxy_cache_key                     \$upstream_cache_key;
            proxy_no_cache                      \$upstream_no_cache;
            proxy_cache_bypass                  \$upstream_cache_bypass;

            access_by_lua_block {
                -- wait for etcd sync
                ngx.sleep($wait_etcd_sync)
                apisix.http_access_phase()
            }

            proxy_http_version 1.1;
            proxy_set_header   Host              \$upstream_host;
            proxy_set_header   Upgrade           \$upstream_upgrade;
            proxy_set_header   Connection        \$upstream_connection;
            proxy_set_header   X-Real-IP         \$remote_addr;
            proxy_pass_header  Date;

            ### the following x-forwarded-* headers is to send to upstream server

            set \$var_x_forwarded_for        \$remote_addr;
            set \$var_x_forwarded_proto      \$scheme;
            set \$var_x_forwarded_host       \$host;
            set \$var_x_forwarded_port       \$server_port;

            if (\$http_x_forwarded_for != "") {
                set \$var_x_forwarded_for "\${http_x_forwarded_for}, \${realip_remote_addr}";
            }
            if (\$http_x_forwarded_host != "") {
                set \$var_x_forwarded_host \$http_x_forwarded_host;
            }
            if (\$http_x_forwarded_port != "") {
                set \$var_x_forwarded_port \$http_x_forwarded_port;
            }

            proxy_set_header   X-Forwarded-For      \$var_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto    \$var_x_forwarded_proto;
            proxy_set_header   X-Forwarded-Host     \$var_x_forwarded_host;
            proxy_set_header   X-Forwarded-Port     \$var_x_forwarded_port;

            proxy_pass         \$upstream_scheme://apisix_backend\$upstream_uri;
            mirror             /proxy_mirror;

            header_filter_by_lua_block {
                apisix.http_header_filter_phase()
            }

            body_filter_by_lua_block {
                apisix.http_body_filter_phase()
            }

            log_by_lua_block {
                apisix.http_log_phase()
            }
        }

        $grpc_location
        $dubbo_location

        location = /proxy_mirror {
            internal;

            if (\$upstream_mirror_host = "") {
                return 200;
            }

            proxy_http_version 1.1;
            proxy_set_header Host \$upstream_host;
            proxy_pass \$upstream_mirror_host\$request_uri;
        }
_EOC_

    $block->set_value("config", $config);

    my $user_apisix_yaml = $block->apisix_yaml // "";
    if ($user_apisix_yaml) {
        $user_apisix_yaml = <<_EOC_;
>>> ../conf/$apisix_file
$user_apisix_yaml
_EOC_
    }

    my $yaml_config = $block->yaml_config // $user_yaml_config;

    if ($block->extra_yaml_config) {
        $yaml_config .= $block->extra_yaml_config;
    }

    my $user_debug_config = $block->debug_config // "";

    my $user_files = $block->user_files;
    $user_files .= <<_EOC_;
>>> ../conf/$debug_file
$user_debug_config
>>> ../conf/config-default.yaml
$default_yaml_config
>>> ../conf/$config_file
$yaml_config
>>> ../conf/cert/apisix.crt
$ssl_crt
>>> ../conf/cert/apisix.key
$ssl_key
>>> ../conf/cert/apisix_ecc.crt
$ssl_ecc_crt
>>> ../conf/cert/apisix_ecc.key
$ssl_ecc_key
>>> ../conf/cert/test2.crt
$test2_crt
>>> ../conf/cert/test2.key
$test2_key
>>> 50x.html
$test_50x_html
$user_apisix_yaml
_EOC_

    $block->set_value("user_files", $user_files);

    $block;
});

sub run_or_exit ($) {
    my ($cmd) = @_;
    my $output = `$cmd`;
    if ($?) {
        warn "$output";
        exit 1;
    }
}

add_cleanup_handler(sub {
    if ($ENV{FLUSH_ETCD}) {
        delete $ENV{APISIX_PROFILE};
        run_or_exit "etcdctl del --prefix /apisix";
        run_or_exit "./bin/apisix init_etcd";
    }
});

1;
