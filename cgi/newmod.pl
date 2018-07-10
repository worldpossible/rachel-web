#!/usr/bin/perl
use strict;
use warnings;
use O2G::Tools;

my ($r, $d, $t) = O2G::Tools->basics();

our $basedir = "/var/modules";

O2G::Tools->jf_static_template_callback($t);

my $user = O2G::Tools->get_current_user();
if ($user and $user->{is_admin} eq "Yes") {
    $t->set_value({ is_admin => 1 });
} else {
    $r->redirect("/sorry_permission.html");
    return;
}

my $module_id = $r->param("module_id");

my %editable = map( { $_ => 1 } qw(
    title moddir lang
    description source_url
    type cc_license
    prereq_id prereq_note
    logofilename rating
    age_range category
));

if ($r->param("save")) {
    my $setclause;
    foreach my $c (keys %editable) {
        if (@{$r->multi_param($c)} > 1) {
            $setclause->{$c} = join ",", @{$r->multi_param($c)};
        } else {
            # to avoid putting junk in the prereq_id field, we check if
            # there's anything there defined but false, and make it NULL
            if ($c eq "prereq_id" and not $r->param($c) and defined $r->param($c)) {
                $setclause->{$c} = undef();
            } elsif ($c eq "moddir") {
                # we make use of this in filesystem calls and URLs
                $setclause->{$c} = O2G::Tools->filter_moddir($r->param($c));
            } else {
                $setclause->{$c} = $r->param($c);
            }
        }
    }

    # we make use of this in filesystem calls and URLs
    my $moddir = O2G::Tools->filter_moddir($r->param("moddir"));

    # calculate sizes XXX should we do this in a batch script later?
    $setclause->{ksize} = O2G::Tools->get_ksize( $moddir );
    $setclause->{file_count} = O2G::Tools->get_filecount( $moddir );

    my $module_id = $d->insert("modules", $setclause );
    $r->redirect("/viewmod/$moddir");
    return;
}

my $columns = $d->select_multiple("DESC modules");

my $module = $d->select_single(qq(
    SELECT * FROM modules WHERE module_id = ?
), [ $module_id ]);


foreach my $c (@$columns) {
    next if not $editable{ $c->{Field} };
    my $loop = $t->get_loop("columns");
    $loop->set_value({
        colname => $c->{Field},
        colval  => $r->html_escape($module->{$c->{Field}}),
        editable => $editable{$c->{Field}},
        is_ksize => ($c->{Field} eq "ksize"),
        textarea => ($c->{Type} eq "text"),
    });
    if ($c->{Type} =~ /^(set|enum)/) {
        $loop->set_value("selection" => 1);
        my %dbvals = ( ($module->{$c->{Field}}||"") => 1);
        if ($1 eq "set") {
            $loop->set_value( multiple => 1 );
            %dbvals = map { $_ => 1 } split /,/, ($module->{$c->{Field}}||"");
        }
        my $pvalcount = 0;
        foreach my $pval (split /,/, $c->{Type}) {
            $pval =~ s/^(enum|set)?\(?'//;
            $pval =~ s/'\)?$//;
            my $subloop = $loop->get_loop("pvals");
            $subloop->set_value( opt => $pval );
            if ($dbvals{ $pval||"" }) {
                $subloop->set_value( sel => 1 );
            }
            ++$pvalcount;
        }
        if ($c->{Type} =~ /^set/) {
            $loop->set_value( pvalcount => $pvalcount );
        }
    } elsif ($c->{Field} eq "moddir") {
        $loop->set_value("selection" => 1);
        my $dbmods = $d->select_multiple("SELECT moddir FROM modules");
        my %dbmods;
        foreach my $m (@$dbmods) {
            $dbmods{ $m->{moddir} } = 1;
        }
        foreach my $m (`ls -d $basedir/*/`) {
            $m =~ /\/([^\/]+)\/$/;
            next if $dbmods{$1};
            my $subloop = $loop->get_loop("pvals");
            $subloop->set_values( opt => $1 );
        }
    }
        
}

$t->set_values($module);
$t->set_values({
    page_title => "Add New Module",
    page_htmlf => "newmod.htmlf",
});

O2G::Tools->send_page();

