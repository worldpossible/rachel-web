#!/usr/bin/perl
use strict;
use warnings;
use O2G::Tools;

my ($r, $d, $t) = O2G::Tools->basics();

our $basedir = "/var//modules";

O2G::Tools->jf_static_template_callback($t);

my $user = O2G::Tools->get_current_user();
if ($user and $user->{is_admin} eq "Yes") {
    $t->set_value({ is_admin => 1 });
} else {
    $r->redirect("/sorry_permission.html");
    return;
}

# these are columns that don't need to be manually checked --
# either they're OK being whatever or they can be automatically fixed
my %skip_columns = map( { $_ => 1 } qw(
    module_id moddir lang ksize file_count type prereq_id prereq_note
    is_hidden version kiwix_url kiwix_date
));

my $columns = $d->select_multiple("DESC modules");

my $colcount = 0;
foreach my $col (@$columns) {
    next if $skip_columns{$col->{Field}};
    $colcount++;
}
$t->set_value( colcount => $colcount );

# this is one of the few places you can find hidden modules
my $modules = $d->select_multiple(qq(
    SELECT * FROM modules
     #WHERE is_hidden = "No"
     ORDER BY lang, title
));
O2G::Tools->expand_module_data($modules);

my $count = 0;
my $lastlang = "";
my %dbmods;
foreach my $mod (@$modules) {

    $dbmods{$mod->{moddir}} = 1;
    my $rloop = $t->get_loop("row");
    $rloop->set_value( link => "editmod.pl?module_id=$mod->{module_id}" );
    if ($mod->{is_hidden} eq "Yes") {
        $rloop->set_value( is_hidden => 1 );
    }

    # for each new language we put a language line
    if ($lastlang ne $mod->{lang}) {
        $rloop->set_value( new_lang => $mod->{langname} );
    }
    # and every 10 lines (or after a new language) we
    # put a column header line
    if ($count % 10 == 0 or $lastlang ne $mod->{lang}) {
        $rloop->set_value( header => 1 );
        foreach my $col (@$columns) {
            next if $skip_columns{$col->{Field}};
            my $hloop= $rloop->get_loop("header");
            $hloop->set_value( colname => $col->{Field} );
        }
    }
    ++$count;
    $lastlang = $mod->{lang};

    # here's where we display the module data
    foreach my $col (@$columns) {
        next if $skip_columns{$col->{Field}};
        my $cloop = $rloop->get_loop("column");
        if ($col->{Field} eq "title") {
            $cloop->set_value({
                text => "$mod->{title}<br>$mod->{moddir}",
                is_ok => 1
            });
        } else {
            $cloop->set_value( is_ok => is_ok( $col->{Field}, $mod ) );
        }
    }

}

# we don't report these as "no DB entry" because
# they're not modules... but it's nice to have them
# in the rsync directory
$dbmods{contentshell} = 1;
$dbmods{"extra-build-files"} = 1;

# show directories with no module info
foreach my $m (`ls -d $basedir/*/`) {
    $m =~ /\/([^\/]+)\/$/;
    next if $dbmods{$1};
    my $loop = $t->get_loop("fsonly");
    $loop->set_values( dir => $1 );
}

$t->set_values({
    page_title => "Check All Modules",
    page_htmlf => "checkallmods.htmlf",
});

O2G::Tools->send_page();

sub is_ok {

    my ($field, $mod) = @_;

    # we should do the following automated checks
    # - file permissions
    # - rachel-index.php
    # - zip file

    if ($field eq "logofilename") {
        return 0 if not $mod->{haslogo};
    } elsif ($field eq "is_hidden") {
        return ($mod->{$field} eq "No" ? 1 : 0);
    } elsif ($field eq "prereq_id" or $field eq "prereq_note") {
        return 1;
    }

    # if it's not handled above, it just needs to be defined
    if (not defined $mod->{$field} or $mod->{$field} eq "") {
        return 0;
    }

    return 1;

}
