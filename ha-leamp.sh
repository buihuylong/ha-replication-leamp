#!/bash/shall
#Write by KeepWalking86
##Shell script to install & config
##Website running laravel-5.6, php7.1, mongo-3.4, nginx-1.x, apache-2.4, ...

#Check OS CentOS-7x
echo "Current OS version"
hostnamectl

##Disable SELinux 
###Disable SELinux Temporarily
setenforce 0
###Disable SELinux Permanently
####Applicated after you restart OS
sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/sysconfig/selinux

#Check user account to run script
USER=$UID
if [ $USER != 0 ]; then
        echo "You need root account to install system"
        exit 1;
fi

##Set Timezone Vietnam Asia/Ho_Chi_Minh GMT+7
timedatectl set-timezone "Asia/Ho_Chi_Minh"

#datetime
NOW=$(date +&Y-%m-%d)

##Server IP Address
#Server01=192.168.10.111/24 && Server02=192.168.10.112/24
IP_SERVER=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')
SERVER01=192.168.10.111
SERVER02=192.168.10.112
VIP_ADDR=192.168.10.113 #VIP ipaddress for HA
#show network interface 'state UP'
#ip a |grep 'state UP' |awk '{print $2}' | cut -d':' -f1
NET_INTERFACE=enp0s3 #replace with your network interface
#Network Address
NET_ADDR=192.168.10.0/24

##Set hosts
cat >>/etc/hosts <<EOF
$SERVER01    server01
$SERVER02    server02
EOF

