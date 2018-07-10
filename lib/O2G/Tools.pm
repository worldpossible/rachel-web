package O2G::Tools;
use strict;
use warnings;

use JF::ApacheRequest;
use JF::Database;
use JF::Template;

our ($r, $d, $t);

sub basics {
    return (request(), database(), template());
}

sub request { # always the master request object...
    if (not $r) {
        $r = JF::ApacheRequest->new;
    }
    return $r;
}

sub database { # always the master db connection...
    if (not $d) {
        $d = JF::Database->new("rachelmods", "", "");
    }
    return $d;
}

sub template { # always a new template...
    $t = JF::Template->new;
    $t->set_dir("/srv/www/oer2go/templates");
    return $t;
}

sub send_page {
    my ($pkg, $page) = @_;
    if (not $page) { $page = "oer2go.tmpl"; }
    $r->content_type("text/html");
    $r->print($t->parse_file($page));
}

#-------------------------------------------
# get or set cookie data
#-------------------------------------------
our (%COOKIE, $COOKIE_IS_DIRTY);
use constant COOKIE_NAME => "user_state";
use constant COOKIE_KEY  => "00000000000000000000000000000000";
use constant COOKIE_LAG  => "60";
use constant COOKIE_EXP  => { -expires => "+5y" };
use constant SHOW_COOKIE_ACTIVITY => 0;
use Digest::SHA qw(sha1_hex);
sub cookie_data {

    my $class = shift;
    my $key = shift;
    my ($has_val, $val);
    if (@_) { # this is so we can detect and use undefs
        $has_val = 1;
        $val = shift;
    }

    if (not %COOKIE) { # first time we've been called on this request

        # init the request object
        $class->request;

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
            #$d->update("user",
            #    { last_seen_at => $d->now() },
            #    { user_id => $COOKIE{user_id} },
            #);
            $COOKIE{time} = time();
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

sub logout {
    my ($class, $user_id) = @_;
    %COOKIE = ();
    $r->cookie( COOKIE_NAME, {}, { -expires => "-1d" } );
}

sub get_current_user {
    my $class = shift;
    my $user_id = $class->cookie_data("user_id");
    if ($user_id) {
        return database()->select_single(qq(
            SELECT * FROM users WHERE user_id = ?
        ), [ $user_id ]);
    }
    return undef;
}

sub send_cookie {
    # don't bother sending if it's just time
    if ($COOKIE{user_id} and $COOKIE_IS_DIRTY) {
        $COOKIE{time} = time();
        $COOKIE{checksum} = sha1_hex(join("-", sort(%COOKIE, COOKIE_KEY)));
        $r->cookie( COOKIE_NAME, \%COOKIE, COOKIE_EXP );
        $COOKIE_IS_DIRTY = 0;
        warn "Actually sending cookie header\n" if SHOW_COOKIE_ACTIVITY;
    }
}


sub jf_static_template_callback {
    my ($class, $t) = @_;
    my $cookie = $class->cookie_data;
    $t->set_value({
        user_id => $cookie->{user_id},
        user_first_name => $cookie->{first_name},
    });
}

# cleanup registered in httpd.conf
# -- if you don't register this, you get segfaults
sub handler {
    %COOKIE = ();
    ($r, $d, $t) = (undef, undef, undef);
}

# got the codes from:
#   select distinct lang from modules order by lang;
our %langname = (
    en => "English",
    es => "Spanish",
    pt => "Portuguese",
    fr => "French",
    hi => "Hindi",
    de => "German",
    ar => "Arabic",
    kn => "Kannada",
    multi => "Multilingual",
    id => "Indonesian",
);

our %stars = (
    0 => "zero",
    1 => "one",
    2 => "two",
    3 => "three",
    4 => "four",
    5 => "five",
);

our $modbase = "/var/modules";

# take an arrayref of modules and fill out the non-DB related stuff
sub expand_module_data {

    my ($class, $data) = @_;

    # if a singleton was passed in
    my $modules;
    if (ref($data) eq "ARRAY") {
        $modules = $data;
    } else {
        $modules = [ $data ];
    }

    foreach my $m (@$modules) {

        # this first set is used on the search results
        $m->{langname} = $langname{$m->{lang}};

        if ($m->{logofilename}
                and -e "$modbase/$m->{moddir}/$m->{logofilename}") {
            $m->{haslogo} = 1;
        }

        if (! -e "$modbase/$m->{moddir}/index.htmlf") {
            $m->{missing_htmlf} = 1;
        }

        # this is the text that the javascript search looks at
        # "lang" is the first two characters, so we don't need
        # that explicitly
        $m->{search_string} = join( " ",
            ($m->{moddir}||""),
            ($m->{langname}||""),
            ($m->{title}||""),
            ($m->{category}||""),
            ($m->{age_range}||"")
        );

        my ($whole, $half) = split(/\./, ($m->{rating}||"0.0"));
        $whole = $stars{$whole};
        $half = $half >= 5 ? " half" : "";
        $m->{star_class} = "$whole$half star"; 

        # this is used on the viewmod page (individual module)
        if (-r "$modbase/$m->{moddir}/rachel-index.php") {
            $m->{hasindexmod} = 1;
        }

        if (-r "/var/public_ftp/zipped-modules/$m->{moddir}.zip") {
            $m->{haszipfile} = 1;
        }

        $m->{gsize} = sprintf( "%.1f GB", ($m->{ksize}/1024)/1024);
        if ($m->{gsize} =~ /^0\.0/) {
            $m->{gsize} = "< 0.1 GB";
        }

        if ($m->{cc_license}) {
            my ($cc_code, $cc_ver) = $m->{cc_license} =~ /\(CC (\S+) (\d.\d)\)/;
            if ($cc_code and $cc_ver) {
                $cc_code = lc($cc_code);
                $m->{cc_link} = "https://creativecommons.org/licenses/$cc_code/$cc_ver/";
                $m->{cc_png} = "https://licensebuttons.net/l/$cc_code/$cc_ver/88x31.png";
            }
        }
        
    }

}

sub filter_moddir {
    my ($class, $moddir) = @_;
    $moddir =~ s/[^a-z0-9\-\_\.]//gi;
    return $moddir;
}

sub get_ksize {
    my ($class, $moddir) = @_;
    # don't trust the caller - sanitize again
    $moddir = $class->filter_moddir($moddir);
    my $du = `/usr/bin/du -ks /var/modules/$moddir`;
    my ($ksize) = $du =~ /^(\d+)/;
    return $ksize;
}

sub get_filecount {
    my ($class, $moddir) = @_;
    # don't trust the caller - sanitize again
    $moddir = $class->filter_moddir($moddir);
    my $find = `find /var/modules/$moddir -type f | wc -l`;
    my ($file_count) = $find =~ /^(\d+)/;
    return $file_count;
}

1;
