#!/usr/bin/perl
use strict;
use warnings;
use lib "../lib";
use WP::Tools;

my $d = WP::Tools->database();

my $modules = $d->select_multiple(
    "SELECT module_id, moddir FROM modules WHERE is_hidden = 'No'"
);

foreach my $mod (@$modules) {
    print STDERR "Getting size of $mod->{moddir}... ";
    my $du = `/usr/bin/du -ks /var/www/dev/html/mods/$mod->{moddir}`;
    my ($ksize) = $du =~ /^(\d+)/;
    print STDERR "$ksize\n";
    print STDERR "Getting file count of $mod->{moddir}... ";
    my $file_count = `find /var/www/dev/html/mods/$mod->{moddir} -type f | wc -l`;
    chomp($file_count);
    print STDERR "$file_count\n";
    print STDERR "Updating DB for $mod->{moddir}\n\n";
    $d->update("modules",
        { ksize => $ksize, file_count => $file_count },
        { module_id => $mod->{module_id} }
    );
}

#print $ksize;
