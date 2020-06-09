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
use t::APISIX 'no_plan';

log_level('debug');
no_root_location();

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

run_tests;

__DATA__

=== TEST 1: set ssl(sni: www.test.com)
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("conf/cert/apisix.crt")
        local ssl_key =  t.read_file("conf/cert/apisix.key")
        local data = {cert = ssl_cert, key = ssl_key, sni = "www.test.com"}

        local code, body = t.test('/apisix/admin/ssl/1',
            ngx.HTTP_PUT,
            core.json.encode(data),
            [[{
                "node": {
                    "value": {
                        "sni": "www.test.com"
                    },
                    "key": "/apisix/ssl/1"
                },
                "action": "set"
            }]]
            )

        ngx.status = code
        ngx.say(body)
    }
}
--- request
GET /t
--- response_body
passed
--- no_error_log
[error]



=== TEST 2: set route(id: 1)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1980": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed
--- no_error_log
[error]



=== TEST 3: client request
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;

location /t {
    content_by_lua_block {
        -- etcd sync
        ngx.sleep(0.2)

        do
            local sock = ngx.socket.tcp()

            sock:settimeout(2000)

            local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local sess, err = sock:sslhandshake(nil, "www.test.com", true)
            if not sess then
                ngx.say("failed to do SSL handshake: ", err)
                return
            end

            ngx.say("ssl handshake: ", type(sess))

            local req = "GET /hello HTTP/1.0\r\nHost: www.test.com\r\nConnection: close\r\n\r\n"
            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send http request: ", err)
                return
            end

            ngx.say("sent http request: ", bytes, " bytes.")

            while true do
                local line, err = sock:receive()
                if not line then
                    -- ngx.say("failed to receive response status line: ", err)
                    break
                end

                ngx.say("received: ", line)
            end

            local ok, err = sock:close()
            ngx.say("close: ", ok, " ", err)
        end  -- do
        -- collectgarbage()
    }
}
--- request
GET /t
--- response_body eval
qr{connected: 1
ssl handshake: userdata
sent http request: 62 bytes.
received: HTTP/1.1 200 OK
received: Content-Type: text/plain
received: Connection: close
received: Server: \w+
received: \nreceived: hello world
close: 1 nil}
--- error_log
lua ssl server name: "www.test.com"
--- no_error_log
[error]
[alert]



=== TEST 4: client request(no cert domain)
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;

location /t {
    content_by_lua_block {
        -- etcd sync
        ngx.sleep(0.2)

        do
            local sock = ngx.socket.tcp()

            sock:settimeout(2000)

            local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local sess, err = sock:sslhandshake(nil, "no-cert.com", true)
            if not sess then
                ngx.say("failed to do SSL handshake: ", err)
                return
            end
        end
    }
}
--- request
GET /t
--- response_body
connected: 1
failed to do SSL handshake: certificate host mismatch
--- error_log
not found any valid sni configuration



=== TEST 5: set ssl(sni: wildcard)
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("conf/cert/apisix.crt")
        local ssl_key =  t.read_file("conf/cert/apisix.key")
        local data = {cert = ssl_cert, key = ssl_key, sni = "*.test.com"}

        local code, body = t.test('/apisix/admin/ssl/1',
            ngx.HTTP_PUT,
            core.json.encode(data),
            [[{
                "node": {
                    "value": {
                        "sni": "*.test.com"
                    },
                    "key": "/apisix/ssl/1"
                },
                "action": "set"
            }]]
            )

        ngx.status = code
        ngx.say(body)
    }
}
--- request
GET /t
--- response_body
passed
--- no_error_log
[error]



=== TEST 6: client request
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;

