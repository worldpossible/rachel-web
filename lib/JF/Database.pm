#------------------------------------------
# Full documentation should be available
# at the command line via perldoc.  Please
# report any errors or omissions to the
# author.  Thank you.  And have a nice day.
#-------------------------------------------
package JF::Database;

use strict;
use warnings;
use Carp;
use DBI;
use Data::Dumper;

#-------------------------------------------
# When on, this will let you know when a query result
# set uses a lot of memory so you can rewrite using
# select_handle() if you want
#-------------------------------------------
use constant WARN_LARGE_RESULTS => 0;

#-------------------------------------------
# this makes more of the driver shared, by loading it
# at server startup (this file is in Startup.pm)
#-------------------------------------------
DBI->install_driver("mysql");

#-------------------------------------------
# DBD::mysql under OSX doesn't seem to support mysql_inserid?
# so we special case it with another query... since this is
# not so efficient, we use the DBD value on non-darwin systems
#-------------------------------------------
our $is_darwin;
BEGIN { $is_darwin = 1 if $^O =~ /darwin/i; }

#-------------------------------------------
# There's a few places we check that a query is 
# SELECT, or more generally, a READ.  So we centralize
# the regex here.
#-------------------------------------------
our $SELECT_REGEX = qr/^(?:select|show|explain|desc)/i;

#-------------------------------------------
# a cache for database handles
#-------------------------------------------
our $HANDLE_CACHE = {};

#-------------------------------------------
# pass in a database name, username and password
# and it returns a JF::Database object
#-------------------------------------------
sub new {

    my ($class, $db_name, $user, $pass) = @_;

    if (not ($db_name and $user and defined($pass))) {
        no warnings;
        croak "Missing database connection args"
            . " (db_name:$db_name, user:$user, pass:$pass)"
    }
    return bless({
        DB   => $db_name,
        USER => $user,
        PASS => $pass,
        ID   => "$db_name:$user:$pass",
    }, $class);

}

#-------------------------------------------
# sets this DB object to be read only... there's
# no unset method because then this read_only thing
# wouldn't be very strict now, would it?  Plus, you
# can always create another handle and not set this.
#-------------------------------------------
sub set_read_only {
    my $self = shift;
    $self->{READ_ONLY} = 1;
}

#-------------------------------------------
# These two functions allow you to change the behavior when
# a query error is encountered.  Normally you get a warning
# and things proceed normally.  If you set it to silent, you
# won't even get a warning.  If you set it to fatal, the error
# will trigger a die(), which you can then trap with an eval
# for special handling if you like.  In either case, it effects
# only the next query run: the flags are automatically reset
# after the next query.  Yes, this is a bit of a weird way to
# go about it, but you optimize (here for ease of usage)
# for the common case, right?  I thought so.
#-------------------------------------------
sub set_next_query_err_silent {
    my $self = shift;
    $self->{QUERY_ERR_SILENT} = 1;
}

sub set_next_query_err_fatal {
    my $self = shift;
    $self->{QUERY_ERR_FATAL} = 1;
}

#-------------------------------------------
# useful if you have some dynamic query construction
# going on, with lots of bind variables, and you just
# want to see what's really going to be sent to the DB
#-------------------------------------------
sub warn_next_query {
    my $self = shift;
    $self->{WARN_NEXT_QUERY} = 1;
}

#-------------------------------------------
# set an alternate DB if the original one fails
# on a connect or a ping.  This is useful if you're
# working with replicated databases, you can set
# a few extras in here, and they will be used if
# one goes down, providing a sort of hot failover.
# note that it won't detect it going down until
# it tries to connect or the next time it does a ping.
# For scripts this means each time the script is run.
# For mod_perl this means once on every request.
# You can set more than one, it's a FIFO stack.
#     NOTE: not implemented yet
#-------------------------------------------
sub set_alt_db {
    croak "set_alt_db() not implemented yet";
    my ($self, $db_name, $user, $pass) = @_;
    push @{$self->{ALT_DB}}, {
        DB   => $db_name,
        USER => $user,
        PASS => $pass,
        ID   => "$db_name:$user:$pass",
    };
}

