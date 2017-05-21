#!/bin/bash
#Install script to install Pterodactyl panel v0.6.0 and Wings daemon v0.4.0 on Ubuntu 16.04
function output() {
  echo -e '\e[34m'$1'\e[0m'; #Blue text
}

function installchoice {
  output "This install script is only meant for use on fresh OS installs. Installing on a non-fresh OS could break things."
  output "Please select what you would like to install:\n[1] Install the panel.\n[2] Install the daemon.\n[3] Install the panel and daemon."
  read choice
  case $choice in
      1 ) installoption=1
          output "You have selected panel installation only."
          ;;
      2 ) installoption=2
          output "You have selected daemon installation only."
          ;;
      3 ) installoption=3
          output "You have selected panel and daemon installation."
          ;;
      * ) output "You did not enter a a valid selection"
          installchoice
  esac
}

function webserverchoice {
  output "Please select which web server you would like to use:\n[1] nginx.\n[2] apache."
  read choice
  case $choice in
      1 ) webserver=1
          output "You have selected nginx."
          ;;
      2 ) webserver=2
          output "You have selected apache."
          ;;
      * ) output "You did not enter a a valid selection"
          webserverchoice
  esac
}

function required_vars_panel {
    output "Please enter your FQDN:"
    read FQDN

    output "Please enter your timezone in PHP format"
    read timezone

    output "Please enter the desired user email address:"
    read email

    output "Please enter the desired password:"
    read password
}

function required_vars_daemon {
  output "Please enter your FQDN"
  read FQDN
}

#All panel related install functions
function install_apache_dependencies {
  # Add additional PHP packages.
  add-apt-repository -y ppa:ondrej/php
  curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

  # Update APT
  apt update

  # Install Dependencies
  apt-get -y install php7.1 php7.1-cli php7.1-gd php7.1-mysql php7.1-pdo php7.1-mbstring php7.1-tokenizer php7.1-bcmath php7.1-xml php7.1-curl php7.1-memcached php7.1-zip mariadb-server libapache2-mod-php apache2 curl tar unzip git memcached
}

function install_nginx_dependencies {
  # Add additional PHP packages.
  add-apt-repository -y ppa:ondrej/php
  curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

  # Update repositories list
  apt update

  # Install Dependencies
  apt-get -y install php7.1 php7.1-cli php7.1-gd php7.1-mysql php7.1-pdo php7.1-mbstring php7.1-tokenizer php7.1-bcmath php7.1-xml php7.1-fpm php7.1-memcached php7.1-curl php7.1-zip mariadb-server nginx curl tar unzip git memcached
}

