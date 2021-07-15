--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local require = require
local core = require("apisix.core")
local discovery = require("apisix.discovery.init").discovery
local upstream_util = require("apisix.utils.upstream")
local apisix_ssl = require("apisix.ssl")
local balancer = require("ngx.balancer")
local error = error
local tostring = tostring
local ipairs = ipairs
local pairs = pairs
local is_http = ngx.config.subsystem == "http"
local upstreams
local healthcheck


local set_upstream_tls_client_param
local ok, apisix_ngx_upstream = pcall(require, "resty.apisix.upstream")
if ok then
    set_upstream_tls_client_param = apisix_ngx_upstream.set_cert_and_key
else
    set_upstream_tls_client_param = function ()
        return nil, "need to build APISIX-OpenResty to support upstream mTLS"
    end
end


local HTTP_CODE_UPSTREAM_UNAVAILABLE = 503
local _M = {}


local function set_directly(ctx, key, ver, conf)
    if not ctx then
        error("missing argument ctx", 2)
    end
    if not key then
        error("missing argument key", 2)
    end
    if not ver then
        error("missing argument ver", 2)
    end
    if not conf then
        error("missing argument conf", 2)
    end

    ctx.upstream_conf = conf
    ctx.upstream_version = ver
    ctx.upstream_key = key
    ctx.upstream_healthcheck_parent = conf.parent
    return
end
_M.set = set_directly


local function release_checker(healthcheck_parent)
    local checker = healthcheck_parent.checker
    core.log.info("try to release checker: ", tostring(checker))
    checker:clear()
    checker:stop()
end


local function get_healthchecker_name(value)
    return "upstream#" .. value.key
end
_M.get_healthchecker_name = get_healthchecker_name


local function create_checker(upstream)
    if healthcheck == nil then
        healthcheck = require("resty.healthcheck")
    end

    local healthcheck_parent = upstream.parent
    if healthcheck_parent.checker and healthcheck_parent.checker_upstream == upstream then
        return healthcheck_parent.checker
    end

    local checker, err = healthcheck.new({
        name = get_healthchecker_name(healthcheck_parent),
        shm_name = "upstream-healthcheck",
        checks = upstream.checks,
    })

    if not checker then
        core.log.error("fail to create healthcheck instance: ", err)
        return nil
    end

    if healthcheck_parent.checker then
        core.config_util.cancel_clean_handler(healthcheck_parent,
                                              healthcheck_parent.checker_idx, true)
    end

    core.log.info("create new checker: ", tostring(checker))

    local host = upstream.checks and upstream.checks.active and upstream.checks.active.host
    local port = upstream.checks and upstream.checks.active and upstream.checks.active.port
    for _, node in ipairs(upstream.nodes) do
        local ok, err = checker:add_target(node.host, port or node.port, host)
        if not ok then
            core.log.error("failed to add new health check target: ", node.host, ":",
                    port or node.port, " err: ", err)
        end
    end

    healthcheck_parent.checker = checker
    healthcheck_parent.checker_upstream = upstream
    healthcheck_parent.checker_idx =
        core.config_util.add_clean_handler(healthcheck_parent, release_checker)

    return checker
end


local function fetch_healthchecker(upstream)
    if not upstream.checks then
        return nil
    end

    return create_checker(upstream)
end


local function set_upstream_scheme(ctx, upstream)
    -- plugins like proxy-rewrite may already set ctx.upstream_scheme
    if not ctx.upstream_scheme then
        -- the old configuration doesn't have scheme field, so fallback to "http"
        ctx.upstream_scheme = upstream.scheme or "http"
    end

    ctx.var["upstream_scheme"] = ctx.upstream_scheme
end


