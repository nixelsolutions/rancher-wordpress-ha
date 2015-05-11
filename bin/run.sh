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

if [ ! -e ${HTTP_DOCUMENTROOT}/index.php ]; then
   echo "=> Installing wordpress in ${HTTP_DOCUMENTROOT} - this may take a while ..."
   curl -o /tmp/wordpress.tar.gz "https://wordpress.org/wordpress-${WORDPRESS_VERSION}.tar.gz"
   tar -zxf /tmp/wordpress.tar.gz -C /tmp/
   mv /tmp/wordpress/* ${HTTP_DOCUMENTROOT}/
   chown -R www-data:www-data ${HTTP_DOCUMENTROOT}
fi

if [ ! -e ${HTTP_DOCUMENTROOT}/wp-config.php ]; then
   echo "=> Configuring wordpress..."
   sed -e "s/database_name_here/$WORDPRESS_DB_NAME/
   s/username_here/$WORDPRESS_DB_USER/
   s/password_here/$WORDPRESS_DB_PASSWORD/
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
fi

if grep WORDPRESS_DB_HOSTS /etc/mysql/mysql-proxy.cnf >/dev/null; then
   perl -p -i -e "s/WORDPRESS_DB_HOSTS/${WORDPRESS_DB_HOSTS}/g" /etc/mysql/mysql-proxy.cnf
fi

if grep WORDPRESS_DB_USER /etc/mysql/mysql-proxy.cnf >/dev/null; then
   perl -p -i -e "s/WORDPRESS_DB_USER/${WORDPRESS_DB_USER}/g" /etc/mysql/mysql-proxy.cnf
fi

if grep WORDPRESS_DB_PASSWORD /etc/mysql/mysql-proxy.cnf >/dev/null; then
   perl -p -i -e "s/WORDPRESS_DB_PASSWORD/${WORDPRESS_DB_PASSWORD}/g" /etc/mysql/mysql-proxy.cnf
fi

/usr/bin/supervisord
