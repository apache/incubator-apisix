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
local require            = require
local local_conf         = require("apisix.core.config_local").local_conf()
local core               = require("apisix.core")
local resty_consul       = require('resty.consul')
local cjson              = require('cjson')
local http               = require('resty.http')
local util               = require("apisix.cli.util")
local ipairs             = ipairs
local error              = error
local ngx                = ngx
local unpack             = unpack
local ngx_re_match       = ngx.re.match
local tonumber           = tonumber
local pairs              = pairs
local ipairs             = ipairs
local ngx_timer_at       = ngx.timer.at
local ngx_timer_every    = ngx.timer.every
local log                = core.log
local ngx_decode_base64  = ngx.decode_base64
local json_delay_encode  = core.json.delay_encode
local cjson_null         = cjson.null

local applications = core.table.new(0, 5)
local default_service
local default_weight
local default_prefix_rule
local skip_keys_map = core.table.new(0, 1)
local dump_params

local events
local events_list
local consul_apps

local schema = {
    type = "object",
    properties = {
        servers = {
            type = "array",
            minItems = 1,
            items = {
                type = "string",
            }
        },
        fetch_interval = {type = "integer", minimum = 1, default = 3},
        keepalive = {
            type = "boolean",
            default = true
        },
        prefix = {type = "string", default = "upstreams"},
        weight = {type = "integer", minimum = 1, default = 1},
        timeout = {
            type = "object",
            properties = {
                connect = {type = "integer", minimum = 1, default = 2000},
                read = {type = "integer", minimum = 1, default = 2000},
                wait = {type = "integer", minimum = 1, default = 60}
            },
            default = {
                connect = 2000,
                read = 2000,
                wait = 60,
            }
        },
        skip_keys = {
            type = "array",
            minItems = 1,
            items = {
                type = "string",
            }
        },
        dump = {
            type = "object",
            properties = {
                path = {type = "string", minLength = 1},
                load_on_init = {type = "boolean", default = true},
                expire = {type = "integer", default = 0},
            },
            required = {"path"},
        },
        default_service = {
            type = "object",
            properties = {
                host = {type = "string"},
                port = {type = "integer"},
                metadata = {
                    type = "object",
                    properties = {
                        fail_timeout = {type = "integer", default = 1},
                        weight = {type = "integer", default = 1},
                        max_fails = {type = "integer", default = 1}
                    },
                    default = {
                        fail_timeout = 1,
                        weight = 1,
                        max_fails = 1
                    }
                }
            }
        }
    },

    required = {"servers"}
}

local _M = {
    version = 0.3,
}


local function discovery_consul_callback(data, event, source, pid)
    applications = data
    log.notice("update local variable application, event is: ", event,
        "source: ", source, "server pid:", pid,
        ", application: ", core.json.encode(applications, true))
end


function _M.all_nodes()
    return applications
end


function _M.nodes(service_name)
    if not applications then
        log.error("application is nil, failed to fetch nodes for : ", service_name)
        return
    end

    local resp_list = applications[service_name]

    if not resp_list then
        log.error("fetch nodes failed by ", service_name, ", return default service")
        return default_service and {default_service}
    end

    log.info("process id: ", ngx.worker.id(), ", applications[", service_name, "] = ",
        json_delay_encode(resp_list, true))

    return resp_list
end


local function parse_instance(node, server_name_prefix)
    local key = node.Key

    if key == cjson_null or not key or #key == 0 then
        log.error("consul_key_empty, server_name_prefix: ", server_name_prefix,
            ", node: ", json_delay_encode(node, true))
        return false
    end

    local result = ngx_re_match(key, default_prefix_rule, "jo")
    if not result then
        log.error("server name parse error, server_name_prefix: ", server_name_prefix,
            ", node: ", json_delay_encode(node, true))
        return false
    end

    local sn, host, port = result[1], result[2], result[3]

    -- if exist, skip special kesy
    if sn and skip_keys_map[sn] then
        return false
    end

    -- base64 value   = "IHsid2VpZ2h0IjogMTIwLCAibWF4X2ZhaWxzIjogMiwgImZhaWxfdGltZW91dCI6IDJ9"
    -- ori    value   = "{"weight": 120, "max_fails": 2, "fail_timeout": 2}"
    local metadataBase64 = node.Value
    if metadataBase64 == cjson_null or not metadataBase64 or #metadataBase64 == 0 then
        log.error("error: consul_value_empty, server_name_prefix: ", server_name_prefix,
            ", node: ", json_delay_encode(node, true))
        return false
    end

    local metadata, err = core.json.decode(ngx_decode_base64(metadataBase64))
    if err then
        log.error("invalid upstream value, server_name_prefix: ", server_name_prefix,
            ",err: ", err, ", node: ", json_delay_encode(node, true))
        return false
    elseif metadata.check_status == false or metadata.check_status == "false" then
        log.error("server node unhealthy, server_name_prefix: ", server_name_prefix,
            ", node: ", json_delay_encode(node, true))
        return false
    end

    return true, host, tonumber(port), metadata, sn
