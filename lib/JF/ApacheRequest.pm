#-------------------------------------------
# Full documentation should be available
# at the command line via perldoc.  Please
# report any errors or omissions to the
# author.  Thank you.  And have a nice day.
#-------------------------------------------
package  JF::ApacheRequest;
	@JF::ApacheRequest::ISA = qw( Apache2::Request );

use strict;
use warnings;
if ($ENV{MOD_PERL}) {
    require Apache2::Request;
    require Apache2::Cookie;
    require Apache2::Upload;
}
use Apache2::Util;
use Apache2::RequestUtil;
use Apache2::Const qw(OK REDIRECT);

# so $r->connection->remote_ip works
use Apache2::Connection;

# so hacky! I can't find a way to store this in
# the request object and it doesn't subclass properly
# as described in the Apache2::Request docs (segfaults!) 
# so I just stuff this here. At the moment it's only used
# in one place, so it doesn't matter. And even if it is
# used in many places, it should get clobbered with the
# correct value on each requst. Sigh. 
our $COOKIE_SUB;

#-------------------------------------------
# this new enforces a single request object
# no matter how many times it's called during a request
#-------------------------------------------
sub new {
    my $class = shift;
    # this is apparently not good under threads -- we
    # are supposed to pass around the request object
    # (yuck).  there _are_ good uses for global
    # variables, you know :/
    return bless Apache2::Request->new(
        Apache2::RequestUtil->request, @_
    ), $class;
}

#-------------------------------------------
# this param is not sensitive to scalar and list
# context - it always returns a scalar: the first
# off the list if there are multiple values.
# if you want multiple values (as an arrayref)
# then you should call multi_param() below
#-------------------------------------------
sub param {
    my $self = shift;
    if (@_ == 1) {
        return scalar($self->SUPER::param(shift));
    }
    return $self->SUPER::param(@_);
}

#-------------------------------------------
# if a value is _supposed_ to have multiple
# items, you can get them here, always as an
# arrayref (even if there is one or none).
#-------------------------------------------
sub multi_param {
    my $self = shift;
    return [$self->SUPER::param($_[0])];
}

#-------------------------------------------
# if you want the params in a hash, this is
# where you can get them.
#-------------------------------------------
sub param_hashref {
    my %in;
    my $self = shift;
    foreach my $k ($self->param) {
	$in{$k} = scalar($self->SUPER::param($k));
    }
    return \%in;
}

#-------------------------------------------
# this upload call mimics the behavior of
# the param call -- sort of
#-------------------------------------------
sub upload {
    my $self = shift;
    if (@_) {
	my ($up, $fh);
	$up = $self->SUPER::upload(shift) || return undef;
	$fh = $up->fh || (return (undef, undef));
	local $/;
	return ($up->filename(), scalar(<$fh>));
    } else {
	my @upload;
	foreach my $up ($self->SUPER::upload) {
	    push @upload, $up->name;
	}
	return @upload;
    }
}

#-------------------------------------------
# passthrough to retrieve the more flexible Apache2::Upload object
#-------------------------------------------
sub upload_obj {
    my $class = shift;
    return $class->SUPER::upload(@_);
}

sub upload_hashref {
    my %in;
    my $self = shift;
    foreach my $k ($self->upload) {
	$in{$k} = $self->upload($k);
    }
    return \%in;
}

# a cookie function that acts like param
sub cookie {

    my ($self, $name, $value, $args) = @_;

    # I used to try to cache the cooke parse, but $self (as
    # inherited from Apache2::Request) isn't a hash, and the
    # seemingly workable $r->pnotes() would complain about arguments
    if (not defined $name) {
	my $cookies = Apache2::Cookie->fetch;
	return keys %{ $cookies };
    } elsif (not defined $value) {
	my $cookies = Apache2::Cookie->fetch;
	return $cookies->{$name}
	    ?  $cookies->{$name}->value : undef;
    } else {

	my $domain = $args->{-domain};
        # unless a domain is provided, or it's a dotted decimal IP
        # we strip off the subdomain here so the cookie works more
        # consistently
	if (not $domain) {
	    if ($ENV{SERVER_NAME} =~ /^\d+\.\d+\.\d+\.\d+$/) {
		$domain = $ENV{SERVER_NAME};
	    } else {
		($domain) = $ENV{SERVER_NAME} =~ /(\.[^\.]+\.[^\.]+)$/;
	    }
	}

	my $c = Apache2::Cookie->new(
	    $self,
	    -name    => $name,
	    -value   => $value,
	    $args->{-expires} ? (-expires => $args->{-expires}) : (),
	    -domain  => $domain,
	    -path    => ($args->{-path}||"/"),
	    $args->{-secure} ? (-secure => $args->{-secure}) : (),
	);

	$c->bake($self);
    }

}

