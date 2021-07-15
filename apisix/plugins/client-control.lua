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
local ok, apisix_ngx_client = pcall(require, "resty.apisix.client")
local tonumber = tonumber


local schema = {
    type = "object",
    properties = {
        max_body_size = {
            type = "integer",
            minimum = 0,
        },
    },
}


local plugin_name = "client-control"


local _M = {
    version = 0.1,
    priority = 22000,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.rewrite(conf, ctx)
    if not ok then
        core.log.error("need to build APISIX-OpenResty to support client restriction")
        return 503
    end

    if conf.max_body_size then
        local len = tonumber(core.request.header(ctx, "Content-Length"))
        if len then
            -- if length is given in the header, check it immediately
            if conf.max_body_size ~= 0 and len > conf.max_body_size then
                return 413
            end
        end

        -- then check it when reading the body
        local ok, err = apisix_ngx_client.set_client_max_body_size(conf.max_body_size)
        if not ok then
            core.log.error("failed to set client max body size: ", err)
            return 503
        end
    end
end


return _M
