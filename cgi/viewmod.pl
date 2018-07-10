#!/usr/bin/perl
use strict;
use warnings;
use O2G::Tools;

my ($r, $d, $t) = O2G::Tools->basics();

O2G::Tools->jf_static_template_callback($t);

my $user_id = O2G::Tools->get_current_user();
if ($user_id and $user_id->{is_admin} eq "Yes") {
    $t->set_value( is_admin => 1 );
}

my $module = $d->select_single(qq(
    SELECT * FROM modules WHERE moddir = ? AND is_hidden = "No"
), [ $r->param("moddir") ]);

if (not $module) {
    # XXX this should be a 404
    $r->redirect("/");
    return;
}

# flesh out the module data (filesystem paths, etc.)
O2G::Tools->expand_module_data( $module );

$t->set_values($r->html_escape($module));
$t->set_values({
    page_title => $module->{title},
    page_htmlf => "viewmod.htmlf",
    page_script => "iframe_script.htmlf",
    returnUrl   => $r->unparsed_uri,
});

O2G::Tools->send_page();

