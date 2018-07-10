package JF::UserCookie;

use strict;
use warnings;
use Carp;

use Digest::SHA qw(sha1_hex);

#-------------------------------------------
# stored globally
#-------------------------------------------
our ($r, $d, $t);

our (%COOKIE, $COOKIE_IS_DIRTY);
use constant COOKIE_NAME => "jfusercookie";
use constant COOKIE_KEY  => "7434E58A503C2BA33B3D15AEEBF73373";
use constant COOKIE_LAG  => "60";
use constant COOKIE_EXP  => { -expires => "+5y" };
use constant SHOW_COOKIE_ACTIVITY => 0;

#-------------------------------------------
# get or set cookie data
#-------------------------------------------
sub cookie_data {

    my $class = shift;
    my $key = shift;
    my ($has_val, $val);
    if (@_) { # this is so we can detect and use undefs
        $has_val = 1;
        $val = shift;
    }

    if (not %COOKIE) { # first time we've been called on this request

        my @cookie = $r->cookie(COOKIE_NAME); # supposed to be a hash but
                                               # might be undef
        if (not defined $cookie[0]) { # no cookie came in
            warn "No cookie\n" if SHOW_COOKIE_ACTIVITY;
        } else {
	    my %cookie = @cookie; # these hoops avoid an undef warning
            my $checksum = delete $cookie{checksum};
            my $chkstr = join("-", sort(%cookie, COOKIE_KEY));
            if (sha1_hex($chkstr) eq ($checksum||"")) {
                # it's verified good
                warn "Good cookie\n" if SHOW_COOKIE_ACTIVITY;
                %COOKIE = %cookie;
            } else {
                # it didn't verify, create a new one
                warn "Bad cookie: " . join(",", @cookie) if SHOW_COOKIE_ACTIVITY;
            }
        }

        # if the cookie is getting stale, update the time
        # in the cookie, and the database
        if (%COOKIE and time() > $COOKIE{time} + COOKIE_LAG) {
            $d->update("user",
                { last_seen_at => $d->now() },
                { user_id => $COOKIE{user_id} },
            );
            $COOKIE{time} = time();
            $COOKIE_IS_DIRTY = 1;
        }
    }

    if ($key) {

	if ($has_val) { # add the passed in key/value to the cookie
	    $COOKIE{$key} = $val;
            $COOKIE_IS_DIRTY = 1;
	}

        return $COOKIE{$key}; # no autoviv here with one-dim hashes

    }

    # we don't want the client accidentally messing
    # things up if they alter the data... if they want
    # to alter the data they have to call this function
    my %cookie_copy = %COOKIE;
    return \%cookie_copy;

}

#-------------------------------------------
# creates a new user in the database, and the initial cookie hash
#-------------------------------------------
sub new_user_id {
    my ($class, $r) = @_;
    my $user_id = $d->insert("user", {
        created_at => $d->now(),
        last_seen_at => $d->now(),
        ip => $r->connection->remote_ip,
    });
    $COOKIE{user_id} = $user_id;
    $COOKIE{time} = time();
    $COOKIE_IS_DIRTY = 1;
    warn "Prepping cookie for new user_id $user_id\n" if SHOW_COOKIE_ACTIVITY;
    return $user_id;
}

sub login_user_id {
    my ($class, $user_id) = @_;
    $d->update("user",
        { last_seen_at => $d->now() },
        { user_id => $user_id }
    );
    undef %COOKIE;
    $COOKIE{user_id} = $user_id;
    $COOKIE{time} = time();
    $COOKIE_IS_DIRTY = 1;
    warn "Prepping cookie for login user_id $user_id\n" if SHOW_COOKIE_ACTIVITY;
    send_cookie();
    return $user_id;
}

sub logout {
    my ($class, $user_id) = @_;
    %COOKIE = ();
    $r->cookie( COOKIE_NAME, {}, { -expires => "-1d" } );
}

sub get_current_user {
    my $user_id = OHP::Tools->cookie_data("user_id");
    if ($user_id) {
	return database()->select_single(qq(
	    SELECT * FROM user WHERE user_id = ?
	), [ $user_id ]); 
    }
    return undef;
}

sub send_cookie {
    # don't bother sending if it's just time
    if ($COOKIE{user_id} and $COOKIE_IS_DIRTY) {
        delete $COOKIE{checksum};
        $COOKIE{checksum} = sha1_hex(join("-", sort(%COOKIE, COOKIE_KEY)));
        $r->cookie( COOKIE_NAME, \%COOKIE, COOKIE_EXP );
        $COOKIE_IS_DIRTY = 0;
        warn "Actually sending cookie header\n" if SHOW_COOKIE_ACTIVITY;
    }
}

#-------------------------------------------
# cleanup handler, registered in httpd.conf
# -- this isn't strictly necessary as long as we do things
# right elsewhere, but it's a fair safety mechanism so that
# errors show up more loudly as an undef warning instead of
# just mysterious user swapping
#-------------------------------------------
sub handler {
    %COOKIE = ();
    ($r, $d, $t) = (undef, undef, undef);
}

1;