end


local function update_application(server_name_prefix, data)
    local sn
    local up_apps = core.table.new(0, #data)
    local weight = default_weight

    for _, node in ipairs(data) do
        local succ, ip, port, metadata, server_name = parse_instance(node, server_name_prefix)
        if succ then
            sn = server_name_prefix .. server_name
            local nodes = up_apps[sn]
            if not nodes then
                nodes = core.table.new(1, 0)
                up_apps[sn] = nodes
            end
            core.table.insert(nodes, {
                host = ip,
                port = port,
                weight = metadata and metadata.weight or weight,
            })
        end
    end

    -- clean old unused data
    local old_apps = consul_apps[server_name_prefix] or {}
    for k, _ in pairs(old_apps) do
        applications[k] = nil
    end
    core.table.clear(old_apps)

    for k, v in pairs(up_apps) do
        applications[k] = v
    end
    consul_apps[server_name_prefix] = up_apps

    log.info("update applications: ", core.json.encode(applications))
end


local function read_dump_srvs()
    local data, err = util.read_file(dump_params.path)
    if not data then
        log.notice("read dump file get error: ", err)
        return
    end

    log.info("read dump file: ", data)
    data = util.trim(data)
    if #data == 0 then
        log.error("dump file is empty")
        return
    end

    local entity, err  = core.json.decode(data)
    if err then
        log.error("decoded dump data got error: ", err, ", file content: ", data)
        return
    end

    if not entity.services or not entity.last_update then
        log.warn("decoded dump data miss fields, file content: ", data)
        return
    end

    local now_time = ngx.time()
    log.info("dump file last_update: ", entity.last_update, ", dump_params.expire: ",
        dump_params.expire, ", now_time: ", now_time)
    if dump_params.expire ~= 0  and (entity.last_update + dump_params.expire) < now_time then
       log.warn("dump file: ", dump_params.path, " had expired, ignored it")
       return
    end

    applications = entity.services
    log.info("load dump file into memory success")
end


local function write_dump_srvs()
    local entity = {
        services = applications,
        last_update = ngx.time(),
        expire = dump_params.expire, -- later need handle it
    }
    local data = core.json.encode(entity)
    local succ, err =  util.write_file(dump_params.path, data)
    if not succ then
        log.error("write dump into file got error: ", err)
    end
end


local function show_dump_file()
    if not dump_params then
        return 503, "dump params is nil"
    end

    local data, err = util.read_file(dump_params.path)
    if not data then
        return 503, err
    end

    return 200, data
end


function _M.connect(premature, consul_server)
    if premature then
        return
    end

    local consul_client = resty_consul:new({
        host = consul_server.host,
        port = consul_server.port,
        connect_timeout = consul_server.connect_timeout,
        read_timeout = consul_server.read_timeout,
        default_args = consul_server.default_args,
    })

    log.info("consul_server: ", json_delay_encode(consul_server, true))
    local result, err = consul_client:get(consul_server.consul_key)
    local error_info = (err ~= nil and err)
            or ((result ~= nil and result.status ~= 200)
            and result.status)
    if error_info then
        log.error("connect consul: ", consul_server.server_name_key,
            " by key: ", consul_server.consul_key,
            ", got result: ", json_delay_encode(result, true),
            ", with error: ", error_info)

        goto ERR
    end

    log.info("connect consul: ", consul_server.server_name_key,
        ", result status: ", result.status,
        ", result.headers.index: ", result.headers['X-Consul-Index'],
        ", result body: ", json_delay_encode(result.body))

    -- if current index different last index then update application
    if consul_server.index ~= result.headers['X-Consul-Index'] then
        consul_server.index = result.headers['X-Consul-Index']
        -- only long connect type use index
        if consul_server.keepalive then
            consul_server.default_args.index = result.headers['X-Consul-Index']
        end

        -- decode body, decode json, update application, error handling
        if result.body and #result.body ~= 0 then
            log.notice("server_name: ", consul_server.server_name_key,
                ", header: ", core.json.encode(result.headers, true),
                ", body: ", core.json.encode(result.body, true))

            update_application(consul_server.server_name_key, result.body)
            --update events
            local ok, err = events.post(events_list._source, events_list.updating, applications)
            if not ok then
                log.error("post_event failure with ", events_list._source,
                    ", update application error: ", err)
            end

            if dump_params then
                ngx_timer_at(0, write_dump_srvs)
            end
        end
    end

    :: ERR ::
    local keepalive = consul_server.keepalive
    if keepalive then
        local ok, err = ngx_timer_at(0, _M.connect, consul_server)
        if not ok then
            log.error("create ngx_timer_at got error: ", err)
            return
        end
    end
end


local function format_consul_params(consul_conf)
    local consul_server_list = core.table.new(0, #consul_conf.servers)
    local args

    if consul_conf.keepalive == false then
        args = {
            recurse = true,
        }
    elseif consul_conf.keepalive then
        args = {
            recurse = true,
            wait = consul_conf.timeout.wait, --blocked wait!=0; unblocked by wait=0
            index = 0,
        }
    end

    for _, v in pairs(consul_conf.servers) do
        local scheme, host, port, path = unpack(http.parse_uri(nil, v))
        if scheme ~= "http" then
            return nil, "only support consul http schema address, eg: http://address:port"
        elseif path ~= "/" or core.string.has_suffix(v, '/') then
            return nil, "invalid consul server address, the valid format: http://address:port"
        end

        core.table.insert(consul_server_list, {
            host = host,
            port = port,
            connect_timeout = consul_conf.timeout.connect,
            read_timeout = consul_conf.timeout.read,
            consul_key = "/kv/" .. consul_conf.prefix,
            server_name_key = v .. "/v1/kv/",
            weight = consul_conf.weight,
            keepalive = consul_conf.keepalive,
            default_args = args,
            index = 0,
            fetch_interval = consul_conf.fetch_interval -- fetch interval to next connect consul
        })
    end

    return consul_server_list
end


function _M.init_worker()
    local consul_conf = local_conf.discovery.consul_kv
    if not consul_conf
        or not consul_conf.servers
        or #consul_conf.servers == 0 then
        error("do not set consul_kv correctly !")
        return
    end

    local ok, err = core.schema.check(schema, consul_conf)
    if not ok then
        error("invalid consul_kv configuration: " .. err)
        return
    end

    if consul_conf.dump then
      local dump = consul_conf.dump
      dump_params = dump

      if dump.load_on_init then
          read_dump_srvs()
      end
    end

    events = require("resty.worker.events")
    events_list = events.event_list(
        "discovery_consul_update_application",
        "updating"
    )

    if 0 ~= ngx.worker.id() then
        events.register(discovery_consul_callback, events_list._source, events_list.updating)
        return
    end

    log.notice("consul_conf: ", core.json.encode(consul_conf))
    default_weight = consul_conf.weight
    -- set default service, used when the server node cannot be found
    if consul_conf.default_service then
        default_service = consul_conf.default_service
        default_service.weight = default_weight
    end
    default_prefix_rule = "(" .. consul_conf.prefix .. "/.*/)([a-zA-Z0-9.]+):([0-9]+)"
    log.info("default params, default_weight: ", default_weight,
            ", default_prefix_rule: ", default_prefix_rule)
    if consul_conf.skip_keys then
        skip_keys_map = core.table.new(0, #consul_conf.skip_keys)
        for _, v in ipairs(consul_conf.skip_keys) do
            skip_keys_map[v] = true
        end
    end

    local consul_servers_list, err = format_consul_params(consul_conf)
    if err then
        error(err)
        return
    end
    log.info("consul_server_list: ", core.json.encode(consul_servers_list))

    consul_apps = core.table.new(0, 1)
    -- success or failure
    for _, server in ipairs(consul_servers_list) do
        local ok, err = ngx_timer_at(0, _M.connect, server)
        if not ok then
            error("create consul_kv got error: " .. err)
            return
        end

        if server.keepalive == false then
            ngx_timer_every(server.fetch_interval, _M.connect, server)
        end
    end
end


function _M.dump_data()
    return {config = local_conf.discovery.consul_kv, services = applications}
end


function _M.control_api()
    return {
        {
            methods = {"GET"},
            uris = {"/show_dump_file"},
            handler = show_dump_file,
        }
    }
end


return _M