#-------------------------------------------
# this returns a database handle from the cache if possible
#-------------------------------------------
sub get_db_handle {

    my $self = shift;

    #-------------------------------------------
    # If we don't have a handle in the cache we make one.
    # Otherwise we ping if needed (and refresh if needed),
    # then return the handle from the cache.  Since this
    # was written, DBI has added some kind of internal
    # caching mechanism, but I haven't tried it and this
    # seems to work quite well.
    #-------------------------------------------
    if (not $HANDLE_CACHE->{ $self->{ID} }) {
        $HANDLE_CACHE->{ $self->{ID} } = {
            HANDLE     => $self->_get_db_handle,
            NEEDS_PING => 0,
        };
    } elsif ($HANDLE_CACHE->{ $self->{ID} }{NEEDS_PING}) {
        my $dbh = $HANDLE_CACHE->{ $self->{ID} }{HANDLE};
        if (not $dbh or not $dbh->ping) {
            $HANDLE_CACHE->{ $self->{ID} }{HANDLE}->disconnect if $dbh;
            $HANDLE_CACHE->{ $self->{ID} } =  {
                HANDLE     => $self->_get_db_handle,
                NEEDS_PING => 0,
            };
        } else {
            $HANDLE_CACHE->{ $self->{ID} }{NEEDS_PING} = 0;
        }
    }

    return $HANDLE_CACHE->{ $self->{ID} }{HANDLE};

}

#-------------------------------------------
# this always returns a new handle
#-------------------------------------------
sub _get_db_handle {
    my $self = shift;
    my $dbh = DBI->connect(
        "dbi:mysql:$self->{DB}",
        $self->{USER},
        $self->{PASS},
        { PrintError => 0 }
    );
    if (not $dbh) {
        croak $DBI::errstr;
    }
    return $dbh;
}

#-------------------------------------------
# For performance research, it is sometimes useful
# to log all queries.  If you configure a filename,
# that's what the module will do.  Be careful, as
# this can create huge files quickly.  If you don't
# configure a filename, for some reason you have to
# set it to 0 and not as "" or perl complains.  Hmmm.
#-------------------------------------------
use constant QUERY_LOG_FILE => 0;
sub _log_query {

    my ($query, $args) = @_;

    if (open(QLOG, (">>".QUERY_LOG_FILE))) {

        my $logtxt = $query;
        $logtxt =~ s/\s+$//;
        $logtxt =~ s/(^|\n)/$1\t/g;
        $logtxt = "Run At " . localtime() . ":\n$logtxt\n";
        if ($args) {
            $logtxt .= "With Args:\n\t";
            $logtxt .= join(", ", map(($_ ? "'$_'" : "NULL"), @$args));
            $logtxt .= "\n";
        }

        # safe appending, straight from the perldocs
        flock QLOG, 2;
        seek  QLOG, 0, 2;
        print QLOG $logtxt;
        flock QLOG, 8;

    } else {

        warn "Can't log query: $!";

    }

}

