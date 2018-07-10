#!/bin/bash

# backup existing, clear the way
rm -rf /var/modules/contentshell.prev
mv /var/modules/contentshell /var/modules/contentshell.prev

# specify a tag on the command line or it just gets the latest
if [[ ! -z $@ ]]; then release="--branch $@"; fi
git clone --depth=1 $release https://github.com/rachelproject/contentshell.git /var/modules/contentshell

# cleanup
rm -rf /var/modules/contentshell/.git
rm -rf /var/modules/contentshell/.gitignore
rm -rf /var/modules/contentshell/modules/.gitignore