location /t {
    content_by_lua_block {
        -- etcd sync
        ngx.sleep(0.2)

        do
            local sock = ngx.socket.tcp()

            sock:settimeout(2000)

            local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local sess, err = sock:sslhandshake(nil, "www.test.com", false)
            if not sess then
                ngx.say("failed to do SSL handshake: ", err)
                return
            end

            ngx.say("ssl handshake: ", type(sess))

            local req = "GET /hello HTTP/1.0\r\nHost: www.test.com\r\nConnection: close\r\n\r\n"
            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send http request: ", err)
                return
            end

            ngx.say("sent http request: ", bytes, " bytes.")

            while true do
                local line, err = sock:receive()
                if not line then
                    -- ngx.say("failed to receive response status line: ", err)
                    break
                end

                ngx.say("received: ", line)
            end

            local ok, err = sock:close()
            ngx.say("close: ", ok, " ", err)
        end  -- do
        -- collectgarbage()
    }
}
--- request
GET /t
--- response_body eval
qr{connected: 1
ssl handshake: userdata
sent http request: 62 bytes.
received: HTTP/1.1 200 OK
received: Content-Type: text/plain
received: Connection: close
received: Server: \w+
received: \nreceived: hello world
close: 1 nil}
--- error_log
lua ssl server name: "www.test.com"
--- no_error_log
[error]
[alert]



=== TEST 7: set ssl(sni: test.com)
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("conf/cert/apisix.crt")
        local ssl_key =  t.read_file("conf/cert/apisix.key")
        local data = {cert = ssl_cert, key = ssl_key, sni = "test.com"}

        local code, body = t.test('/apisix/admin/ssl/1',
            ngx.HTTP_PUT,
            core.json.encode(data),
            [[{
                "node": {
                    "value": {
                        "sni": "test.com"
                    },
                    "key": "/apisix/ssl/1"
                },
                "action": "set"
            }]]
            )

        ngx.status = code
        ngx.say(body)
    }
}
--- request
GET /t
--- response_body
passed
--- no_error_log
[error]



=== TEST 8: client request: test.com
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;

location /t {
    content_by_lua_block {
        -- etcd sync
        ngx.sleep(0.2)

        do
            local sock = ngx.socket.tcp()

            sock:settimeout(2000)

            local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local sess, err = sock:sslhandshake(nil, "test.com", false)
            if not sess then
                ngx.say("failed to do SSL handshake: ", err)
                return
            end

            ngx.say("ssl handshake: ", type(sess))

            local req = "GET /hello HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n"
            local bytes, err = sock:send(req)
            if not bytes then
                ngx.say("failed to send http request: ", err)
                return
            end

            ngx.say("sent http request: ", bytes, " bytes.")

            while true do
                local line, err = sock:receive()
                if not line then
                    -- ngx.say("failed to receive response status line: ", err)
                    break
                end

                ngx.say("received: ", line)
            end

            local ok, err = sock:close()
            ngx.say("close: ", ok, " ", err)
        end  -- do
        -- collectgarbage()
    }
}
--- request
GET /t
--- response_body eval
qr{connected: 1
ssl handshake: userdata
sent http request: 58 bytes.
received: HTTP/1.1 200 OK
received: Content-Type: text/plain
received: Connection: close
received: Server: \w+
received: \nreceived: hello world
close: 1 nil}
--- error_log
lua ssl server name: "test.com"
--- no_error_log
[error]
[alert]



=== TEST 9: set ssl(sni: *.test2.com)
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("conf/cert/test2.crt")
        local ssl_key =  t.read_file("conf/cert/test2.key")
        local data = {cert = ssl_cert, key = ssl_key, sni = "*.test2.com"}

        local code, body = t.test('/apisix/admin/ssl/1',
            ngx.HTTP_PUT,
            core.json.encode(data),
            [[{
                "node": {
                    "value": {
                        "sni": "*.test2.com"
                    },
                    "key": "/apisix/ssl/1"
                },
                "action": "set"
            }]]
            )

        ngx.status = code
        ngx.say(body)
    }
}
--- request
GET /t
--- response_body
passed
--- no_error_log
[error]



=== TEST 10: client request: www.test2.com
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;