#-------------------------------------------
# runs a query and returns what you want
#-------------------------------------------
sub query {

    my ($self, $query, $args) = @_;

    #-------------------------------------------
    # This resets the flags that control error reporting
    # behavior.  We do this right away so any early exit from
    # this sub doesn't leave these flags set for the next query.
    #-------------------------------------------
    my $query_err_silent = delete $self->{QUERY_ERR_SILENT};
    my $query_err_fatal  = delete $self->{QUERY_ERR_FATAL};
    my $warn_next_query  = delete $self->{WARN_NEXT_QUERY};

    #-------------------------------------------
    # Check we've got a query and valid args.
    # These are fatal because they should be easy
    # enough to detect during testing
    #-------------------------------------------
    croak "No Query Specified" if not $query;
    croak "Bad Args (must be arrayref): $args"
        if ($args and ref($args) ne "ARRAY");

    #-------------------------------------------
    # Strangely MySQL (or DBI) doesn't complain about mismatched
    # bind variables unless you pass at least one in
    #-------------------------------------------
    carp "Warning: 0 bind variables when some might be needed"
        if ((not $args) or (not @$args)) and $query =~ /\?/;

    #-------------------------------------------
    # we allow write-protecting the DB object
    # ...this is primarily intended to be used with replicated
    # databases where a write that would normally be fine
    # on the master would cause serious problems if run on a slave
    #-------------------------------------------
    $query =~ s/^\s+//;
    if ($self->{READ_ONLY} and $query !~ $SELECT_REGEX) {
        croak "Write attempt on read-only DB";
    }

    #-------------------------------------------
    # hacky way to determine what table they're writing to
    # ... used for the deadlock warnings
    #-------------------------------------------
    my ($table) = $query =~ /(?:update|into|from)\s+(\S+)/i;
    if ($table) {
        $table = "'$table'";
    } else {
        $table = "(unknown)";
    }

    my $dbh = $self->get_db_handle;
    my $sth = $dbh->prepare($query);

    _log_query($query, $args) if QUERY_LOG_FILE;

    _clean_warn(
        "You asked to see this:",
        $query, $args
    ) if $warn_next_query;

    #-------------------------------------------
    # if there's a deadlock we have to retry the transaction
    # we try to be gentle about it because it probably means
    # the DB table we're looking at is getting slammed
    #-------------------------------------------
    my $deadlock;
    my $maxtries = 5;

    #-------------------------------------------
    # We may have to do this a few times if we get a deadlock.
    # This could be a "while (1)" since we always "last", but
    # in the interest of protecting our children from accidental
    # introduction of infinite loops, I made it a foreach
    #-------------------------------------------
    foreach my $try (1..$maxtries) {

        #-------------------------------------------
        # We work with return values instead of doing an eval()
        # and relying on the RaiseError attribute.  This is
        # mainly to avoid the overhead of incurring an eval() on
        # every query.  Return values are a pain to do right, so
        # the eval() system usually makes sense, but since this is all
        # centralized it's easy to handle it right once.
        # Note how execute() returns various things: it usually returns
        # the number of rows, but it returns "0 but true" (perl's "0E0")
        # if there were no rows.  It returns undef if there was an
        # error in the query, and it even returns "-1" if the query was
        # killed while in progress!  So we detect success like so:
        #-------------------------------------------
        my $rv = $sth->execute(@{$args||[]});

        if ($rv and $rv >= 0) {

            #-------------------------------------------
            # Success!
            # Announce the resolution if this was a retry...
            # Then ditch the loop and we'll process the results below.
            #-------------------------------------------
            carp("DEADLOCK RESOLVED on try $try") if $deadlock;
            $deadlock = 0;
            last;

        } elsif ($DBI::errstr =~ /deadlock found/i) {

            #-------------------------------------------
            # The correct way to handle a deadlock is to try again.
            # We automate that here, with an exponential backoff
            # after each try.  We also give up after $maxtries.
            #-------------------------------------------
            carp("DEADLOCK on try $try");
            $deadlock = 1;

            # skip the sleep if that was our last try
            last if $try >= $maxtries;

            # longer sleep on each try
            sleep($try*$try);

        #-------------------------------------------
        # I once tried to handle dropped connections automatically,
        # thinking it would give us some hot-failover-like abilities.
        # Especially cool if you had several rep databases and could
        # shut one down and have everything switch over automatically.
        # This turned out to not be a great idea.  Though perhaps there
        # is a way to set it up properly.  The problem was that I couldn't
        # tell between a case where you should retry and a case where
        # you shouldn't.  Depending on whether you're talking to localhost
        # or the network, you might get "server shutdown" or "lost connection"
        # respectively, or even "server has gone away".  Anyways, these errors
        # could indicate several things, but you can't tell from the error.
        # So it is quite possible that the query was manually shot down,
        # in which case we should probably just bail, not retry.  I've also
        # seen a couple cases where a particular query causes a MySQL child
        # to exit (a bug in MySQL to be sure) but again, not something worth
        # throwing at the DB again.  In the end I've decided that
        # dropped connections should be a fatal error.  On the next
        # request we'll try to refresh the connection anyways.
        # Note that "lost connection" and "server shutdown" seem to take
        # place in the middle of an executing query.  Whereas "server has
        # gone away" seems to be if you try to execute on a dead database
        # handle.  This is all seperate from trying to open a new connection
        # to a dead database, for example.  Not sure what benefit we could
        # draw from that distinction, but perhaps worth noting.
        #-------------------------------------------
        } elsif ($DBI::errstr
                =~ /(?:lost connection|server shutdown|gone away)/i) {

            #-------------------------------------------
            # This usually means the query was manually killed
            # or the database itself was shut down.  We should bail
            # instead of retrying or even letting the script proceed.
            # This message doesn't have any blame attached, so we
            # don't need to work it over.  Just pass the blame
            # back to the caller... even though technically it's
            # not its fault either.
            #-------------------------------------------
            croak("DBD::mysql::st execute failed: ", $DBI::errstr);

        } else {

            #-------------------------------------------
            # We've got a non-fatal, non-recoverable error.
            # Normal behavior is to send out a warning indicating
            # the caller as the culprit.  But for flexibility we
            # offer two other behaviors here for advanced use.
            # search for QUERY_ERR in this file for more info
            #-------------------------------------------
            if ($query_err_fatal) {
                die $DBI::errstr;
            } elsif (not $query_err_silent) {
                _clean_warn(
                    "DBD::mysql::st execute failed: $DBI::errstr",
                    $query, $args
                );
            }

            #-------------------------------------------
            # it was determined that we should always send
            # back an arrayref, whether there were results,
            # no results, or even an error, as is the case here
            #-------------------------------------------
            if ($query =~ $SELECT_REGEX) {
                return [];
            } else {
                return undef;
            }

        }

    }

    #-------------------------------------------
    # This is one of but a very few fatal runtime 
    # errors that this module throws.  The rest should
    # be caught during basic testing.  But this seems
    # serious enough that I think a fatal error is appropriate.
    #-------------------------------------------
    if ($deadlock) {
        croak "FATAL DEADLOCK on after $maxtries tries";
    }

    #-------------------------------------------
    # Okay, we've just checked and handled everything we can
    # for the error cases, now we can handle success!
    # Different query types have different return values
    # and the logic tree below handles all that
    #-------------------------------------------

    if ($query =~ $SELECT_REGEX) {

        my @result;
        while (my $row = $sth->fetchrow_hashref) {
            push @result, $row;
        }

        #-------------------------------------------
        # We try to detect large result sets that might be better done with
        # select_handle()... if it's less than 1000 rows, don't worry.  If
        # it's more than that, check out the row size and calculate roughly
        # how much memory we're using.  Tell them if it's a lot.  In my
        # testing the below formula was usually in the ballpark.
        # Suggestions welcome.
        #-------------------------------------------
        if (WARN_LARGE_RESULTS and @result > 1000) {
            my $rows = @result;
            my $size = 0;
            foreach my $samp (1..10) {
                $size += length(Dumper($result[rand(@result)])) * 2;
            }
            $size  = sprintf("%.0f", $size/10 );
            my $mb = sprintf("%.1f", ($rows * $size)/1024/1024);
            if ($mb > 10) {
                my $msg = (
                    "Large result set (~${size}B x $rows rows = ~${mb}MB), "
                    . "consider using select_handle()"
                );
                _clean_warn( $msg, $query, $args );
            }
        }

        return \@result;

    #-------------------------------------------
    # INSERT returns the new primary key if there was one
    #-------------------------------------------
    } elsif ($query =~ /^insert/i) {

        return $dbh->{mysql_insertid} if not $is_darwin;
        return $self->_darwin_mysql_insertid($dbh);

    #-------------------------------------------
    # UPDATE returns the number of rows matched (not changed!)
    # DELETE the number of rows matched (not changed!)
    # REPLACE is a weird MySQLism that does either an
    # INSERT or a DELETE/INSERT if there's a duplicate unique
    # key.  It returns 1 on INSERT and 2 on DELETE/INSERT
    #-------------------------------------------
    } elsif ($query =~ /^(?:update|delete|replace)/i) {

        my $num_rows = $sth->rows;
        return $num_rows;

    #-------------------------------------------
    # The warning would be handled above
    # And create/drop temporary tables
    #-------------------------------------------
    } elsif ($query =~ m/^(?:create|drop|lock|unlock|set)/i) {
        return 1;
    }

    #-------------------------------------------
    # If we don't know what it was, we bail.
    #-------------------------------------------
    croak "Unknown query type: '" . substr($query, 0, 10) . "...'";

}

