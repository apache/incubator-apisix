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
local ngx_time = ngx.time


local _M = {}


function _M.inject_timestamp(conf, prev_conf, patch_conf)
    if not conf.create_time then
        if prev_conf and prev_conf.node.value.create_time then
            conf.create_time = prev_conf.node.value.create_time
        end

        -- As we don't know existent data's create_time, we have to pretend
        -- they are created now.
        conf.create_time = ngx_time()
    end

    -- For PATCH request, the modification is passed as 'patch_conf'
    if not conf.update_time or (patch_conf and patch_conf.update_time == nil) then
        conf.update_time = ngx_time()
    end
end


return _M
