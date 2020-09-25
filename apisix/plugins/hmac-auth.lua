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
local ngx        = ngx
local type       = type
local select     = select
local abs        = math.abs
local ngx_time   = ngx.time
local ngx_re     = require("ngx.re")
local ngx_req    = ngx.req
local pairs      = pairs
local ipairs     = ipairs
local hmac_sha1  = ngx.hmac_sha1
local escape_uri = ngx.escape_uri
local core       = require("apisix.core")
local hmac       = require("resty.hmac")
local consumer   = require("apisix.consumer")
local ngx_decode_base64 = ngx.decode_base64

local SIGNATURE_KEY = "X-HMAC-SIGNATURE"
local ALGORITHM_KEY = "X-HMAC-ALGORITHM"
local HTTP_DATE_KEY = "Date"
local ACCESS_KEY    = "X-HMAC-ACCESS-KEY"
local SIGNED_HEADERS_KEY = "X-HMAC-SIGNED-HEADERS"
local plugin_name   = "hmac-auth"

local schema = {
    type = "object",
    oneOf = {
        {
            title = "work with route or service object",
            properties = {},
            additionalProperties = false,
        },
        {
            title = "work with consumer object",
            properties = {
                access_key = {type = "string", minLength = 1, maxLength = 256},
                secret_key = {type = "string", minLength = 1, maxLength = 256},
                algorithm = {
                    type = "string",
                    enum = {"hmac-sha1", "hmac-sha256", "hmac-sha512"},
                    default = "hmac-sha256"
                },
                clock_skew = {
                    type = "integer",
                    default = 0
                },
                signed_headers = {
                    type = "array",
                    items = {
                        type = "string",
                        minLength = 1,
                        maxLength = 50,
                    }
                },
            },
            required = {"access_key", "secret_key"},
            additionalProperties = false,
        },
    }
}

local _M = {
    version = 0.1,
    priority = 2530,
    type = 'auth',
    name = plugin_name,
    schema = schema,
}

local hmac_funcs = {
    ["hmac-sha1"] = function(secret_key, message)
        return hmac_sha1(secret_key, message)
    end,
    ["hmac-sha256"] = function(secret_key, message)
        return hmac:new(secret_key, hmac.ALGOS.SHA256):final(message)
    end,
    ["hmac-sha512"] = function(secret_key, message)
        return hmac:new(secret_key, hmac.ALGOS.SHA512):final(message)
    end,
}


local function try_attr(t, ...)
    local tbl = t
    local count = select('#', ...)
    for i = 1, count do
        local attr = select(i, ...)
        tbl = tbl[attr]
        if type(tbl) ~= "table" then
            return false
        end
    end

    return true
end