##Config SSH Keys on servers
echo "*** INSTALLING SSH KEYS***"
#create keys with empty passphrase
[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
#copy ssh key over other server
if [ $IP_SERVER == $SERVER01 ]; then
    #ssh-copy-id -i ~/.ssh/id_rsa.pub $SERVER02
    ssh-copy-id $SERVER02
else
    ssh-copy-id $SERVER01
fi

##Install tools, libraries to compile, download, ...
yum groupinstall "Development Tools" -y
yum install vim net-tools tmux -y

##Install repositories
yum -y install epel-release
rpm -Uvh https://mirror.webtatic.com/yum/el7/webtatic-release.rpm

##Installing PHP7
yum -y install php71w php71w-common php71w-gd php71w-phar php71w-xml php71w-cli php71w-mbstring php71w-tokenizer php71w-openssl php71w-pdo php71w-devel
###Install php Zend OPcache
yum -y install php71w-opcache


##INSTALLING APACHE + NGINX + ...
echo "---------------------------------------------------------"
echo "----------INSTALLING APACHE + NGINX + ...----------------"
echo "---------------------------------------------------------"

##Install Apache
echo "----------------------------------------------------"
echo "----INSTALLING & BASIC CONFIGURATION FOR APACHE ----"
echo "----------------------------------------------------"
yum -y install httpd
###Edit httpd.conf 
###listen sites on port 8080 (80 default port will be used by nginx reverse proxy)
sed -i '/Listen 80/c\Listen 8080' /etc/httpd/conf/httpd.conf

###Change LogFormat to log real agent ipaddress, instead of localhost ipaddress (127.0.0.1)
sed -i '/LogFormat.*combined$/c\    LogFormat "%{X-Forwarded-For}i %l %u %t \\"%r\\" %>s %b \\"%{Referer}i\\" \\"%{User-Agent}i\\"" combined' /etc/httpd/conf/httpd.conf

##Create VirtualHosts "example.local"
###read -p "Enter your domain: " DOMAIN
DOMAIN="example.local"
###Document Root
DOCUMENT_ROOT="/var/www/${DOMAIN}"
[ ! -d $DOCUMENT_ROOT ] && mkdir -p $DOCUMENT_ROOT
###Create example.local configuration file
cat >/etc/httpd/conf.d/${DOMAIN}.conf <<EOF
<VirtualHost *:8080>
    ServerAdmin keepwalking@${DOMAIN}
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot ${DOCUMENT_ROOT}/public
    ##Note: to use .htaccess, we need AllowOverride All (the first, enable rewrite_module)
    #ex: we want remove index from url
    <Directory ${DOCUMENT_ROOT}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>    
    ErrorLog ${DOCUMENT_ROOT}/logs/error.log
    CustomLog ${DOCUMENT_ROOT}/logs/access.log combined
</VirtualHost>
EOF

#Create logs directory
mkdir -p ${DOCUMENT_ROOT}/logs

#Start & enable Apache
systemctl start httpd.service
systemctl enable httpd.service

#Open port 80, 443 & 8080 on firewall
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --reload

##Install Laravel 5
echo "--------------------------------------------"
echo "-------------Installing Laravel 5-----------"
echo "--------------------------------------------"

#Install PHP Composer
curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/bin --filename=composer

#Install Laravel
#Laravel provides two ways for the installation of the framework on the server. 
#We can install Laravel with the laravel installer, and we can install it with PHP composer
cd ${DOCUMENT_ROOT}
composer create-project laravel/laravel .

#Set the Permissions
chown -R apache:apache ${DOCUMENT_ROOT}
chmod -R 755 ${DOCUMENT_ROOT}/laravel/storage

###Redis for cache & session PHP Laravel##
echo "--------Redis for PHP Laravel session--------"
echo "---------------------------------------------"
##Installing Redis & PhpRedis extension
yum -y install redis
#Before using Redis with Laravel, we need to install the predis/predis package via compose
cd ${DOCUMENT_ROOT}
composer require predis/predis
#Can use phpredis replace predis/predis
yum -y install php71w-pecl-redis
#start redis service
service redis start
#open firewall
firewall-cmd --permanent --add-port=6379/tcp
firewall-cmd --reload

###########INSTALLING & REPLICATION MONGODB-3X###############
echo "---------------------------------------------------------"
echo "-----------INSTALLING & REPLICATION MONGODB-3X-----------"
echo "---------------------------------------------------------"

##Installing MongoDB
echo "---------------------------------------------------"
echo "--------------Installing MongoDB-------------------"
#Creating repo mongodb
cat >/etc/yum.repos.d/mongodb-org.repo <<EOF
[mongodb-org-3.4]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/3.4/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-3.4.asc
EOF
#Install MongoDB
yum install mongodb-org -y
#Start & enable MongoDB
systemctl start mongod
systemctl enable mongod

##Installing mongo-php-library
#with PHP 7 version, we can use composer to install mongo-php-library
yum -y install php71w-pear
pecl install mongodb
#Add extension mongodb.so in [PHP] block
sed -i '/extension=msql.so/c\extension=mongodb.so' /etc/php.ini
yum install php71w-pecl-mongodb
#using composer to update
cd ${DOCUMENT_ROOT}
composer update

## Replication MongoDB servers
echo "---------------------------------------------------"
echo "-------------- Replication MongoDB-----------------"
echo "---------------------------------------------------"

#Allow access mongo from any IPs
#Edit /etc/mongod.conf on servers
sed -i 's/127.0.0.1/0.0.0.0/' /etc/mongod.conf
#Open firewall to allow access local network
firewall-cmd --permanent --zone=public --add-rich-rule="rule family="ipv4" source address="$NET_ADDR" port port="27017" protocol="tcp" accept"
firewall-cmd --reload

#Set replication mongo
#Server01 is primary, server02 is secondary
#Set /etc/mongod.conf
cat >>/etc/mongod.conf <<EOF
replication:
  replSetName: mongo_rep
EOF
#restart mongod
systemctl restart mongod

###Init mongodb replica set on primary server01
# mongo --host 127.0.0.1 --port 27017
# >rs.initiate({_id:"mongo_example",members:[{_id:1,host:"mobifonetv01:27017",priority:3},{_id:2,host:"mobifonetv02:27017",priority:2}]})

# **********************************
# reconfigure your replication as per below steps
# > cfg = rs.conf()
# > cfg.members = [cfg.members[1]]
# > rs.reconfig(cfg, {force : true})
# ***********************************


#########INSTALLING NGINX AS REVERSE PROXY OR LOAD BALANCING##############
echo "-------------------------------------------------------------------"
echo "-----------------INSTALLING NGINX AS REVERSE PROXY-----------------"
echo "-------------------------------------------------------------------"

##Installing Nginx
yum -y install nginx
systemctl enable nginx.service
service nginx restart

##Using Nginx as Reverse proxy
#Configuring standard proxy parameters
cat >/etc/nginx/proxy_params <<EOF
proxy_set_header Host \$http_host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
client_max_body_size    10m;
client_body_buffer_size 128k;
proxy_connect_timeout   90;
proxy_send_timeout      90;
proxy_read_timeout      90;
proxy_buffers           32 4k;
EOF

##Create many virtualhosts, same server_name as apache
mkdir /etc/nginx/sites-available/
mkdir /etc/nginx/sites-enabled/
#Edit nginx.conf and add new line include /etc/nginx/sites-enabled/*; in http block
sed -i 's/include.*mime.types;/&\
    include \/etc\/nginx\/sites-enabled\/*;/g' /etc/nginx/nginx.conf

#Reverse proxy for site example.local
cat >/etc/nginx/sites-available/${DOMAIN}.conf <<EOF
server {
  server_name $DOMAIN;
  root /var/www/${DOMAIN};
  # app1 reverse proxy follow
  #proxy_set_header X-Real-IP $remote_addr;
  #proxy_set_header Host $host;
  #proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  location / {
        proxy_pass http://${IP_SERVER}:8080;
        include /etc/nginx/proxy_params;
  }
}
EOF

