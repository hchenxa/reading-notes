# TLS labs nginx 主配置模板
# 由 lib.sh 渲染:#@FRAG:xxx@ 行展开为 fragments/xxx.conf,@TOKEN@ 逐个替换
events { worker_connections 1024; }

http {
    log_format main '$remote_addr [$time_local] "$request" $status '
                    'ssl_verify=$ssl_client_verify cn="$ssl_client_s_dn"';
    access_log /dev/stdout main;
    error_log  /dev/stderr warn;

    # ── 8080 容器内 http 后端:回显它"实际收到"的头(模拟应用)
    server {
        listen       8080;
        default_type text/plain;
        location / {
            return 200 'backend: xfp=[$http_x_forwarded_proto] xff=[$http_x_forwarded_for] client_cn=[$http_x_client_cn] client_verify=[$http_x_client_verify]\n';
        }
    }

#@FRAG:AUTHZ_MAP@
#@FRAG:EXTRA_443_SERVER@

    # ── 443 termination 前端(www.example.com)
    server {
        listen       443 ssl;
        http2        on;
        server_name  www.example.com;

        ssl_certificate     @WWW_CERT@;
        ssl_certificate_key @WWW_KEY@;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_ticket_key @TICKET_KEY@;
#@FRAG:CIPHERS@
        location / {
#@FRAG:FRONT_LOC@
        }
    }

    # ── 9443 容器内 TLS 后端(api.example.com)——bridging / passthrough 的上游
    server {
        listen       9443 ssl;
        server_name  api.example.com;

        ssl_certificate     @BACKEND_CERT@;
        ssl_certificate_key @BACKEND_KEY@;
        ssl_protocols       TLSv1.2 TLSv1.3;
        location / {
            proxy_pass http://127.0.0.1:8080;
        }
    }

    # ── 8443 mTLS 前端(example.com)
    server {
        listen       8443 ssl;
        server_name  example.com;

        ssl_certificate     @WWW_CERT@;
        ssl_certificate_key @WWW_KEY@;
        ssl_client_certificate /etc/nginx/certs/ca/lab-ca.crt;
        ssl_verify_client  on;
        ssl_verify_depth   2;

        location / {
            proxy_set_header X-Client-CN     $ssl_client_s_dn;
            proxy_set_header X-Client-Verify $ssl_client_verify;
            proxy_pass http://127.0.0.1:8080;
#@FRAG:AUTHZ_DENY@
        }
    }
}

stream {
    log_format stream_main '$remote_addr [$time_local] sni=$ssl_preread_server_name -> $backend';
    access_log /dev/stdout stream_main;

    map $ssl_preread_server_name $backend {
        api.example.com 127.0.0.1:9443;
#@FRAG:PASS_DEFAULT@
    }

    server {
        listen      4443;
        proxy_pass  $backend;
        ssl_preread on;
    }
}