sub select_single {
    my ($self, $query, $args) = @_;
    croak "No Query Specified" if not $query;
    $query =~ s/^\s+//;
    if ($query !~ $SELECT_REGEX) {
        croak "select_single() can only take a SELECT";
    }
    my $result = $self->query($query, $args);
    return $result->[0]; # this very well may be undef
}

sub select_multiple {
    my ($self, $query, $args) = @_;
    croak "No Query Specified" if not $query;
    $query =~ s/^\s+//;
    if ($query !~ $SELECT_REGEX) {
        croak "select_multiple() can only take a SELECT";
    }
    return $self->query($query, $args);
}

#-------------------------------------------
# This is a concession to flexibility... though I'd like
# every query to go through the query() method above (where
# we can do better error handling and logging),
# there is the case of the extremely huge result set where you
# want to iterate through each row rather than preload
# the data into a huge datastructure.  So we provide
# this method that will give you a DBI statement handle
# with mysql_use_result turned on so you can fetchrow_hashref()
# to your heart's content without fear of running out of memory.
#-------------------------------------------
sub select_handle {
    my ($self, $query, $args) = @_;
    croak "No Query Specified" if not $query;
    $query =~ s/^\s+//;
    if ($query !~ $SELECT_REGEX) {
        croak "select_handle() can only take a SELECT";
    }
    my $dbh = $self->get_db_handle;
    my $sth = $dbh->prepare($query);
    $sth->{mysql_use_result} = 1;
    my $rv = $sth->execute(@{$args||[]});
    if ($rv and $rv >= 0) {
        return $sth;
    } else {
        _clean_warn(
            "DBD::mysql::st execute failed: $DBI::errstr",
            $query, $args
        );
        return undef;
    }

}