#Enable reverse proxy for site example.local
cd /etc/nginx/sites-enabled
ln -s ../sites-available/${DOMAIN}.conf .
systemctl restart nginx.service

###mod_remoteip default installed with apache-2.4
####To using, we add lines following to httpd.conf
####Them Khoi moi vao sau string /IfModule dau tien cua /etc/httpd/conf.d
# sed -e ''  /&\
# <IfModule remoteip_module>
# RemoteIPHeader X-Real-IP
# RemoteIPInternalProxy 192.168.10.101
# </IfModule>/g' /etc/http/conf/httpd.conf

#########################HIGH AVAILABLE###############################
echo "----------------------------------------------------------------"
echo "-------------------------HA WAP/WEB-----------------------------"
echo "----------------------------------------------------------------"

##Installing & Config KeepAlived
yum -y install keepalived
#On CentOS 7 minimal, default killall not exist, then install the follow package:
yum -y install psmisc

##Config keepalived.conf
if [ $IP_SERVER==$SERVER01 ]; then
    cat >/etc/keepalived/keepalived.conf <<EOF
! Configuration File for keepalived
global_defs {
   notification_email {
     info@${DOMAIN}
   }
   smtp_server mail.${DOMAIN}
   notification_email_from info@${DOMAIN}
   smtp_connect_timeout 30
   router_id LVS_MASTER
}
vrrp_script chk_nginx {
        script "killall -0 nginx"       # verify the pid is exist or not
        interval 2                      # check every 2 seconds
        weight 2                        # add 2 points of prio if OK
}
vrrp_script chk_httpd {
        script "killall -0 httpd"       # verify the pid is exist or not
        interval 2                      # check every 2 seconds
        weight 2                        # add 2 points of prio if OK
}
vrrp_instance VI_1 {
    state MASTER
    interface $NET_INTERFACE
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass k@l!ve  #same for all machines
    }
    virtual_ipaddress {
        $VIP_ADDR
    }
    track_script {
        chk_nginx
        chk_httpd
    }
}
EOF
else
    cat >/etc/keepalived/keepalived.conf <<EOF
! Configuration File for keepalived
global_defs {
   notification_email {
     info@${DOMAIN}
   }
   smtp_server mail.${DOMAIN}
   smtp_connect_timeout 30
   router_id LVS_BACKUP
}
vrrp_script chk_nginx {
        script "killall -0 nginx"       # verify the pid is exist or not
        interval 2                      # check every 2 seconds
        weight 2                        # add 2 points of prio if OK
}
vrrp_script chk_httpd {
        script "killall -0 httpd"       # verify the pid is exist or not
        interval 2                      # check every 2 seconds
        weight 2                        # add 2 points of prio if OK
}
vrrp_instance VI_1 {
    state BACKUP
    interface $NET_INTERFACE
    virtual_router_id 51
    priority 99
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass k@l!ve  #same for all machines
    }
    virtual_ipaddress {
        $VIP_ADDR
    }
    track_script {
        chk_nginx
        chk_httpd
    }
    #track_interface { #Check by network interface
    #   eth0
    #   eth1
    #}

}
EOF
fi

#Add firewall rules to allow VRRP communication using the multicast IP address 224.0.0.18 
#and the VRRP protocol (112) on each network interface that Keepalived will control
firewall-cmd --direct --permanent --add-rule ipv4 filter INPUT 0 \
  --in-interface $NET_INTERFACE --destination 224.0.0.18 --protocol vrrp -j ACCEPT
firewall-cmd --direct --permanent --add-rule ipv4 filter OUTPUT 0 \
  --out-interface $NET_INTERFACE --destination 224.0.0.18 --protocol vrrp -j ACCEPT
firewall-cmd --reload

#Start keepalived
systemctl start keepalived
systemctl enable keepalived
