#!/bin/bash

set -e

[ "$DEBUG" == "1" ] && set -x && set +e

# Required variables
sleep 5
export GLUSTER_HOSTS=`dig +short ${GLUSTER_HOST}`
if [ -z "${GLUSTER_HOSTS}" ]; then
   echo "*** ERROR: Could not determine which containers are part of Gluster service."
   echo "*** Is Gluster service linked with the alias \"${GLUSTER_HOST}\"?"
   echo "*** If not, please link gluster service as \"${GLUSTER_HOST}\""
   echo "*** Exiting ..."
   exit 1
fi
export DB_HOSTS=`dig +short ${DB_HOST}`
if [ -z "${DB_HOSTS}" ]; then
   echo "*** ERROR: Could not determine which containers are part of Gluster service."
   echo "*** Is Gluster service linked with the alias \"${DB_HOST}\"?"
   echo "*** If not, please link gluster service as \"${DB_HOST}\""
   echo "*** Exiting ..."
   exit 1
fi

if [ "${DB_PASSWORD}" == "**ChangeMe**" -o -z "${DB_PASSWORD}" ]; then
   echo "ERROR: You did not specify "DB_PASSWORD" environment variable - Exiting..."
   exit 0
fi

if [ "${DB_NAME}" == "**ChangeMe**" -o -z "${DB_NAME}" ]; then
   DB_NAME=`echo "${WORDPRESS_NAME}" | sed "s/\./-/g"`
fi

if [ "${HTTP_DOCUMENTROOT}" == "**ChangeMe**" -o -z "${HTTP_DOCUMENTROOT}" ]; then
   HTTP_DOCUMENTROOT=${GLUSTER_VOL_PATH}/${WORDPRESS_NAME}
fi

ALIVE=0
for glusterHost in ${GLUSTER_HOSTS}; do
    echo "=> Checking if I can reach GlusterFS node ${glusterHost} ..."
    if ping -c 10 ${glusterHost} >/dev/null 2>&1; then
       echo "=> GlusterFS node ${glusterHost} is alive"
       ALIVE=1
       break
    else
       echo "*** Could not reach server ${glusterHost} ..."
    fi
done

if [ "$ALIVE" == 0 ]; then
   echo "ERROR: could not contact any GlusterFS node from this list: ${GLUSTER_HOSTS} - Exiting..."
   exit 1
fi

echo "=> Mounting GlusterFS volume ${GLUSTER_VOL} from GlusterFS node ${glusterHost} ..."
mount -t glusterfs ${glusterHost}:/${GLUSTER_VOL} ${GLUSTER_VOL_PATH}

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

   for host in `echo ${DB_HOSTS} | sed "s/,/ /g"`; do
      PXC_HOSTS_HAPROXY="$PXC_HOSTS_HAPROXY\n  server pxc$PXC_HOSTS_COUNTER $host check port 9200 rise 2 fall 3"
      if [ $PXC_HOSTS_COUNTER -gt 0 ]; then
         PXC_HOSTS_HAPROXY="$PXC_HOSTS_HAPROXY backup"
      fi
      PXC_HOSTS_COUNTER=$((PXC_HOSTS_COUNTER+1))
   done
   perl -p -i -e "s/DB_PASSWORD/${DB_PASSWORD}/g" /etc/haproxy/haproxy.cfg
   perl -p -i -e "s/.*server pxc.*//g" /etc/haproxy/haproxy.cfg
   perl -p -i -e "s/# PXC nodes here.*/# PXC nodes here\n${PXC_HOSTS_HAPROXY}/g" /etc/haproxy/haproxy.cfg
fi

if [ ! -e ${HTTP_DOCUMENTROOT}/wp-config.php ] && [ -e ${HTTP_DOCUMENTROOT}/wp-config-sample.php ] ; then
   echo "=> Configuring wordpress..."
   touch ${HTTP_DOCUMENTROOT}/wp-config.php
   WP_DB_PASSWORD=`pwgen -s 20 1`
   sed -e "s/database_name_here/$DB_NAME/
   s/username_here/$DB_NAME/
   s/password_here/$WP_DB_PASSWORD/
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

  echo "=> Creating database ${DB_NAME}, username ${DB_NAME}, with password ${WP_DB_PASSWORD} ..."
  service haproxy start
  sleep 2
  mysql -h 127.0.0.1 -u root -p${DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME}; GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_NAME}'@'10.42.%' IDENTIFIED BY '${WP_DB_PASSWORD}'; FLUSH PRIVILEGES;"
  service haproxy stop
fi

if [ ! -e ${HTTP_DOCUMENTROOT}/healthcheck.txt ]; then
   echo "OK" > ${HTTP_DOCUMENTROOT}/healthcheck.txt
fi

/usr/bin/supervisord
