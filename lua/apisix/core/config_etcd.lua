-- Copyright (C) Yuansheng Wang

local log = require("apisix.core.log")
local etcd = require("resty.etcd")
local config = require("apisix.core.config")
local new_tab = require("table.new")
local json_encode = require("cjson.safe").encode
local insert_tab = table.insert


local _M = {version = 0.1}
local mt = { __index = _M }


local function readdir(etcd_cli, key)
    if not etcd_cli then
        return nil, "not inited"
    end

    local data, err = etcd_cli:readdir(key, true)
    if not data then
        -- log.error("failed to get key from etcd: ", err)
        return nil, err
    end

    local body = data.body or {}

    if body.message then
        return nil, body.message
    end

    return body.node
end

local function waitdir(etcd_cli, key, modified_index)
    if not etcd_cli then
        return nil, "not inited"
    end

    local data, err = etcd_cli:waitdir(key, modified_index)
    if not data then
        -- log.error("failed to get key from etcd: ", err)
        return nil, err
    end

    local body = data.body or {}

    if body.message then
        return nil, body.message
    end

    return body.node
end


function _M.fetch(self)
    if self.values == nil then
        local node, err = readdir(self.etcd_cli, self.key)
        if not node then
            return nil, err
        end

        if not node.dir then
            return nil, self.key .. " is not a dir"
        end

        self.values = new_tab(#node.nodes, 0)
        self.values_hash = new_tab(0, #node.nodes)

        for _, item in ipairs(node.nodes) do
            insert_tab(self.values, item.value)
            self.values_hash[item.key] = #self.values

            if not self.prev_index or item.modifiedIndex > self.prev_index then
                self.prev_index = item.modifiedIndex
            end
        end

        return self.values
    end

    local item, err = waitdir(self.etcd_cli, self.key, self.prev_index + 1)
    if not item then
        return nil, err
    end

    if item.dir then
        log.error("todo: support for parsing `dir` response structures. ",
                  json_encode(item))
        return self.values
    end
    -- log.warn("waitdir: ", require("cjson").encode(item))

    if not self.prev_index or item.modifiedIndex > self.prev_index then
        self.prev_index = item.modifiedIndex
    end

    local pre_index = self.values_hash[item.key]
    if pre_index then
        if item.value then
            self.values[pre_index] = item.value

        else
            self.values[pre_index] = false
        end

        return self.values
    end

    if item.value then
        insert_tab(self.values, item.value)
        self.values_hash[item.key] = #self.values
    end

    return self.values
end


function _M.new(key)
    if not key then
        return nil, "missing `key` argument"
    end

    local local_conf, err = config.local_conf()
    if not local_conf then
        return nil, err
    end

    local etcd_cli
    etcd_cli, err = etcd.new(local_conf.etcd)
    if not etcd_cli then
        return nil, err
    end

    return setmetatable({
        etcd_cli = etcd_cli,
        values = nil,
        routes_hash = nil,
        prev_index = nil,
        key = key,
    }, mt)
end


return _M
