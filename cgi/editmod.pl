#!/usr/bin/perl
use strict;
use warnings;
use O2G::Tools;
use Archive::Zip;

my ($r, $d, $t) = O2G::Tools->basics();

O2G::Tools->jf_static_template_callback($t);

my $user = O2G::Tools->get_current_user();
if ($user and $user->{is_admin} eq "Yes") {
    $t->set_value({
        is_admin => 1,
        editing => 1,
    });
} else {
    $r->redirect("/sorry_permission.html");
    return;
}

my $module_id = $r->param("module_id");

# we allow coming here via moddir, but we redirect to
# module_id since moddir can be changed and then things
# get really confusing
if (not $module_id) {
    if ($r->param("moddir")) {
        my $module = $d->select_single(qq(
            SELECT module_id FROM modules WHERE moddir = ?
        ), [ $r->param("moddir") ]);
        $r->redirect($r->uri . "?module_id=$module->{module_id}");
        return;
    }
    # no module_id *and* no moddir? get out.
    $r->redirect("/");
    return;
}

my %editable = map( { $_ => 1 } qw(
    title moddir lang
    ksize file_count
    description source_url
    type cc_license
    prereq_id prereq_note
    logofilename rating
    age_range category
    is_hidden version 
    kiwix_url kiwix_date
));

if ($r->param("zipmod")) {
    
    my $module = $d->select_single(qq(
        SELECT * FROM modules WHERE module_id = ?
    ), [ $module_id ]);
    
    my $moddir  = $module->{moddir};
    my $modpath = "/var/modules/" . $moddir;
    my $outPath = "/var/public_ftp/zipped-modules/" . $moddir . ".zip";

    if(-e $outPath){
        unlink($outPath);
    } 

    my $zip = Archive::Zip->new();
    $zip->addDirectory( $modpath );
    $zip->writeToFileNamed($outPath);
}

if ($r->param("delmod")) {
    $d->delete("modules", 
             { module_id => $r->param("module_id") });
}


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
            } else {
                $setclause->{$c} = $r->param($c);
            }
        }
    }
#    use Data::Dumper;
#    warn Dumper($setclause);
#    $d->warn_next_query();
    $d->update("modules", $setclause,
        { module_id => $r->param("module_id") }
    );
    $t->set_value( saved => 1 );
}

# we get the module down here because we want to get
# the *saved* version that we just updated
my $module = $d->select_single(qq(
        SELECT * FROM modules WHERE module_id = ?
), [ $module_id ]);

if (not $module) {
    # XXX this should be a 404
    $r->redirect("/");
    return;
}

O2G::Tools->expand_module_data( $module );

my $columns = $d->select_multiple("DESC modules");
foreach my $c (@$columns) {
    my $loop = $t->get_loop("columns");
    $loop->set_value({
        colname => $c->{Field},
        colval  => $r->html_escape($module->{$c->{Field}}),
        editable => $editable{$c->{Field}},
        is_ksize => ($c->{Field} eq "ksize"),
        is_file_count => ($c->{Field} eq "file_count"),
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
    }
        
}

$t->set_values($module);
$t->set_values({
    page_title => $module->{title},
    page_htmlf => "editmod.htmlf",
});

O2G::Tools->send_page();

