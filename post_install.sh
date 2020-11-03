#!/bin/sh

# Enable the service
sysrc -f /etc/rc.conf nginx_enable="YES"
sysrc -f /etc/rc.conf mysql_enable="YES"
sysrc -f /etc/rc.conf php_fpm_enable="YES"
sysrc -f /etc/rc.conf phd_enable="YES"
sysrc -f /etc/rc.conf sshd_enable="YES"

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

# Start the service
service nginx start 2>/dev/null
service php-fpm start 2>/dev/null
service mysql-server start 2>/dev/null

#https://docs.phabricator.com/server/13/admin_manual/installation/installation_wizard.html do not use the same name for user and db
USER="dbadmin"
DB="phabricator"

# Save the config values
echo "$DB" > /root/dbname
echo "$USER" > /root/dbuser
export LC_ALL=C
cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1 > /root/dbpassword
PASS=`cat /root/dbpassword`

if [ -e "/root/.mysql_secret" ] ; then
   # Mysql > 57 sets a default PW on root
   # TMPPW=$(cat /root/.mysql_secret | grep -v "^#")
   TMPPW=$(cat /root/.mysql_secret | sed '1d')
   echo "SQL Temp Password: $TMPPW"

# Configure mysql
mysql -u root -p"${TMPPW}" --connect-expired-password <<-EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${PASS}';
CREATE USER '${USER}'@'localhost' IDENTIFIED BY '${PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON ${DB}.* TO '${USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

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

cp /usr/local/lib/php/phabricator/resources/sshd/phabricator-sudoers.sample /usr/local/etc/sudoers.d

cat >>/etc/ssh/sshd_config <<EOF
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

service sshd start

mkdir -p /var/phabricator/files
mkdir -p /var/phabricator/repo
chown -Rf www:www /var/phabricator

cd /usr/local/lib/php/phabricator && ./bin/config set mysql.host "localhost"
cd /usr/local/lib/php/phabricator && ./bin/config set mysql.user "$USER"
cd /usr/local/lib/php/phabricator && ./bin/config set mysql.pass "$PASS"
cd /usr/local/lib/php/phabricator && ./bin/config set phabricator.base-uri "http://`hostname`.shenrs.eu"

cd /usr/local/lib/php/phabricator && ./bin/storage upgrade --force 

#restart the services to make sure we have pick up the new permission
service php-fpm restart 2>/dev/null
#nginx restarts to fast while php is not fully started yet
sleep 5
service nginx restart 2>/dev/null

sleep 5
service phd start 2>/dev/null

echo "Database Name: $DB" > /root/PLUGIN_INFO
echo "Database User: $USER" >> /root/PLUGIN_INFO
echo "Database Password: $PASS" >> /root/PLUGIN_INFO

# echo "Phabricator Admin User: $NCUSER" >> /root/PLUGIN_INFO
# echo "Phabricator Admin Password: $NCPASS" >> /root/PLUGIN_INFO
