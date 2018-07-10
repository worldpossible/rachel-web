#!/usr/bin/perl
use strict;
use warnings;

use O2G::Tools;

our ($r, $d, $t) = O2G::Tools->basics;
our $in = $r->param_hashref;

#-------------------------------------------
# main script logic right here
#-------------------------------------------

my $page_title = "Log In";
my $page_htmlf = "login.htmlf";

# we futz around with email so that it is prefilled in
# most cases as they navigate around
my $email = $r->html_escape($in->{email}||"");

if ($in->{login}) {
    # we're trying a login
    my $login_url = login();
    if ($login_url) {
        # it worked!
        $r->redirect($login_url);
        return;
    } else {
        $t->set_value( error => 1 );
    }

}

# everything ends up here eventually
$t->set_value({
    email       => ($in->{email} || O2G::Tools->cookie_data("user_email") || ""),
    page_title  => $page_title,
    page_htmlf  => $page_htmlf,

});

O2G::Tools->send_page();
return;

#-------------------------------------------
# support subs
#-------------------------------------------

sub login {

    my $user = $d->select_single(qq(
        SELECT * FROM users
         WHERE email = ?
           AND password = SHA1(CONCAT(?, salt))
    ), [ $in->{email}, $in->{password} ]);

    if (not $user) {
        return;
    }

    O2G::Tools->cookie_data( user_id => $user->{user_id} );
    O2G::Tools->cookie_data( first_name => $user->{first_name} );
    O2G::Tools->cookie_data( email => $user->{email} );
    O2G::Tools->send_cookie(); # XXX module should do this automatically

    return $in->{returnUrl} || "/";;

}

