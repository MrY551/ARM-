# Xiao Huang 站点 HTTPS 配置（由 xiaohuang site ssl 生成）
server {
    listen        443 ssl http2;
    server_name   @DOMAIN@;

    root          "@ROOT@";
    index         index.php index.html index.htm;

    ssl_certificate      "@SSL_CERT@";
    ssl_certificate_key  "@SSL_KEY@";
    ssl_protocols        TLSv1.2 TLSv1.3;
    ssl_ciphers          HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache    shared:SSL:10m;
    ssl_session_timeout  10m;

    access_log    @LOG_DIR@/site-@DOMAIN@-ssl-access.log  main;
    error_log     @LOG_DIR@/site-@DOMAIN@-ssl-error.log   warn;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        try_files      $uri =404;
        fastcgi_pass   127.0.0.1:@PHP_FPM_PORT@;
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME  $document_root$fastcgi_script_name;
        fastcgi_param  PATH_INFO        $fastcgi_path_info;
        fastcgi_split_path_info ^((?U).+\.php)(/?.+)$;
        include        fastcgi_params;
    }

    location ~ /\.(ht|git|svn|env) {
        deny  all;
    }
}
