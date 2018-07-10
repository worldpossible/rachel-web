#!/usr/bin/perl
use strict;
use warnings;

my $moddir = "/var/modules";
my $zipdir = "/var/public_ftp/zipped-modules";

foreach my $mod (`ls $moddir`) {
    chomp $mod;
    next if !-d "$moddir/$mod";
    my $cmd = "zip -ru $zipdir/$mod.zip $moddir/$mod";
    print "$cmd\n";
    `$cmd`;
}
