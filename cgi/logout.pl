#!/usr/bin/perl
use strict;
use warnings;

use O2G::Tools;

my $r = O2G::Tools->request;

#-------------------------------------------
# main script logic right here
#-------------------------------------------

O2G::Tools->logout;
$r->redirect("/");
return;

# that was easy...
