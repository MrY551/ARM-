# Xiao Huang 站点配置（Apache，由 xiaohuang site add / 安装器生成）
<VirtualHost *:@PORT@>
    ServerName @DOMAIN@
    ServerAlias www.@DOMAIN@
    DocumentRoot "@ROOT@"

    <Directory "@ROOT@">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
        DirectoryIndex index.php index.html index.htm
    </Directory>

    ErrorLog  "@LOG_DIR@/site-@DOMAIN@-apache-error.log"
    CustomLog "@LOG_DIR@/site-@DOMAIN@-apache-access.log" combined

    <IfModule proxy_fcgi_module>
        <FilesMatch "\.php$">
            SetHandler "proxy:fcgi://127.0.0.1:@PHP_FPM_PORT@"
        </FilesMatch>
    </IfModule>
</VirtualHost>
