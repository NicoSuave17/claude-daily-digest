defaults
auth            on
tls             on
tls_trust_file  /etc/ssl/cert.pem
logfile         __INSTALL_DIR__/logs/msmtp.log

account gmail
host            smtp.gmail.com
port            587
from            __EMAIL__
user            __EMAIL__
passwordeval    "security find-generic-password -s __KEYCHAIN_SERVICE__ -w /Library/Keychains/System.keychain"

account default : gmail