local function array_to_map(arr)
    local map = core.table.new(0, #arr)
    for _, v in ipairs(arr) do
      map[v] = true
    end

    return map
end


local create_consumer_cache
do
    local consumer_ids = {}

    function create_consumer_cache(consumers)
        core.table.clear(consumer_ids)

        for _, consumer in ipairs(consumers.nodes) do
            core.log.info("consumer node: ", core.json.delay_encode(consumer))
            consumer_ids[consumer.auth_conf.access_key] = consumer
        end

        return consumer_ids
    end

end -- do


function _M.check_schema(conf)
    core.log.info("input conf: ", core.json.delay_encode(conf))

    return core.schema.check(schema, conf)
end


local function get_consumer(access_key)
    if not access_key then
        return nil, {message = "missing access key"}
    end

    local consumer_conf = consumer.plugin(plugin_name)
    if not consumer_conf then
        return nil, {message = "Missing related consumer"}
    end

    local consumers = core.lrucache.plugin(plugin_name, "consumers_key",
            consumer_conf.conf_version,
            create_consumer_cache, consumer_conf)

    local consumer = consumers[access_key]
    if not consumer then
        return nil, {message = "Invalid access key"}
    end
    core.log.info("consumer: ", core.json.delay_encode(consumer))

    return consumer
end


local function generate_signature(ctx, secret_key, params)
    local canonical_uri = ctx.var.uri
    local canonical_query_string = ""
    local request_method = ngx_req.get_method()
    local args = ngx_req.get_uri_args()

    if canonical_uri == "" then
        canonical_uri = "/"
    end

    if type(args) == "table" then
        local keys = {}
        local query_tab = {}

        for k, v in pairs(args) do
            core.table.insert(keys, k)
        end
        core.table.sort(keys)

        for _, key in pairs(keys) do
            local param = args[key]
            if type(param) == "table" then
                for _, val in pairs(param) do
                    core.table.insert(query_tab, escape_uri(key) .. "=" .. escape_uri(val))
                end
            else
                core.table.insert(query_tab, escape_uri(key) .. "=" .. escape_uri(param))
            end
        end
        canonical_query_string = core.table.concat(query_tab, "&")
    end

    local canonical_headers = {}

    core.log.info("all headers: ",
                  core.json.delay_encode(core.request.headers(ctx), true))

    if params.signed_headers then
        for _, h in ipairs(params.signed_headers) do
            local canonical_header = core.request.header(ctx, h) or ""
            core.table.insert(canonical_headers, canonical_header)
            core.log.info("canonical_header name:", core.json.delay_encode(h))
            core.log.info("canonical_header value: ",
                          core.json.delay_encode(canonical_header))
        end
    end

    local signing_string = request_method .. canonical_uri
                            .. canonical_query_string
                            .. params.access_key .. params.date
                            .. core.table.concat(canonical_headers, "")

    core.log.info("signing_string:", signing_string,
                  " params.signed_headers:",
                  core.json.delay_encode(params.signed_headers))

    return hmac_funcs[params.algorithm](secret_key, signing_string)
end


local function validate(ctx, params)
    if not params.access_key or not params.signature then
        return nil, {message = "access key or signature missing"}
    end

    local consumer, err = get_consumer(params.access_key)
    if err then
        return nil, err
    end

    local conf = consumer.auth_conf
    if conf.algorithm ~= params.algorithm then
        return nil, {message = "algorithm " .. params.algorithm .. " not supported"}
    end

    core.log.info("clock_skew: ", conf.clock_skew)
    if conf.clock_skew and conf.clock_skew > 0 then
        local time = ngx.parse_http_time(params.date)
        core.log.info("params.date: ", params.date, " time: ", time)
        if not time then
            return nil, {message = "Invalid GMT format time"}
        end

        local diff = abs(ngx_time() - time)
        core.log.info("gmt diff: ", diff)
        if diff > conf.clock_skew then
            return nil, {message = "Clock skew exceeded"}
        end
    end

    -- validate headers
    if conf.signed_headers and #conf.signed_headers >= 1 then
        local headers_map = array_to_map(conf.signed_headers)
        if params.signed_headers then
            for _, header in ipairs(params.signed_headers) do
                if not headers_map[header] then
                    return nil, {message = "Invalid signed header " .. header}
                end
            end
        end
    end

    local secret_key          = conf and conf.secret_key
    local request_signature   = ngx_decode_base64(params.signature)
    local generated_signature = generate_signature(ctx, secret_key, params)

    core.log.info("request_signature: ", request_signature,
                  " generated_signature: ", generated_signature)

    if request_signature ~= generated_signature then
        return nil, {message = "Invalid signature"}
    end

    return consumer
end

local function get_params(ctx)
    local params = {}
    local local_conf = core.config.local_conf()
    local access_key = ACCESS_KEY
    local signature_key = SIGNATURE_KEY
    local algorithm_key = ALGORITHM_KEY
    local http_date_key = HTTP_DATE_KEY
    local signed_headers_key = SIGNED_HEADERS_KEY

    if try_attr(local_conf, "plugin_attr", "hmac-auth") then
        local attr = local_conf.plugin_attr["hmac-auth"]
        access_key = attr.access_key or access_key
        signature_key = attr.signature_key or signature_key
        algorithm_key = attr.algorithm_key or algorithm_key
        http_date_key = attr.http_date_key or http_date_key
        signed_headers_key = attr.signed_headers_key or signed_headers_key
    end

    local app_key = core.request.header(ctx, access_key)
    local signature = core.request.header(ctx, signature_key)
    local algorithm = core.request.header(ctx, algorithm_key)
    local date = core.request.header(ctx, http_date_key)
    local signed_headers = core.request.header(ctx, signed_headers_key)
    core.log.info("signature_key: ", signature_key)

    -- get params from header `Authorization`
    if not app_key then
        local auth_string = core.request.header(ctx, "Authorization")
        if not auth_string then
            return params
        end

        local auth_data = ngx_re.split(auth_string, "#")
        core.log.info("auth_string: ", auth_string, " #auth_data: ",
                      #auth_data, " auth_data: ",
                      core.json.delay_encode(auth_data))

        if #auth_data == 6 and auth_data[1] == "hmac-auth-v1" then
            app_key = auth_data[2]
            signature = auth_data[3]
            algorithm = auth_data[4]
            date = auth_data[5]
            signed_headers = auth_data[6]
        end
    end

    params.access_key = app_key
    params.algorithm  = algorithm
    params.signature  = signature
    params.date  = date or ""
    params.signed_headers = signed_headers and ngx_re.split(signed_headers, ";")

    core.log.info("params: ", core.json.delay_encode(params))

    return params
end


function _M.rewrite(conf, ctx)
    local params = get_params(ctx)
    local validated_consumer, err = validate(ctx, params)
    if err then
        return 401, err
    end

    if not validated_consumer then
        return 401, {message = "Invalid signature"}
    end

    local consumer_conf = consumer.plugin(plugin_name)
    ctx.consumer = validated_consumer
    ctx.consumer_id = validated_consumer.consumer_id
    ctx.consumer_ver = consumer_conf.conf_version
    core.log.info("hit hmac-auth rewrite")
end


return _M
