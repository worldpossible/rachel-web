#!/usr/bin/perl
use strict;
use warnings;
use O2G::Tools;

my ($r, $d, $t) = O2G::Tools->basics();

my $user = O2G::Tools->get_current_user();
if (not $user or $user->{is_admin} ne "Yes") {
    $r->redirect("/sorry_permission.html");
    return;
}

$r->content_type("text/plain");

my $module_id = $r->param("module_id");
exit if $module_id =~ /\D/;

my $mod = $d->select_single(
    "SELECT moddir FROM modules WHERE module_id = ?",
    [ $module_id ]
);
exit if not ($mod and $mod->{moddir});

print O2G::Tools->get_ksize($mod->{moddir});
