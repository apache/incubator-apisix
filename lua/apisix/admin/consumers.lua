local core = require("apisix.core")

local _M = {
    version = 0.1,
}


local function check_conf(uri_segs, conf)
    -- core.log.error(core.json.encode(conf))
    if not conf then
        return nil, {error_msg = "missing configurations"}
    end

    local consumer_name = conf.username or uri_segs[5]
    if not consumer_name then
        return nil, {error_msg = "missing consumer name"}
    end

    core.log.info("schema: ", core.json.delay_encode(core.schema.consumer))
    core.log.info("conf  : ", core.json.delay_encode(conf))
    local ok, err = core.schema.check(core.schema.consumer, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end

    return consumer_name
end


function _M.put(uri_segs, conf)
    local consumer_name, err = check_conf(uri_segs, conf)
    if not consumer_name then
        return 400, err
    end

    local key = "/consumers/" .. consumer_name
    core.log.info("key: ", key)
    local res, err = core.etcd.set(key, conf)
    if not res then
        core.log.error("failed to put consumer[", key, "]: ", err)
        return 500, {error_msg = err}
    end

    return res.status, res.body
end


function _M.get(uri_segs)
    local consumer_name = uri_segs[5]
    local key = "/consumers"
    if consumer_name then
        key = key .. "/" .. consumer_name
    end

    local res, err = core.etcd.get(key)
    if not res then
        core.log.error("failed to get consumer[", key, "]: ", err)
        return 500, {error_msg = err}
    end

    return res.status, res.body
end


function _M.post(uri_segs, conf)
    return 400, {error_msg = "not support `POST` method for consumer"}
end


function _M.delete(uri_segs)
    local consumer_name = uri_segs[5]
    if not consumer_name then
        return 400, {error_msg = "missing consumer name"}
    end

    local key = "/consumers/" .. consumer_name
    local res, err = core.etcd.delete(key)
    if not res then
        core.log.error("failed to delete consumer[", key, "]: ", err)
        return 500, {error_msg = err}
    end

    return res.status, res.body
end


return _M
