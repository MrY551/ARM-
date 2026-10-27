# Xiao Huang 站点配置（由 xiaohuang site add / 安装器生成）
server {
    listen        @PORT@;
    server_name   @DOMAIN@;

    root          "@ROOT@";
    index         index.php index.html index.htm;

    access_log    @LOG_DIR@/site-@DOMAIN@-access.log  main;
    error_log     @LOG_DIR@/site-@DOMAIN@-error.log   warn;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    # PHP 交给 php-fpm（127.0.0.1:9000，与 Windows 版一致）
    location ~ \.php$ {
        try_files      $uri =404;
        fastcgi_pass   127.0.0.1:@PHP_FPM_PORT@;
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME  $document_root$fastcgi_script_name;
        fastcgi_param  PATH_INFO        $fastcgi_path_info;
        fastcgi_split_path_info ^((?U).+\.php)(/?.+)$;
        include        fastcgi_params;
    }

    location ~ /\.ht {
        deny  all;
    }

    location ~ /\.(git|svn|env) {
        deny  all;
    }
}
