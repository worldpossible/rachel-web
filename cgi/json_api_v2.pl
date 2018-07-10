#!/usr/bin/perl
use strict;
use warnings;
use O2G::Tools;
use JSON;

my ($r, $d, $t) = O2G::Tools->basics();

my $modules;

# You can pass in a module_id, moddir, or nothing (to get everything)
# Note1: we include NOT NULL to avoid returning bad data,
# which unfortunately has got  into the system at times
# and caused problems serious bugs for end users
# Note2: we used to include WHERE is_hidden = 'No'"
# but then once we hide a module we couldn't send updates,
# which might include things like moving them to a new
# version (name) of the module

if ($r->param("module_id")) {
    if ($r->param("module_id") =~ /^\d+$/) {
        $modules = $d->select_single(qq(
            SELECT *
              FROM modules
             WHERE module_id = ?
               AND moddir IS NOT NULL
        ), [ $r->param("module_id") ] );
    }
} elsif ($r->param("moddir")) {
    if ($r->param("moddir") =~ /^[a-z0-9\-\_\.]+$/) {
        $modules = $d->select_single(qq(
            SELECT *
              FROM modules
             WHERE moddir = ?
               AND moddir IS NOT NULL
        ), [ $r->param("moddir") ] );
    }
} else {
    # this may need to go away at some point when the collection
    # gets to big - for now we do allow getting all modules, but
    # only a small subset of the data for each
    my $rv = $d->select_multiple(qq(
        SELECT /* first the updatecheck components */
               moddir, ksize, file_count, version, is_hidden,
               /* then a few extra pieces that might help with display */
               module_id, title, lang, logofilename
          FROM modules
         WHERE moddir IS NOT NULL
    ));
    foreach my $mod (@$rv) {
        $modules->{ $mod->{moddir} } = $mod;
    }
}


$r->content_type("application/json; charset=utf-8");
# surprisingly (because of my ignorance) if you specify UTF8 to JSON,
# it corrupts some (but not all!) of the UTF8 characters
my $json = JSON->new; #->pretty(1)->canonical(1); # doubles run time
if ($modules) {
    print $json->encode($modules);
} else {
    print $json->encode({});
}

exit;
