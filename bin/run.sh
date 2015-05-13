#!/bin/bash

set -e

[ "$DEBUG" == "1" ] && set -x && set +e

if [ "${GLUSTER_PEER}" == "**ChangeMe**" ]; then
   echo "ERROR: You did not specify "GLUSTER_PEER" environment variable - Exiting..."
   exit 0
fi
if [ "${WORDPRESS_DB_HOSTS}" == "**ChangeMe**" ]; then
   echo "ERROR: You did not specify "WORDPRESS_DB_HOSTS" environment variable - Exiting..."
   exit 0
fi
if [ "${WORDPRESS_DB_PASSWORD}" == "**ChangeMe**" ]; then
   echo "ERROR: You did not specify "WORDPRESS_DB_PASSWORD" environment variable - Exiting..."
   exit 0
fi

ALIVE=0
for PEER in `echo "${GLUSTER_PEER}" | sed "s/,/ /g"`; do
    echo "=> Checking if I can reach GlusterFS node ${PEER} ..."
    if ping -c 10 ${PEER} >/dev/null 2>&1; then
       echo "=> GlusterFS node ${PEER} is alive"
       ALIVE=1
       break
    else
       echo "*** Could not reach server ${PEER} ..."
    fi
done

if [ "$ALIVE" == 0 ]; then
   echo "ERROR: could not contact any GlusterFS node from this list: ${GLUSTER_PEER} - Exiting..."
   exit 1
fi

echo "=> Mounting GlusterFS volume ${GLUSTER_VOL} from GlusterFS node ${PEER} ..."
mount -t glusterfs ${PEER}:/${GLUSTER_VOL} ${GLUSTER_VOL_PATH}

if [ ! -d ${HTTP_DOCUMENTROOT} ]; then
   mkdir -p ${HTTP_DOCUMENTROOT}
fi

if [ ! -d ${PHP_SESSION_PATH} ]; then
   mkdir -p ${PHP_SESSION_PATH}
   chown www-data:www-data ${PHP_SESSION_PATH}
fi

if [ ! -e ${HTTP_DOCUMENTROOT}/index.php ]; then
   echo "=> Installing wordpress in ${HTTP_DOCUMENTROOT} - this may take a while ..."
   touch ${HTTP_DOCUMENTROOT}/index.php
   curl -o /tmp/wordpress.tar.gz "https://wordpress.org/wordpress-${WORDPRESS_VERSION}.tar.gz"
   tar -zxf /tmp/wordpress.tar.gz -C /tmp/
   mv /tmp/wordpress/* ${HTTP_DOCUMENTROOT}/
   chown -R www-data:www-data ${HTTP_DOCUMENTROOT}
fi

if grep "PXC nodes here" /etc/haproxy/haproxy.cfg >/dev/null; then
   PXC_HOSTS_HAPROXY=""
   PXC_HOSTS_COUNTER=0

   for host in `echo ${WORDPRESS_DB_HOSTS} | sed "s/,/ /g"`; do
      PXC_HOSTS_HAPROXY="$PXC_HOSTS_HAPROXY\n  server pxc$PXC_HOSTS_COUNTER $host check port 9200 rise 2 fall 3"
      if [ $PXC_HOSTS_COUNTER -gt 0 ]; then
         PXC_HOSTS_HAPROXY="$PXC_HOSTS_HAPROXY backup"
      fi
      PXC_HOSTS_COUNTER=$((PXC_HOSTS_COUNTER+1))
   done
   perl -p -i -e "s/WORDPRESS_DB_PASSWORD/${WORDPRESS_DB_PASSWORD}/g" /etc/haproxy/haproxy.cfg
   perl -p -i -e "s/# PXC nodes here.*/${PXC_HOSTS_HAPROXY}/g" /etc/haproxy/haproxy.cfg
fi

if [ ! -e ${HTTP_DOCUMENTROOT}/wp-config.php ] && [ -e ${HTTP_DOCUMENTROOT}/wp-config-sample.php ] ; then
   echo "=> Configuring wordpress..."
   touch ${HTTP_DOCUMENTROOT}/wp-config.php
   DB_PASSWORD=`pwgen -s 20 1`
   sed -e "s/database_name_here/$WORDPRESS_DB_NAME/
   s/username_here/$WORDPRESS_DB_NAME/
   s/password_here/$DB_PASSWORD/
   s/localhost/127.0.0.1/
   /'AUTH_KEY'/s/put your unique phrase here/`pwgen -c -n -1 65`/
   /'SECURE_AUTH_KEY'/s/put your unique phrase here/`pwgen -c -n -1 65`/
   /'LOGGED_IN_KEY'/s/put your unique phrase here/`pwgen -c -n -1 65`/
   /'NONCE_KEY'/s/put your unique phrase here/`pwgen -c -n -1 65`/
   /'AUTH_SALT'/s/put your unique phrase here/`pwgen -c -n -1 65`/
   /'SECURE_AUTH_SALT'/s/put your unique phrase here/`pwgen -c -n -1 65`/
   /'LOGGED_IN_SALT'/s/put your unique phrase here/`pwgen -c -n -1 65`/
   /'NONCE_SALT'/s/put your unique phrase here/`pwgen -c -n -1 65`/" ${HTTP_DOCUMENTROOT}/wp-config-sample.php > ${HTTP_DOCUMENTROOT}/wp-config.php
   chown www-data:www-data ${HTTP_DOCUMENTROOT}/wp-config.php
   chmod 640 ${HTTP_DOCUMENTROOT}/wp-config.php

  # Download nginx helper plugin
  curl -O `curl -i -s https://wordpress.org/plugins/nginx-helper/ | egrep -o "https://downloads.wordpress.org/plugin/[^']+"`
  unzip -o nginx-helper.*.zip -d ${HTTP_DOCUMENTROOT}/wp-content/plugins
  chown -R www-data:www-data ${HTTP_DOCUMENTROOT}/wp-content/plugins/nginx-helper

  # Activate nginx plugin and set up pretty permalink structure once logged in
  cat << ENDL >> ${HTTP_DOCUMENTROOT}/wp-config.php
\$plugins = get_option( 'active_plugins' );
if ( count( \$plugins ) === 0 ) {
  require_once(ABSPATH .'/wp-admin/includes/plugin.php');
  \$wp_rewrite->set_permalink_structure( '/%postname%/' );
  \$pluginsToActivate = array( 'nginx-helper/nginx-helper.php' );
  foreach ( \$pluginsToActivate as \$plugin ) {
    if ( !in_array( \$plugin, \$plugins ) ) {
      activate_plugin( '${HTTP_DOCUMENTROOT}/wp-content/plugins/' . \$plugin );
    }
  }
}
ENDL

  echo "=> Creating database ${WORDPRESS_DB_NAME}, username ${WORDPRESS_DB_NAME}, with password ${DB_PASSWORD} ..."
  service haproxy start
  sleep 2
  mysql -h 127.0.0.1 -u root -p${WORDPRESS_DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS ${WORDPRESS_DB_NAME}; GRANT ALL PRIVILEGES ON ${WORDPRESS_DB_NAME}.* TO '${WORDPRESS_DB_NAME}'@'10.42.%' IDENTIFIED BY '${DB_PASSWORD}'; FLUSH PRIVILEGES;"
  service haproxy stop
fi

if [ ! -e ${HTTP_DOCUMENTROOT}/healthcheck.txt ]; then
   echo "OK" > ${HTTP_DOCUMENTROOT}/healthcheck.txt
fi

/usr/bin/supervisord