sub cookie_hashref {
    my %in;
    my $self = shift;
    foreach my $k ($self->cookie) {
	$in{$k} = $self->cookie($k);
    }
    return \%in;
}

#-------------------------------------------
# do HTML escaping for a hashref, arrayref, or scalar
#-------------------------------------------
my %seen; # catch self refs
sub html_escape {

    my ($proto, $arg) = @_;

    if (ref $arg eq "HASH") {
        return if $seen{$arg};
        $seen{$arg} = 1;
	# make a copy so we don't clobber anything
	my $esc = {};
        foreach my $k (keys %$arg) {
	    if (defined $arg->{$k}) {
                if (ref($arg->{key})) {
                    $esc->{$k} = $proto->html_escape( $arg->{$k} );
                } else {
		    $esc->{$k} = $arg->{$k};
                    $esc->{$k} =~ s/&/&amp;/g;
                    $esc->{$k} =~ s/</&lt;/g;
                    $esc->{$k} =~ s/>/&gt;/g;
                }
	    } else {
		# we want "exists" to work the same before and after
	        $esc->{$k} = undef;
	    }
        }
        delete $seen{$arg};
	return $esc;
    } elsif (ref $arg eq "ARRAY") {
        return if $seen{$arg};
        $seen{$arg} = 1;
	# make a copy so we don't clobber anything
	my $esc = [];
        foreach my $v (@$arg) {
	    if (defined $v) {
                if (ref($v)) {
                    push @$esc, $proto->html_escape( $v );
                } else {
		    my $escv = $v;
                    $escv =~ s/&/&amp;/g;
                    $escv =~ s/</&lt;/g;
                    $escv =~ s/>/&gt;/g;
                    push @$esc, $escv;
                }
	    } else {
		# we don't want to lose undefined elements
		push @$esc, undef;
	    }
        }
        delete $seen{$arg};
	return $esc;
    } else {
	if (not defined $arg) {
	    return undef;
	} else {
	    my $esc = $arg;
            $esc =~ s/&/&amp;/g;
            $esc =~ s/</&lt;/g;
            $esc =~ s/>/&gt;/g;
            return $esc;
	}
    }

}

#-------------------------------------------
# do URL escaping for a hashref, arrayref, or scalar
#-------------------------------------------
sub url_encode {

    my ($proto, $arg) = @_;

    # Apache2::Util::escape_uri would be much faster than the
    # perl regex, but it doesn't nail all the weird characters
    # like ?, &, =, /, etc. which is what we usually want

    if (ref $arg eq "HASH") {
	my $esc = {};
        foreach my $k (keys %$arg) {
	    $esc->{$k} = $arg->{$k};
	    $esc->{$k} =~ s/ /+/g;
            $esc->{$k} =~ s/([^a-zA-Z0-9_.+-])/uc sprintf("%%%02x",ord($1))/eg;
        }
	return $esc;
    } elsif (ref $arg eq "ARRAY") {
	my $esc = [];
        foreach my $v (@$arg) {
	    $v =~ s/ /+/g;
            $v =~ s/([^a-zA-Z0-9_.+-])/uc sprintf("%%%02x",ord($1))/eg;
	    push @$esc, $v;
        }
	return $esc;
    } else {
	$arg =~ s/ /+/g;
	$arg =~ s/([^a-zA-Z0-9_.+-])/uc sprintf("%%%02x",ord($1))/eg;
	return $arg;
    }

}

sub url_decode {

    my ($proto, $arg) = @_;

    if (ref $arg eq "HASH") {
	my $esc = {};
        foreach my $k (keys %$arg) {
            $esc->{$k} = Apache2::Util::unescape_uri_info($arg->{$k});
        }
	return $esc;
    } elsif (ref $arg eq "ARRAY") {
	my $esc = [];
        foreach my $v (@$arg) {
            push @$esc, Apache2::Util::unescape_uri_info($v);
        }
	return $esc;
    } else {
        return Apache2::Util::unescape_uri_info($arg);
    }

}

