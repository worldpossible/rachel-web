#!/usr/bin/perl
use strict;
use warnings;

my $basedir = "/var/modules";

my %sizes;
my $rv = `mysql -N -u root rachelmods -e 'select concat(moddir,"/",logofilename) from modules'`;
foreach my $file (split(/\n/, $rv)) {
    next if $file =~ /^concat/;
    print "'$file'\n";
    next if not -e "$basedir/$file";
    $sizes{$file} = -s "$basedir/$file";
}

foreach my $file ( sort({ $sizes{$a} <=> $sizes{$b} } keys %sizes) ) {
    my $size = sprintf("%.2fK", $sizes{$file} / 1024);
    print "$size\t $file\n";
}
