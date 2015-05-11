FROM ubuntu:14.04

MAINTAINER Manel Martinez <manel@nixelsolutions.com>

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y python-software-properties software-properties-common
RUN add-apt-repository -y ppa:gluster/glusterfs-3.5 && \
    apt-get update && \
    apt-get install -y nginx php5-fpm php5-mysql php-apc supervisor glusterfs-client curl mysql-proxy pwgen unzip

ENV GLUSTER_PEER **ChangeMe**

ENV WORDPRESS_VERSION 4.2.2
ENV GLUSTER_VOL ranchervol
ENV GLUSTER_VOL_PATH /var/www/html
ENV HTTP_PORT 80
ENV HTTP_DOCUMENTROOT ${GLUSTER_VOL_PATH}
ENV DEBUG 0

ENV WORDPRESS_DB_HOSTS **ChangeMe**
ENV WORDPRESS_DB_USER root
ENV WORDPRESS_DB_PASSWORD **ChangeMe**
ENV WORDPRESS_DB_NAME wordpress

RUN mkdir -p /var/log/supervisor ${GLUSTER_VOL_PATH}
WORKDIR ${GLUSTER_VOL_PATH}

RUN mkdir -p /usr/local/bin
ADD ./bin /usr/local/bin
RUN chmod +x /usr/local/bin/*.sh
ADD ./etc/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
ADD ./etc/mysql/mysql-proxy.cnf /etc/mysql/mysql-proxy.cnf
#ADD ./etc/nginx/sites-enabled/wordpress /etc/nginx/sites-enabled/wordpress

RUN perl -p -i -e "s/ENABLED=\"false\"/ENABLED=\"true\"/g" /etc/default/mysql-proxy
RUN perl -p -i -e "s/OPTIONS=\"\"/OPTIONS=\"--defaults-file=\/etc\/mysql\/mysql-proxy.cnf\"/g" /etc/default/mysql-proxy
RUN chmod 0600 /etc/mysql/mysql-proxy.cnf

RUN echo "daemon off;" >> /etc/nginx/nginx.conf
RUN rm -f /etc/nginx/sites-enabled/default
#RUN HTTP_ESCAPED_DOCROOT=`echo ${HTTP_DOCUMENTROOT} | sed "s/\//\\\\\\\\\//g"` && perl -p -i -e "s/HTTP_DOCUMENTROOT/${HTTP_ESCAPED_DOCROOT}/g" /etc/nginx/sites-enabled/wordpress

CMD ["/usr/local/bin/run.sh"]