function panel_downloading {
  mkdir -p /var/www/html/pterodactyl
  cd /var/www/html/pterodactyl

  curl -Lo v0.6.0.tar.gz https://github.com/Pterodactyl/Panel/archive/v0.6.0.tar.gz
  tar --strip-components=1 -xzvf v0.6.0.tar.gz

  chmod -R 755 storage/* bootstrap/cache
}

function panel_installing {
  curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer

  cp .env.example .env
  composer install --no-dev
  php artisan key:generate --force

  #Create MySQL database with random password
  password=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`

  Q1="CREATE DATABASE IF NOT EXISTS pterodactyl;"
  Q2="GRANT ALL ON pterodactyl.* TO 'panel'@'localhost' IDENTIFIED BY '$password';"
  Q3="FLUSH PRIVILEGES;"
  SQL="${Q1}${Q2}${Q3}"

  mysql -u root -p="" -e "$SQL"

  php artisan pterodactyl:env --dbhost=localhost --dbport=3306 --dbname=pterodactyl --dbuser=panel --dbpass=$password --url=http://$FQDN --timezone=$timezone

  php artisan migrate
  php artisan db:seed

  php artisan pterodactyl:user --email=$email --password=$password --admin=1

  chown -R www-data:www-data *
}

function panel_queuelisteners {
  (crontab -l ; echo "* * * * * php /var/www/pterodactyl/html/artisan schedule:run >> /dev/null 2>&1")| crontab -

  cat > /etc/systemd/system/pteroq.service <<- "EOF"
  # Pterodactyl Queue Worker File
  [Unit]
  Description=Pterodactyl Queue Worker

  [Service]
  User=www-data
  Group=www-data
  Restart=on-failure
  ExecStart=/usr/bin/php /var/www/html/pterodactyl/artisan queue:work database --queue=high,standard,low --sleep=3 --tries=3

  [Install]
  WantedBy=multi-user.target
  EOF

  sudo systemctl enable pteroq.service
  sudo systemctl start pteroq
}

function ssl_certs {
  cd /root
  curl https://get.acme.sh | sh
  cd /root/.acme.sh/
  sh acme.sh --issue --apache -d $FQDN

  mkdir -p /etc/letsencrypt/live/$FQDN
  ./acme.sh --install-cert -d $FQDN --certpath /etc/letsencrypt/live/$FQDN/cert.pem --keypath /etc/letsencrypt/live/$FQDN/privkey.pem --fullchainpath /etc/letsencrypt/live/$FQDN/fullchain.pem
}

function panel_webserver_configuration_nginx {
  output "ngingwebconf"
}

function panel_webserver_configuration_apache {
  cat > /etc/apache2/sites-available/pterodactyl.conf <<- "EOF"
  <IfModule mod_ssl.c>
  <VirtualHost *:443>
          ServerAdmin webmaster@localhost
          DocumentRoot "/var/www/pterodactyl/html/public"
          AllowEncodedSlashes On
          php_value upload_max_filesize 100M
          php_value post_max_size 100M
          <Directory "/var/www/pterodactyl/html/public">
          AllowOverride all
          </Directory>

          SSLEngine on
          SSLCertificateFile /etc/letsencrypt/live/$FQDN/fullchain.pem
          SSLCertificateKeyFile /etc/letsencrypt/live/$FQDN/privkey.pem
          ServerName $FQDN
  </VirtualHost>
  </IfModule>
  EOF

  cat > /etc/apache2/sites-available/000-default.conf <<- "EOF"
  <VirtualHost *:80>
  RewriteEngine on
  RewriteCond %{SERVER_NAME} =$FQDN
  RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,QSA,R=permanent]
  </VirtualHost>
  EOF

  sudo ln -s /etc/apache2/sites-available/pterodactyl.conf /etc/apache2/sites-enabled/pterodactyl.conf
  sudo a2enmod rewrite
  sudo a2enmod ssl
  service apache2 restart
}

#All daemon related install functions
function update_kernel {
  apt install linux-image-extra-$(uname -r) linux-image-extra-virtual
}

function daemon_dependencies {
  #Docker
  curl -sSL https://get.docker.com/ | sh
  systemctl enable docker

  #Nodejs
  curl -sL https://deb.nodesource.com/setup_6.x | sudo -E bash -
  apt install nodejs

  #Additional
  apt install tar unzip make gcc g++ python
}

function daemon_install {
  mkdir -p /srv/daemon /srv/daemon-data
  cd /srv/daemon
  curl -Lo v0.4.0.tar.gz https://github.com/Pterodactyl/Daemon/archive/v0.4.0.tar.gz
  tar --strip-components=1 -xzvf v0.4.0.tar.gz
  npm install --only=production

  echo -e "[Unit]\nDescription=Pterodactyl Wings Daemon\nAfter=docker.service\n\n[Service]\nUser=root\n#Group=some_group\nWorkingDirectory=/srv/daemon\nLimitNOFILE=4096\nPIDFile=/var/run/wings/daemon.pid\nExecStart=/usr/bin/node /srv/daemon/src/index.js\nRestart=on-failure\nStartLimitInterval=600\n\n[Install]\nWantedBy=multi-user.target" > /etc/systemd/system/wings.service
  systemctl daemon-reload
  systemctl enable wings
}

# Time for some user input
installchoice

# Let's figure out what we actually are going to install based on user input
case $installoption in
  1 ) webserverchoice #Panel only, so we show the webserver selection
      required_vars_panel #Gather some user data we need for the installation
      case $webserver in #Install based on choice
        1 ) install_nginx_dependencies
            panel_downloading
            panel_installing
            panel_queuelisteners
            panel_webserver_configuration_nginx
            output "Installation completed!"
            ;;
        2 ) install_apache_dependencies
            panel_downloading
            panel_installing
            panel_queuelisteners
            ssl_certs
            panel_webserver_configuration_apache
            ok "Installation completed"
            ;;
      esac



      ;;
  2 ) #Daemon only
      update_kernel
      daemon_dependencies

      ;;
  3 ) webserverchoice #Panel and daemon, so we show the webserver selection
      required_vars_panel #Gather some user data we need for the installation
      case $webserver in #Install based on choice
        1) install_nginx_dependencies
           ;;
        2) install_apache_dependencies
           ;;
      esac
      ;;
esac