#-------------------------------------------
# a more code-friendly insert syntax
#-------------------------------------------
sub insert {

    my ($self, $table, $data) = @_;

    croak "Missing Arguments For insert()" if not ($table and $data);
    croak "Invalid Data For insert()" if ref $data ne "HASH";

    my (@columns, @values, @qmarks);
    foreach my $k (keys %$data) {
        push @columns, $k;
        push @values, $data->{$k};
        push @qmarks, "?"; 
    }

    return $self->query(
        "INSERT INTO $table (" . join(", ", @columns) .
        ") VALUES (" . join(", ", @qmarks) . ")",
        \@values
    );

}

#-------------------------------------------
# a more code-friendly replace syntax
#-------------------------------------------
sub replace {

    my ($self, $table, $data) = @_;

    croak "Missing Arguments For replace()" if not ($table and $data);
    croak "Invalid Data For replace()" if ref $data ne "HASH";

    my (@columns, @values, @qmarks);
    foreach my $k (keys %$data) {
        push @columns, $k;
        push @values, $data->{$k};
        push @qmarks, "?"; 
    }

    return $self->query(
        "REPLACE INTO $table (" . join(", ", @columns) .
        ") VALUES (" . join(", ", @qmarks) . ")",
        \@values
    );

}

#-------------------------------------------
# a more code-friendly update syntax
#-------------------------------------------
sub update {

    my ($self, $table, $data, $where) = @_;

    croak "Missing arguments for update()"
        if not ($table and $data and $where);
    croak "Invalid data for update()"
        if ref $data ne "HASH" or ref $where ne "HASH";

    my (@set_pairs, @values);
    foreach my $k (keys %$data) {
        push @set_pairs, "$k = ?";
        push @values, $data->{$k};
    }

    my @where_pairs;
    foreach my $k (keys %$where) {
        if (ref $where->{$k} eq "ARRAY") {
            push( @where_pairs,
                "$k IN (" . join(",", map({'?'} @{$where->{$k}})) . ")"
            );
            push @values, @{$where->{$k}};
        } else {
            push @where_pairs, "$k = ?";
            push @values, $where->{$k};
        }
    }

    return $self->query(
        "UPDATE $table SET " . join(", ", @set_pairs) .
        " WHERE " . join(" AND ", @where_pairs),
        \@values
    );

}