# set a callback that will create a cookie or whatever
# before sending out a redirect or web page
sub cookie_sub {
    my $class = shift;
    $COOKIE_SUB = shift;
    return $COOKIE_SUB;
}

sub redirect {
    my ($self, $url) = @_;

    eval {
        &{$COOKIE_SUB} if ref($COOKIE_SUB) eq "CODE";;
	$self->status(REDIRECT); 
	$self->err_headers_out->add( Location => $url );
    };
    if ($@) {
        warn "JF::ApacheRequest::redirect() failed for $url : $@";
    }
    return REDIRECT;
}

# weird... by trying to be all cool and setting and returning
# the OK status it actually broke HEAD requests: a
# 500 server error would be returned _after_ we return
# from this sub and from the Registry module... so now
# we just keep it simple and let magic be magic
sub send_page {

    my ($self, $t, $file) = @_;

    eval {
        &{$COOKIE_SUB} if ref($COOKIE_SUB) eq "CODE";;
	$self->content_type("text/html");
	$self->print($t->parse_file($file));
    };
    if ($@) {
        warn "JF::ApacheRequest::send_page() failed for $file : $@";
    }

    return;

}


sub this_url {
    my $r = shift;
    my $url = $r->uri;
    if ($r->args) {
	$url .= "?" . $r->args;
    }
    return $url;
}

1;

=head1 NAME

JF::ApacheRequest - a more complete Apache2::Request object

=head1 SYNOPSIS

  use JF::ApacheRequest;

  my $r = JF::ApacheRequest->new;
  my $name   = $r->param("name");
  my $cookie = $r->cookie("auth");
  my $image  = $r->upload("image");

=head1 USAGE

For starters, this object inherits from Apache2::Request (which
inherits from Apache), so it does everything that either request
object can do.

There are a few differences and extras.  First, the differences:

JF::ApacheRequest->new() can be called without any arguments - it will
get the Apache2::Request itself.

A call to $r->param() is NOT context sensitive.  It never results in
multiple values or an empty list.  This is helpful in preventing unexpected
(and possibly insecure) behavior.  If there are multiple values, you get back
only the first.  If there were no values you get back undef.  To get an
arrayref of multiple values you must instead call $r->multi_param().  If
there were none you get back an empty arrayref.

Then we have several extra enhancements:

  # get uploads
  my @upload_names = $r->upload();
  my ($upload_filename, $upload_data) = $r->upload("image");

These work just like their $r->param() counterparts, although you can't set
values for an upload.

  # get cookies
  my @cookie_names = $r->cookie();
  my $cookie = $r->cookie("stuff");

  # set cookies
  $r->cookie("stuff", "12345");
  $r->cookie("mostuff", "67890",
      { -expires => "+1y", -path => "/cgi-bin/" }
  );

Works like $r->param().  You can set a cookie with just a name and
value. You can also pass in a hashref of the values you would pass to
Apache2::Cookie->new(), minus the -name and -value (which are the first
and second arguments instead).  If you don't pass a hashref, the default
will be different from Apache2::Cookie's default in two ways: the -path
will be set to "/" so the cookie will be returned to all URL's at your
site.  You can override this if you pass -path in the hashref.  The domain
will be stripped of it's subdomain (i.e. "www.foobar.com" and "dev.foobar.com"
both become "foobar.com")

  my $in = $r->param_hashref();
  my $up = $r->upload_hashref();
  my $ck = $r->cookie_hashref();

If you want the params, uploads, or cookies in a hashref, the above
functions is how you would get them.

  my $newstring   = JF::Request->html_escape( $string );
  my $newarrayref = JF::Request->html_escape( $arrayref );
  my $newhashref  = JF::Request->html_escape( $hashref );

  my $encoded = JF::Request->url_encode( $string );
  my $decoded = JF::Request->url_decode( $string );

These functions convert strings as expected.  They can also take arrayrefs
as an argument and will convert each element in the array, or if a hashref
is passed they will convert all the values (not the keys).

There's also $r->this_url which returns the server-relative url including
any query string arguments ... basically just a combination of $r->uri
and $r->query_string with enough smarts to leave off a trailing "?" if
there's no query string.

That's about it.

Oh yeah - one last conveniece.  A simple redirect method:

  return $r->redirect( $url );

=head1 NOTES

=head1 BUGS

=head1 DEPENDENCIES

  Apache2::Request, Apache2::Cookie, Apache2::Util

=head1 AUTHOR

Jonathan Field - jon@binadopta.com