local fill_node_info
do
    local scheme_to_port = {
        http = 80,
        https = 443,
        grpc = 80,
        grpcs = 443,
    }

    function fill_node_info(up_conf, scheme, is_stream)
        local nodes = up_conf.nodes
        if up_conf.nodes_ref == nodes then
            -- filled
            return true
        end

        local need_filled = false
        for _, n in ipairs(nodes) do
            if not is_stream and not n.port then
                if up_conf.scheme ~= scheme then
                    return nil, "Can't detect upstream's scheme. " ..
                                "You should either specify a port in the node " ..
                                "or specify the upstream.scheme explicitly"
                end

                need_filled = true
            end

            if not n.priority then
                need_filled = true
            end
        end

        up_conf.original_nodes = nodes

        if not need_filled then
            up_conf.nodes_ref = nodes
            return true
        end

        local filled_nodes = core.table.new(#nodes, 0)
        for i, n in ipairs(nodes) do
            if not n.port or not n.priority then
                filled_nodes[i] = core.table.clone(n)

                if not is_stream and not n.port then
                    filled_nodes[i].port = scheme_to_port[scheme]
                end

                -- fix priority for non-array nodes and nodes from service discovery
                if not n.priority then
                    filled_nodes[i].priority = 0
                end
            else
                filled_nodes[i] = n
            end
        end

        up_conf.nodes_ref = filled_nodes
        up_conf.nodes = filled_nodes
        return true
    end
end


function _M.set_by_route(route, api_ctx)
    if api_ctx.upstream_conf then
        -- upstream_conf has been set by traffic-split plugin
        return
    end

    local up_conf = api_ctx.matched_upstream
    if not up_conf then
        return 500, "missing upstream configuration in Route or Service"
    end
    -- core.log.info("up_conf: ", core.json.delay_encode(up_conf, true))

    if up_conf.service_name then
        if not discovery then
            return 500, "discovery is uninitialized"
        end
        if not up_conf.discovery_type then
            return 500, "discovery server need appoint"
        end

        local dis = discovery[up_conf.discovery_type]
        if not dis then
            local err = "discovery " .. up_conf.discovery_type .. " is uninitialized"
            return 500, err
        end

        local new_nodes, err = dis.nodes(up_conf.service_name)
        if not new_nodes then
            return HTTP_CODE_UPSTREAM_UNAVAILABLE, "no valid upstream node: " .. (err or "nil")
        end

        local same = upstream_util.compare_upstream_node(up_conf, new_nodes)
        if not same then
            local pass, err = core.schema.check(core.schema.discovery_nodes, new_nodes)
            if not pass then
                return HTTP_CODE_UPSTREAM_UNAVAILABLE, "invalid nodes format: " .. err
            end

            up_conf.nodes = new_nodes
            local new_up_conf = core.table.clone(up_conf)
            core.log.info("discover new upstream from ", up_conf.service_name, ", type ",
                          up_conf.discovery_type, ": ",
                          core.json.delay_encode(new_up_conf, true))

            local parent = up_conf.parent
            if parent.value.upstream then
                -- the up_conf comes from route or service
                parent.value.upstream = new_up_conf
            else
                parent.value = new_up_conf
            end
            up_conf = new_up_conf
        end
    end

    set_directly(api_ctx, up_conf.type .. "#upstream_" .. tostring(up_conf),
                 api_ctx.conf_version, up_conf)

    local nodes_count = up_conf.nodes and #up_conf.nodes or 0
    if nodes_count == 0 then
        return HTTP_CODE_UPSTREAM_UNAVAILABLE, "no valid upstream node"
    end

    if not is_http then
        local ok, err = fill_node_info(up_conf, nil, true)
        if not ok then
            return 503, err
        end

        return
    end

    set_upstream_scheme(api_ctx, up_conf)

    local ok, err = fill_node_info(up_conf, api_ctx.upstream_scheme, false)
    if not ok then
        return 503, err
    end

    if nodes_count > 1 then
        local checker = fetch_healthchecker(up_conf)
        api_ctx.up_checker = checker
    end

    local scheme = up_conf.scheme
    if (scheme == "https" or scheme == "grpcs") and up_conf.tls then
        -- the sni here is just for logging
        local sni = api_ctx.var.upstream_host
        local cert, err = apisix_ssl.fetch_cert(sni, up_conf.tls.client_cert)
        if not ok then
            return 503, err
        end

        local key, err = apisix_ssl.fetch_pkey(sni, up_conf.tls.client_key)
        if not ok then
            return 503, err
        end

        if scheme == "grpcs" then
            api_ctx.upstream_grpcs_cert = cert
            api_ctx.upstream_grpcs_key = key
        else
            local ok, err = set_upstream_tls_client_param(cert, key)
            if not ok then
                return 503, err
            end
        end
    end

    return
end


function _M.set_grpcs_upstream_param(ctx)
    if ctx.upstream_grpcs_cert then
        local cert = ctx.upstream_grpcs_cert
        local key = ctx.upstream_grpcs_key
        local ok, err = set_upstream_tls_client_param(cert, key)
        if not ok then
            return 503, err
        end
    end
end


function _M.upstreams()
    if not upstreams then
        return nil, nil
    end

    return upstreams.values, upstreams.conf_version
end


function _M.check_schema(conf)
    return core.schema.check(core.schema.upstream, conf)
end


local function get_chash_key_schema(hash_on)
    if not hash_on then
        return nil, "hash_on is nil"
    end

    if hash_on == "vars" then
        return core.schema.upstream_hash_vars_schema
    end

    if hash_on == "header" or hash_on == "cookie" then
        return core.schema.upstream_hash_header_schema
    end

    if hash_on == "consumer" then
        return nil, nil
    end

    if hash_on == "vars_combinations" then
        return core.schema.upstream_hash_vars_combinations_schema
    end

    return nil, "invalid hash_on type " .. hash_on
end


local function check_upstream_conf(in_dp, conf)
    if not in_dp then
        local ok, err = core.schema.check(core.schema.upstream, conf)
        if not ok then
            return false, "invalid configuration: " .. err
        end

        -- encrypt the key in the admin
        if conf.tls and conf.tls.client_key then
            conf.tls.client_key = apisix_ssl.aes_encrypt_pkey(conf.tls.client_key)
        end
    end

    if conf.pass_host == "node" and conf.nodes and
        not balancer.recreate_request and core.table.nkeys(conf.nodes) ~= 1
    then
        return false, "only support single node for `node` mode currently"
    end

    if conf.pass_host == "rewrite" and
        (conf.upstream_host == nil or conf.upstream_host == "")
    then
        return false, "`upstream_host` can't be empty when `pass_host` is `rewrite`"
    end

    if conf.tls then
        local cert = conf.tls.client_cert
        local key = conf.tls.client_key
        local ok, err = apisix_ssl.validate(cert, key)
        if not ok then
            return false, err
        end
    end

    if conf.type ~= "chash" then
        return true
    end

    if conf.hash_on ~= "consumer" and not conf.key then
        return false, "missing key"
    end

    local key_schema, err = get_chash_key_schema(conf.hash_on)
    if err then
        return false, "type is chash, err: " .. err
    end

    if key_schema then
        local ok, err = core.schema.check(key_schema, conf.key)
        if not ok then
            return false, "invalid configuration: " .. err
        end
    end

    return true
end


function _M.check_upstream_conf(conf)
    return check_upstream_conf(false, conf)
end


local function filter_upstream(value, parent)
    if not value then
        return
    end

    value.parent = parent

    if not value.nodes then
        return
    end

    local nodes = value.nodes
    if core.table.isarray(nodes) then
        for _, node in ipairs(nodes) do
            local host = node.host
            if not core.utils.parse_ipv4(host) and
                    not core.utils.parse_ipv6(host) then
                parent.has_domain = true
                break
            end
        end
    else
        local new_nodes = core.table.new(core.table.nkeys(nodes), 0)
        for addr, weight in pairs(nodes) do
            local host, port = core.utils.parse_addr(addr)
            if not core.utils.parse_ipv4(host) and
                    not core.utils.parse_ipv6(host) then
                parent.has_domain = true
            end
            local node = {
                host = host,
                port = port,
                weight = weight,
            }
            core.table.insert(new_nodes, node)
        end
        value.nodes = new_nodes
    end
end
_M.filter_upstream = filter_upstream


function _M.init_worker()
    local err
    upstreams, err = core.config.new("/upstreams", {
            automatic = true,
            item_schema = core.schema.upstream,
            -- also check extra fields in the DP side
            checker = function (item, schema_type)
                return check_upstream_conf(true, item)
            end,
            filter = function(upstream)
                upstream.has_domain = false

                filter_upstream(upstream.value, upstream)

                core.log.info("filter upstream: ", core.json.delay_encode(upstream, true))
            end,
        })
    if not upstreams then
        error("failed to create etcd instance for fetching upstream: " .. err)
        return
    end
end


return _M
