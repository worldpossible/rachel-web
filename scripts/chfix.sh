#!/bin/bash

# fix this directory's permissions
find . -type d -print0 | xargs -0 chmod 0775
find . -type f -print0 | xargs -0 chmod 0664
chgrp -R users .
