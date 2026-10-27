# Xiao Huang 站点 HTTPS 配置（Apache，由 xiaohuang site ssl 生成）
<VirtualHost *:443>
    ServerName @DOMAIN@
    DocumentRoot "@ROOT@"

    SSLEngine on
    SSLCertificateFile    "@SSL_CERT@"
    SSLCertificateKeyFile "@SSL_KEY@"
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite HIGH:!aNULL:!MD5

    <Directory "@ROOT@">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
        DirectoryIndex index.php index.html index.htm
    </Directory>

    <IfModule proxy_fcgi_module>
        <FilesMatch "\.php$">
            SetHandler "proxy:fcgi://127.0.0.1:@PHP_FPM_PORT@"
        </FilesMatch>
    </IfModule>

    ErrorLog  "@LOG_DIR@/site-@DOMAIN@-ssl-apache-error.log"
    CustomLog "@LOG_DIR@/site-@DOMAIN@-ssl-apache-access.log" combined
</VirtualHost>
