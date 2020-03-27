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
local core     = require("apisix.core")
local log_util = require("apisix.utils.log-util")
local producer = require ("resty.kafka.producer")
local batch_processor = require("apisix.utils.batch-processor")
local pairs    = pairs
local type     = type
local table    = table
local plugin_name = "kafka-logger"
local ngx = ngx
local buffers = {}

local schema = {
    type = "object",
    properties = {
        broker_list = {
            type = "object"
        },
        kafka_topic = {type = "string"},
        async =  {type = "boolean", default = false},
        key = {type = "string"},
        timeout = {type = "integer", minimum = 1, default = 3},
        name = {type = "string", default = "kafka logger"},
        max_retry_count = {type = "integer", minimum = 0, default = 0},
        retry_delay = {type = "integer", minimum = 0, default = 1},
        buffer_duration = {type = "integer", minimum = 1, default = 60},
        inactive_timeout = {type = "integer", minimum = 1, default = 5},
        batch_max_size = {type = "integer", minimum = 1, default = 1000},
    },
    required = {"broker_list", "kafka_topic", "key"}
}

local _M = {
    version = 0.1,
    priority = 403,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function send_kafka_data(conf, log_message)
    if core.table.nkeys(conf.broker_list) == 0 then
        core.log.error("failed to identify the broker specified")
    end

    local broker_list = {}
    local broker_config = {}

    for host, port  in pairs(conf.broker_list) do
        if type(host) == 'string'
            and type(port) == 'number' then

            local broker = {
                host = host, port = port
            }
            table.insert(broker_list,broker)
        end
    end

    broker_config["request_timeout"] = conf.timeout * 1000
    broker_config["max_retry"] = conf.max_retry_count

    --Async producers will queue logs and push them when the buffer exceeds.
    if conf.async then
        broker_config["producer_type"] = "async"
    end

    local prod, err = producer:new(broker_list,broker_config)
    if err then
        return nil, "failed to identify the broker specified: " .. err
    end

    local ok, err = prod:send(conf.kafka_topic, conf.key, log_message)
    if not ok then
        return nil, "failed to send data to Kafka topic" .. err
    end
end


function _M.log(conf)
    local entry = log_util.get_full_log(ngx)

    if not entry.route_id then
        core.log.error("failed to obtain the route id for udp logger")
        return
    end

    local log_buffer = buffers[entry.route_id]

    -- If a logger is not present for the route, create one
    if not log_buffer then
        -- Generate a function to be executed by the batch processor
        local func = function(entries, batch_max_size)
            local data
            if batch_max_size == 1 then
                data = core.json.encode(entries[1]) -- encode as single {}
            else
                data = core.json.encode(entries) -- encode as array [{}]
            end
            return send_kafka_data(conf, data)
        end

        local config = {
            name = conf.name,
            retry_delay = conf.retry_delay,
            batch_max_size = conf.batch_max_size,
            max_retry_count = conf.max_retry_count,
            buffer_duration = conf.buffer_duration,
            inactive_timeout = conf.inactive_timeout,
        }

        local err
        log_buffer, err = batch_processor:new(func, config)

        if not log_buffer then
            core.log.err("error when creating the batch processor: " .. err)
            return
        end

        buffers[entry.route_id] = log_buffer
    end

    log_buffer:push(entry)
end

return _M