location /t {
    content_by_lua_block {
        -- etcd sync
        ngx.sleep(0.2)

        do
            local sock = ngx.socket.tcp()

            sock:settimeout(2000)

            local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local sess, err = sock:sslhandshake(nil, "www.test2.com", true)
            if not sess then
                ngx.say("failed to do SSL handshake: ", err)
                return
            end

            ngx.say("ssl handshake: ", type(sess))
        end  -- do
        -- collectgarbage()
    }
}
--- request
GET /t
--- response_body
connected: 1
failed to do SSL handshake: 18: self signed certificate
--- error_log
lua ssl server name: "www.test2.com"
--- no_error_log
[error]
[alert]



=== TEST 11: client request: aa.bb.test2.com
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;

location /t {
    content_by_lua_block {
        -- etcd sync
        ngx.sleep(0.2)

        do
            local sock = ngx.socket.tcp()

            sock:settimeout(2000)

            local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local sess, err = sock:sslhandshake(nil, "aa.bb.test2.com", true)
            if not sess then
                ngx.say("failed to do SSL handshake: ", err)
                return
            end

            ngx.say("ssl handshake: ", type(sess))
        end  -- do
        -- collectgarbage()
    }
}
--- request
GET /t
--- response_body
connected: 1
failed to do SSL handshake: certificate host mismatch
--- error_log
lua ssl server name: "aa.bb.test2.com"
not found any valid sni configuration, matched sni: *.test2.com current sni: aa.bb.test2.com
--- no_error_log
[error]
[alert]



=== TEST 12: disable ssl(sni: *.test2.com)
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local data = {status = 0}

        local code, body = t.test('/apisix/admin/ssl/1',
            ngx.HTTP_PATCH,
            core.json.encode(data),
            [[{
                "node": {
                    "value": {
                        "status": 0
                    },
                    "key": "/apisix/ssl/1"
                },
                "action": "set"
            }]]
            )

        ngx.status = code
        ngx.say(body)
    }
}
--- request
GET /t
--- response_body
passed
--- no_error_log
[error]



=== TEST 13: client request: www.test2.com -- fail
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;

location /t {
    content_by_lua_block {
        -- etcd sync
        ngx.sleep(0.2)

        do
            local sock = ngx.socket.tcp()

            sock:settimeout(2000)

            local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local sess, err = sock:sslhandshake(nil, "www.test2.com", true)
            if not sess then
                ngx.say("failed to do SSL handshake: ", err)
                return
            end

            ngx.say("ssl handshake: ", type(sess))
        end  -- do
        -- collectgarbage()
    }
}
--- request
GET /t
--- response_body
connected: 1
failed to do SSL handshake: certificate host mismatch
--- error_log
lua ssl server name: "www.test2.com"
--- no_error_log
[error]
[alert]



=== TEST 14: set ssl(snis: {test2.com, *.test2.com})
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("conf/cert/test2.crt")
        local ssl_key =  t.read_file("conf/cert/test2.key")
        local data = {cert = ssl_cert, key = ssl_key, snis = {"test2.com", "*.test2.com"}}

        local code, body = t.test('/apisix/admin/ssl/1',
            ngx.HTTP_PUT,
            core.json.encode(data),
            [[{
                "node": {
                    "value": {
                        "snis": ["test2.com", "*.test2.com"]
                    },
                    "key": "/apisix/ssl/1"
                },
                "action": "set"
            }]]
            )

        ngx.status = code
        ngx.say(body)
    }
}
--- request
GET /t
--- response_body
passed
--- no_error_log
[error]



=== TEST 15: client request: test2.com
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;

location /t {
    content_by_lua_block {
        -- etcd sync
        ngx.sleep(0.2)

        do
            local sock = ngx.socket.tcp()

            sock:settimeout(2000)

            local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("connected: ", ok)

            local sess, err = sock:sslhandshake(nil, "test2.com", true)
            if not sess then
                ngx.say("failed to do SSL handshake: ", err)
                return
            end

            ngx.say("ssl handshake: ", type(sess))
        end  -- do
        -- collectgarbage()
    }
}
--- request
GET /t
--- response_body
connected: 1
failed to do SSL handshake: 18: self signed certificate
--- error_log
lua ssl server name: "test2.com"
--- no_error_log
[error]
[alert]