#-------------------------------------------
# a more code-friendly delete syntax
#-------------------------------------------
sub delete {

    my ($self, $table, $where) = @_;

    croak "Missing Arguments For Delete" if not ($table and $where);
    croak "Invalid Data For Delete" if ref $where ne "HASH";

    my (@where_pairs, @values);
    foreach my $k (keys %$where) {
        if (ref $where->{$k} eq "ARRAY") {
            push( @where_pairs,
                "$k IN (" . join(",", map({'?'} @{$where->{$k}})) . ")"
            );
            push @values, @{$where->{$k}};
        } else {
            push @where_pairs, "$k = ?";
            push @values, $where->{$k};
        }
    }

    return $self->query(
        "DELETE FROM $table" .
        " WHERE " . join(" AND ", @where_pairs),
        \@values
    );

}

sub _clean_warn {

    my ($err, $query, $args) = @_;

    #-------------------------------------------
    # does anyone else find this rambling MySQL message to
    # be more confusing than helpful?  I have endeavored to improve.
    #-------------------------------------------
    $err =~ s/ syntax; check the manual that corresponds to your MySQL server version for the right syntax to use//;

    #-------------------------------------------
    # First we give the DBI error, with the proper attribution
    #-------------------------------------------
    $err =~ s/ at .+? line \d+\.\n$//s;
    carp $err;

    #-------------------------------------------
    # Then we give a somewhat formatted version of the query
    # in question...
    #-------------------------------------------
    $query =~ s/\n\s*\n/\n/g;
    $query =~ s/(^|\n)/$1\t\t/g;
    chomp $query;
    my $extra_info = "\tOffending Query:\n$query\n";
    if ($args) {
        $args = join(", ", map(($_ ? "'$_'" : "NULL"), @$args));
        $extra_info .= "\tWith Args:\n\t\t$args\n";
    }

    print STDERR $extra_info;

}

#-------------------------------------------
# see above comment on OSX
#-------------------------------------------
sub _darwin_mysql_insertid {
    my ($self, $dbh) = @_;
    my $rv = $self->select_single( "SELECT LAST_INSERT_ID() AS id" );
    return $rv->{id};
}

#-------------------------------------------
# assuming you've set up a PerlCleanupHandler in your
# httpd.conf, this will mark all cached handles so they
# will be pinged before usage on the next request
#-------------------------------------------
sub handler {
    foreach my $c (values %$HANDLE_CACHE) {
        $c->{NEEDS_PING} = 1;
    }
}

#-------------------------------------------
# A SQL datetime since you can't easily insert
# or update a column with the sql function NOW()
#-------------------------------------------
sub now {
    my $self_or_class = shift;
    my $offset = shift || 0;
    my ($sec, $min, $hour, $mday, $mon, $year)
        = localtime( time() + $offset );
    return sprintf(
        "%.4d-%.2d-%.2d %.2d:%.2d:%.2d",
        ($year + 1900), ($mon + 1), $mday, $hour, $min, $sec
    );
}

#-------------------------------------------
# A SQL date since you can't easily insert
# or update a column with the sql CURRENT_DATE
#-------------------------------------------
sub today {
    return substr(now(@_), 0, 10);
}

