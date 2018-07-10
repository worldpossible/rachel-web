#!/usr/bin/perl
use strict;
use warnings;

my %nofile;
chdir("/var/modules");
foreach my $dir (`ls`) {
    chomp $dir;
    next if !-d $dir;
    if (-e "$dir/rachel-index.php") {
        my $cmd = "ln -sf rachel-index.php $dir/index.htmlf";
        print "$cmd\n";
        `$cmd`;
    } else {
        $nofile{$dir} = 1;
    }
}

foreach my $dir (keys %nofile) {
    print "No rachel-index.php in $dir\n";
}
