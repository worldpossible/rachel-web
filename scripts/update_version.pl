#!/usr/bin/perl
use strict;
use warnings;
use lib "../lib";
use O2G::Tools;

my $d = O2G::Tools->database();

my $modules = $d->select_multiple(
    "SELECT module_id, moddir, version FROM modules"
);

my $changed = 0;
foreach my $mod (@$modules) {
    my $version = `grep version /var/modules/$mod->{moddir}/rachel-index.php`;
    # XXX this regex should stay in sync with common.php in contentshell...
    ($version) = $version =~ /<!--\s*version\s*=\s*(?:"|')?([^"'\s]+?)(?:"|')?\s*-->/;

    if (not $version) {
        $version = "v0.0";
    }
    if ($mod->{version} and $version eq $mod->{version}) {
        next;
    }
    print "$mod->{moddir} updated to $version\n";
    $d->update("modules",
        { version => $version, },
        { module_id => $mod->{module_id} }
    );
    ++$changed;
}

print "$changed modules updated\n";