#-------------------------------------------
# This will take an arrayref and return a formatted string
# suitable for putting in a query an IN (...) clause.
# You should put the result right into the query -- don't try
# doing it as a bind variable, because it's already quoted.
#-------------------------------------------
sub make_in_list {

    my ($self, $values) = @_;

    croak "must pass values to make_in_list() as arrayref"
        if ref $values ne "ARRAY";

    #-------------------------------------------
    # You've got to be kidding me... DBI requires connecting to the
    # database to quote strings?  DBI->quote doesn't work.  Well, we'll
    # most likely have to connect in a few cycles anyways...
    # But it means we can't offer this as a class method either :/
    #-------------------------------------------
    my $dbh = $self->get_db_handle;

    # this should work properly even if the list is empty
    return join(", ", map { $dbh->quote($_) } @{$values||[undef]} );

}

#-------------------------------------------
# This quotes a value for use in a query ... please don't
# use this unless you can't use bind variables for some reason.
#-------------------------------------------
sub quote {

    my ($self, $value) = @_;
    my $dbh = $self->get_db_handle;
    return $dbh->quote($value);

}

#-------------------------------------------
# this will gracefully disconnect all database handles
# in the cache when a script or server goes bye-bye
#-------------------------------------------
END {
    foreach my $c (values %$HANDLE_CACHE) {
        $c->{HANDLE}->disconnect;
    }
}

1;

=head1 NAME

JF::Database - A convenient DBI wrapper

=head1 SYNOPSIS

  use JF::Database;

  my $db = JF::Database->new( $dsn, $user, $pass );

  my $results = $db->query(
      "SELECT id, name FROM users WHERE name = ?",
      [ "Hortense" ]
  );

=head1 USAGE

JF::Database is a convenience wrapper around DBI that caches connections,
builds convenient result sets, auto-handles most deadlocks, and allows easier
building of queries with bind variables.

If you're using it under mod_perl you'll want to add a couple lines to
httpd.conf like so:

  PerlRequire                /path_to_modules/JF/Database.pm
  PerlCleanupHandler        JF::Database.pm

This will allow JF::Database to verifiy the connection is ready at the start
of each request.

To code with the module, first you'll want to get a JF::Database object:

  my $db = JF::Database->new( "db_name", "user", "pass" );

This doesn't actually connect to the database, it just gets ready
to.  Once you've got the object, there's only one other method you
really need to call: query(), which quite appropriately runs a query.

You must pass in a SQL string, and optionally an arrayref of bind
variables to plug into the query, like this:

  my $result = $db->query(
      "SELECT first_name FROM foo WHERE last_name = ?", [ "Smith" ]
  );

Different things are returned depending on the type of query.  For example,
if you do a SELECT, you will get back an arrayref of hashrefs: each row is
an array element, each hashref key is a column name.  So using $result from
the above example:

  print "The Smiths:\n";
  foreach my $row (@$result) {
      print  $row->{first_name} . "\n";
  }
  print @$result . " total\n";

A SELECT always results in an arrayref, even if there were no
results or the query had an error.

If you do an UPDATE or DELETE, the number of rows updated or
deleted is returned:

  my $num_rows_updated = $db->query(
      "UPDATE foo SET name = ? WHERE name = ?", [ $newname, $oldname ]
  );

  my $num_rows_deleted = $db->query(
      "DELETE FROM foo WHERE name = ?", [ $badname ]
  );

If you do an INSERT, the new primary key is returned, assuming there
is an auto_increment column on the table:

  my $foo_id = $db->query(
      "INSERT INTO foo (name) values (?)", [ $name ]
  );

Most errors result in just a warning, so a single failed query won't
cause a script to completely die.  The exceptions to this are connection
problems and unresolvable deadlocks.

There are several other convenience methods for running certain
types of queries with a more perl-friendly syntax:

  my $foo_id = $db->insert("table_name", {
      column1 => "foo",
      column2 => "bar",
  });

  my $num_rows_updated = $db->update( "table_name", {
      # set clause
      column1 => "foo",
      column2 => "bar",
  }, {
      # where clause
      column3 => "baz",
  });

Those methods are nice because you get to list the columns and
values in a nice perl hash instead of having to order them all into
a string and match up the question marks and the arguments.  There
is a delete() and replace() method that works exactly like insert().

Another convenience method is select_single() - pass a select
statement and get back a scalar: a hashref of the first row returned.
If there was no result you will get back undef.

