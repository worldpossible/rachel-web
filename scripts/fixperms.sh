#!/bin/bash

# fix our main website permissions
find /var/www -type d -print0 | xargs -0 chmod 0775
find /var/www -type f -print0 | xargs -0 chmod 0664
chgrp -R users /var/www
chmod 777 /var/www/dev/esp
chmod 666 /var/www/dev/esp/esp.sqlite

# fix module permissions
find /var/modules -type d -print0 | xargs -0 chmod 0775
find /var/modules -type f -print0 | xargs -0 chmod 0664
chgrp -R users /var/modules

# special module permissions
# ...this should really be in the module's install.sh, no?
chmod 777 /var/modules/en-file_share/uploads
chmod 777 /var/modules/es-file_share/uploads
chmod 775 /var/modules/*/finish_install.sh

# preview permissions (allow editing)
chmod 777 /var/www/rachelfriends/previews/rachelplus-*
chmod 666 /var/www/rachelfriends/previews/rachelplus-*/admin.sqlite
