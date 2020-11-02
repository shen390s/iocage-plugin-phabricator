#!/bin/sh

# Enable the service
sysrc -f /etc/rc.conf nginx_enable="YES"
sysrc -f /etc/rc.conf mysql_enable="YES"
sysrc -f /etc/rc.conf php_fpm_enable="YES"
sysrc -f /etc/rc.conf phd_enable="YES"

# Install fresh phabricator.conf if user hasn't upgraded
CPCONFIG=0
if [ -e "/usr/local/etc/nginx/conf.d/phabricator.conf" ] ; then
  # Confirm the config doesn't have user-changes. Update if not
  if [ "$(md5 -q /usr/local/etc/nginx/conf.d/phabricator.conf)" = "$(cat /usr/local/etc/nginx/conf.d/phabricator.conf.checksum)" ] ; then
	  CPCONFIG=1
  fi
else
  CPCONFIG=1
fi

# Copy over the nginx config template
if [ "$CPCONFIG" = "1" ] ; then
  cp /usr/local/etc/nginx/conf.d/phabricator.conf.template /usr/local/etc/nginx/conf.d/phabricator.conf
  md5 -q /usr/local/etc/nginx/conf.d/phabricator.conf > /usr/local/etc/nginx/conf.d/phabricator.conf.checksum
fi

cp /usr/local/etc/php.ini-production /usr/local/etc/php.ini
# Modify opcache settings in php.ini according to Phabricator documentation (remove comment and set recommended value)
# https://docs.phabricator.com/server/15/admin_manual/configuration_server/server_tuning.html#enable-php-opcache
sed -i '' 's/.*opcache.enable=.*/opcache.enable=1/' /usr/local/etc/php.ini
sed -i '' 's/.*opcache.enable_cli=.*/opcache.enable_cli=1/' /usr/local/etc/php.ini
sed -i '' 's/.*opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=8/' /usr/local/etc/php.ini
sed -i '' 's/.*opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' /usr/local/etc/php.ini
sed -i '' 's/.*opcache.memory_consumption=.*/opcache.memory_consumption=128/' /usr/local/etc/php.ini
sed -i '' 's/.*opcache.save_comments=.*/opcache.save_comments=1/' /usr/local/etc/php.ini
sed -i '' 's/.*opcache.revalidate_freq=.*/opcache.revalidate_freq=1/' /usr/local/etc/php.ini
# recommended value of 512MB for php memory limit (avoid warning when running occ)
sed -i '' 's/.*memory_limit.*/memory_limit=512M/' /usr/local/etc/php.ini
# recommended value of 10 (instead of 5) to avoid timeout
sed -i '' 's/.*pm.max_children.*/pm.max_children=10/' /usr/local/etc/php-fpm.d/phabricator.conf
# Phabricator wants PATH environment variable set. 
echo "env[PATH] = $PATH" >> /usr/local/etc/php-fpm.d/phabricator.conf

# Start the service
service nginx start 2>/dev/null
service php-fpm start 2>/dev/null
service mysql-server start 2>/dev/null

#https://docs.phabricator.com/server/13/admin_manual/installation/installation_wizard.html do not use the same name for user and db
USER="dbadmin"
DB="phabricator"
NCUSER="ncadmin"

# Save the config values
echo "$DB" > /root/dbname
echo "$USER" > /root/dbuser
echo "$NCUSER" > /root/ncuser
export LC_ALL=C
cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1 > /root/dbpassword
cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1 > /root/ncpassword
PASS=`cat /root/dbpassword`
NCPASS=`cat /root/ncpassword`

if [ -e "/root/.mysql_secret" ] ; then
   # Mysql > 57 sets a default PW on root
   TMPPW=$(cat /root/.mysql_secret | grep -v "^#")
   echo "SQL Temp Password: $TMPPW"

# Configure mysql
mysql -u root -p"${TMPPW}" --connect-expired-password <<-EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${PASS}';
CREATE USER '${USER}'@'localhost' IDENTIFIED BY '${PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON ${DB}.* TO '${USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Make the default log directory
mkdir /var/log/zm
chown www:www /var/log/zm

else
   # Mysql <= 56 does not

# Configure mysql
mysql -u root <<-EOF
UPDATE mysql.user SET Password=PASSWORD('${PASS}') WHERE User='root';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';

CREATE USER '${USER}'@'localhost' IDENTIFIED BY '${PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON ${DB}.* TO '${USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
fi

# If on NAT, we need to use the HOST address as the IP
if [ -e "/etc/iocage-env" ] ; then
	IOCAGE_PLUGIN_IP=$(cat /etc/iocage-env | grep HOST_ADDRESS= | cut -d '=' -f 2)
	echo "Using NAT Address: $IOCAGE_PLUGIN_IP"
fi

cp /usr/local/lib/php/phabricator/resources/sshd/phabricator-sudoers.sample /usr/local/etc/sudoer.d
cp /usr/local/lib/php/phabricator/conf/local/local.json.sample /usr/local/lib/php/phabricator/conf/local/local.json


cat /etc/ssh/sshd_config <<EOF
Match User git
 AllowUsers git
 AuthorizedKeysCommand /usr/local/lib/php/phabricator/resources/sshd/phabricator-ssh-hook.sh
 AuthorizedKeysCommandUser git
 AuthorizedKeysFile none
 AuthenticationMethods publickey
 PermitRootLogin no
 PasswordAuthentication no
 PermitTTY no
 AllowAgentForwarding no
 AllowTcpForwarding no
 GatewayPorts no
 PermitOpen none
 PermitTunnel no
 X11Forwarding no
EOF

service sshd reload

cd /usr/local/lib/php/phabricator && ./bin/config set mysql.host "localhost"
cd /usr/local/lib/php/phabricator && ./bin/config set mysql.user "$USER"
cd /usr/local/lib/php/phabricator && ./bin/config set mysql.pass "$PASS"

cd /usr/local/lib/php/phabricator && ./bin/storage upgrade 

#restart the services to make sure we have pick up the new permission
service php-fpm restart 2>/dev/null
#nginx restarts to fast while php is not fully started yet
sleep 5
service nginx restart 2>/dev/null

service phd start 2>/dev/null

echo "Database Name: $DB" > /root/PLUGIN_INFO
echo "Database User: $USER" >> /root/PLUGIN_INFO
echo "Database Password: $PASS" >> /root/PLUGIN_INFO

echo "Phabricator Admin User: $NCUSER" >> /root/PLUGIN_INFO
echo "Phabricator Admin Password: $NCPASS" >> /root/PLUGIN_INFO