There is also a select_multiple() for completeness, but it's exactly
the same result as calling query(), except it only takes a select.

$db->now() or JF::Database->now() will return the current datetime in
SQL format.  Useful for when you want to use SQL's own NOW() function,
but also want to use the $d->insert() and $d->update() which only work
with bind variables.

$db->today() or JF::Database->today() will return the current date
in SQL format.  It's just a truncated version of now().

$db->set_read_only() will make a database handle read only.  This is
useful for preventing mistakes with a replicated database.  It is
permanent for the object.  You have to make a new object to be able to
do a write.

$db->quote() will quote a single value so it's safe for use in a query.
But you shouldn't ever need to do this as you'll be using bind variables,
right?  This is only here for some rare (perhaps entirely theoretical) case
where you can't use bind variables and need to put the values into the
query string yourself.  Use bind variables!

$db->make_in_list() is kinda neat, it will correctly quote and concat
an arrayref of elemnts together so you can use them in an IN (...) clause,
which is a pain to do properly with bind variables.  For example:

  my $name_list = $db->make_in_list(["Filipe", "Umtupu", "'Ofa"]);
  my $results = $db->select_multiple(
      "SELECT age FROM people WHERE name IN ($name_list)"
  );

Hopefully that's easier and safer than doing it on your own.

$db->select_handle() is for very large result sets where memory usage
would become a problem.  You pass it a query and args, just like you
would with select_multiple(), however instead of getting back an arrayref
you get back a statement handle.  From there you can pull one row at
a time like so:

  my $sth = $db->select_handle("SELECT * FROM universe");

  if ($sth) {
      while (my $row = $sth->fetchrow_hashref) {
          print $row->{universal_id}, "\n";
      }
  }

The upside is that you can iterate through a billion rows without using
more than one row's worth of memory.  This is _only_ the case if you use
and discard the data one row at a time.  If you take each row from
select_handle() and put it into an array or something, then you're not saving
anything at all because, that's what select_multiple() does anyways.  But if
you know what you're doing, it can make for a nice power-user move.

Things to remember, though:

  1. You must check the return value of select_handle() because
     it might be undef if the query caused an error

  2. Don't waste too much time between calls to fetchrow_hashref()
     because MySQL is waiting for you... this is unbuffered

  3. If you don't go through all the rows, you should call
     $sth->finish() unless it's going out of scope immediately anyways

$db->set_next_query_err_silent() and $db->set_next_query_err_fatal() are
another a couple of advanced moves.

Let's say you want to run a query that might fail: for example, an insert that
might create a duplicate unique key.  The easiest/fastest thing is to just run
it and ignore if it fails.  But by default this module will spit out a warning
on you.  Well, if you call $db->set_next_query_err_silent() first it won't.
It's just for the very next query.  Behavior returns to normal after that.

Or let's say you want to check what the specific error was: you can call
$db->set_next_query_err_fatal() and the module will call die() instead of
warn().  The die() message will be $DBI::errstr, so you can then
eval and handle the exception any way you want.  Again, this only applies
to the very next query run.

Perhaps that seems a little odd, but I wanted to optimize for the common case
where you just want to run a query and you don't want everything to blow
up if there's a problem.  At least that's _my_ common case.  But there are a
few cases where you need to surpress warnings, or do exception handling, and
these methods allow you to do so without accidentally effecting other code.
Hopefully this system provides a good blend of convenience, safety, and
flexibility.

$db->warn_next_query() sets a flag that will send the next query to
stder. This is useful if the query and/or arguments were spliced together
dynamically and you just want to see what is actually going to the DB.

=head1 BUGS

=head1 NOTES

Yes, this wrapper is MySQL specific, but why would anyone want another
RDBM anyways ;)

If you don't want to have to pass in the db/user/pass info all over
the place, one can easily subclass JF::Database with a new() that knows
the info.  You can even build that into a static function that does
the connect and the query so that there's only one function to call.

=head1 DEPENDANCIES

DBI, DBD::mysql

=head1 AUTHOR

Jonathan Field - jon@binadopta.com

