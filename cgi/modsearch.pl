#!/usr/bin/perl
use strict;
use warnings;
use O2G::Tools;

# initialize some utility objects
our ($r, $d, $t) = O2G::Tools->basics();

# choose our template and set our page title
$t->set_value({
    page_title => "Module Search",
    page_htmlf => "modsearch.htmlf",
});

# fill in the stuff that's on every page
O2G::Tools->jf_static_template_callback($t);

# get our auth level
my $user_id = O2G::Tools->get_current_user();
if ($user_id and $user_id->{is_admin} eq "Yes") {
    $t->set_value( is_admin => 1 );
}

# get the modules from the DB
my $modules = $d->select_multiple(qq(
    SELECT * FROM modules
     WHERE is_hidden = "No"
     ORDER BY title
));

# flesh out the module data (filesystem paths, etc.)
O2G::Tools->expand_module_data( $modules );

# render the module data to the template
foreach my $m (@$modules) {
    my $mloop = $t->get_loop("modules");
    $mloop->set_values($m);
}    

# send out the HTML
O2G::Tools->send_page();
