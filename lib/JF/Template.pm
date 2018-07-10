#-------------------------------------------
# Full documentation should be available
# at the command line via perldoc.  Please
# report any errors or omissions to the
# author.  Thank you.  And have a nice day.
#-------------------------------------------
package JF::Template;

use strict;
use warnings;
use Carp;

#-------------------------------------------
# The token cache is a huge performance win, and it's
# smart enough to re-read modified files.  It uses a
# little extra memory, but is generally worth it.
# You can turn it off here if you don't like it.
#-------------------------------------------
our %TOKEN_CACHE;
use constant USE_TOKEN_CACHE => 1;

#-------------------------------------------
# When handling complex logic expressions, we use perl's
# eval mechanism... however this is fairly slow, so we
# cache the results.  See where we use this variable
# below for an explanation of how this works.
#-------------------------------------------
our %LOGIC_CACHE;

#-------------------------------------------
# a simple constructor makes for a simple module
#-------------------------------------------
sub new {
    my $self = bless [], shift;
    return $self;
}

#-------------------------------------------
# Why do we use an arrayref instead of a hashref for
# the basis of the object?  Because it's slightly faster,
# slightly lighter in memory, yet just as legible:
#
#   use constant VALUES => 1;
#   ...
#   $self->[VALUES];
#
# I did some tests.  First we'll look at speed:
#
# 150 iterations, no token caching:
#    HASH       : 17.63/sec
#    ARRAY      : 18.54/sec
#
# 150 iterations, with token caching
#    HASH       :  138.89/sec
#    ARRAY      :  147.06/sec
#
# Now let's look at memory.  Note there's the template object
# itself which can be a hash or an array, and then there's the
# tokens, which we've also made into arrays instead of hashes:
#
#                             RPRVT  RSHRD  RSIZE  VSIZE
#
#    HASH  Template objects   5.02M   368K  5.32M  27.7M
#    ARRAY Template objects   5.01M   368K  5.32M  27.7M
#
#    HASH  Tokens             6.92M   368K  7.18M  29.2M
#    ARRAY Tokens             6.45M   368K  6.71M  29.2M
#
# Not a big win, but I tried it to see how big it was, and since it's a little
# better, I'll keep it.  Can't think of a reason not to.
#-------------------------------------------
use constant VALUES => 0;
use constant LOOPS  => 1;
use constant DIR    => 2;
use constant TEMPLATE_RECORD => 3; # this is used to detect recursion
use constant TEMPLATE_FILE   => 4;

#-------------------------------------------
# used to occasionally check the distribution of tags
# in a file... counts how many times each type of token is seen
#-------------------------------------------
use constant SHOW_TOKENS_SEEN => 0;
our %SEEN;

#-------------------------------------------
# set_value takes variable arguments... either a single key/value pair,
# or a hashref with one or more key/value pairs.  Cryptically, I use array
# indexes to avoid giving names since I don't know what the arguments are
# yet. Much of the work is in giving helpful error messages.
# I think it's worth it.
#-------------------------------------------
sub set_value {

    my $self = shift;

    #-------------------------------------------
    # what is now found in @_:
    # 0 is either a hashref or a "key" (of a key value pair)
    # 1 is the "value" (or a mistake if 1 was a hashref)
    # 2 is always a mistake
    #-------------------------------------------

    #-------------------------------------------
    # a hashref is passed in
    #-------------------------------------------
    if (ref $_[0] eq "HASH") {

        foreach my $key (keys %{$_[0]}) {
            if (not defined $key or not length $key) {
                carp "Blank hashref key to set_value({}) ignored";
                return;
            }
            $self->[VALUES]{$key} = $_[0]->{$key};
        }

        if (exists $_[1]) {
            carp "Extra arguments to set_value() ignored after hashref";
        }

    #-------------------------------------------
    # a single key/value pair is passed in
    #-------------------------------------------
    } elsif (not ref $_[0]) {

        if (not defined $_[0] or not length $_[0]) {
            carp "Blank hash key to set_value() ignored";
            return;
        }

        $self->[VALUES]{$_[0]} = $_[1];

        if (exists $_[2]) {
            carp "Extra arguments to set_value() ignored after key/value";
        }

    #-------------------------------------------
    # some non-hash ref was passed in
    #-------------------------------------------
    } else {
        carp "Invalid arguments to set_value() ignored";

    }

}

#-------------------------------------------
# A loop iteration is really just another Template object, and that is how
# it is implemented -- that way it can easily have loops and values of
# it's own.  You pass in the loop name, an iteration is created, and it
# is pushed onto a stack and returned.
#-------------------------------------------
sub get_loop {

    my ($self, $loopname) = @_;

    my $class = ref $self;

    #-------------------------------------------
    # This used to be a regular call to new(), but when creating loops,
    # you don't need the initialization stuff that might be added there
    # (like we do at Zappos) because the loop takes on the environment of
    # their parent anyways during rendering.  If we used the existing new()
    # (and if it is customized to initialize some variables) then we'd
    # waste some time and memory copying all that to each loop iteration.
    # Though I suppose it could be faster on rendering if the loop doesn't
    # have to look up through the environment stack.  And that makes clear
    # the other reason not to use new() here: seemingly global values could
    # not be overridden from the top template object since they would be set
    # locally to each loop.  Anyways, that's the thought process that
    # went into this next line:
    #-------------------------------------------
    my $loop = bless [], $class;

    push @{$self->[LOOPS]{$loopname}}, $loop;

    return $loop;

}

#-------------------------------------------
# If there's no trailing slash on the dir the system should handle it
#-------------------------------------------
sub set_dir {
    my ($self, $dir) = @_;

    #-------------------------------------------
    # Used to try to detect bad directories, but it isn't worth it
    # since you can only do it for absolute paths, and it gets
    # complex with relative paths, which can switch out from under us...
    # So we just let the open() in _tokenize_file() do the work.
    #-------------------------------------------

    #-------------------------------------------
    # add the trailing if there isn't already one
    # ... unless it's blank!
    #-------------------------------------------
    $dir .= "/" if length($dir||"") and $dir !~ /\/$/;
    return $self->[DIR] = $dir;
}

#-------------------------------------------
# You can set the template file with this or you can
# pass in the filename when you call parse_file(),
# whichever makes the code easier to understand.
# Also, you can ignore set_dir() and just set the
# full path here if that makes things easier.
# If you don't set_dir() and you don't use an
# absolute path with set_template, it is undefined
# where the system will look - whatever it thinks
# is the current working directory.
#-------------------------------------------
sub set_template {
    my ($self, $file) = @_;
    return $self->[TEMPLATE_FILE] = $file;
}

#-------------------------------------------
# Give it a filename, and it will read the file, tokenize it,
# and render it.  It returns a string, suitable for printing,
# framing, bronzing, or anything else you can think of.
#-------------------------------------------
sub parse_file {

    my ($self, $file) = @_;

    # one might argue that there should only be one way to
    # set the template file, and one might be right...
    # if over the course of a few projects it seems that
    # it's always better to use the new set_template() call,
    # then we should deprecate the old syntax completely
    # and tidy this up

    if (not $file and not $self->[TEMPLATE_FILE]) {
        croak "No template file provided - use parse_file(\$file) or set_template(\$file) beforehand";
    } elsif ($file and $self->[TEMPLATE_FILE]) {
        carp "File passed to parse_file() when already set with set_template(); using $file";
    } elsif (not $file and $self->[TEMPLATE_FILE]) {
        $file = $self->[TEMPLATE_FILE];
    } else {
        # file is set and not TEMPLATE_FILE, which is fine
        # (and used to be the only way to do things)
    }

    #-------------------------------------------
    # we create an empty string and pass it in as a reference,
    # -- the internal sub will build it up without any copying, which
    # gets us a modest (~4%) performance gain.  Normally it would have
    # to do a copy with each recursive call (there can be quite a few).
    # Also should reduce memory usage, though I didn't test that.
    #-------------------------------------------
    my $final_output = "";

    if ($file !~ /^\//) {
        $file = ($self->[DIR]||"") . $file;
    }

    #-------------------------------------------
    # recursion detection would work even if we didn't do this,
    # but starting off right cuts down on needless error messages.
    #-------------------------------------------
    ++$self->[TEMPLATE_RECORD]{ $file };

    #-------------------------------------------
    # This right here is where it all happens.
    #-------------------------------------------
    $self->_render_tokens(
        $self->_tokenize_file( $file ),
        [], \$final_output
    );

    #-------------------------------------------
    # clear out the recursion stuff -- probably needless, but
    # we try to keep a clean house in case the template object
    # gets reused by the module user...
    #-------------------------------------------
    delete $self->[TEMPLATE_RECORD];

    if (SHOW_TOKENS_SEEN) {
        foreach my $k (sort {$SEEN{$b} <=> $SEEN{$a}} keys %SEEN) {
            warn "$k\t=> $SEEN{$k}\n";
        }
        warn "\n";
    }

    return $final_output;

}

#-------------------------------------------
# convenience... 
#-------------------------------------------
sub send_page {

    my ($t, $tmpl) = @_;
    # to try eliminating this error in the logs:
    #     "Apache2 IO flush: (103) Software caused connection abort"
    # we eval everything and basically ignore if there was a problem

    eval {
        my $r = JF::ApacheRequest->new;
        $r->send_http_header("text/html");
        $r->print( $t->parse_file($tmpl) );
    };
    if ($@) {
	warn "JF::Template::send_page() failed for $tmpl: $@";
    }

}

#-------------------------------------------
# each token is an arrayref -- here are the indexes
# of each part of the token
#-------------------------------------------
use constant COMMAND   => 0;
use constant ARGS      => 1;
use constant LINE      => 2;
use constant FILE      => 3;
use constant SUBTOKENS => 4;

#-------------------------------------------
# each command is mapped to a numerical
# constant so comparisions can be done more
# efficiently, and without all the hardcoded strings
#-------------------------------------------
use constant ROOT    => 0;
use constant IF      => 1;
use constant ELSIF   => 2;

use constant IF_OR_ELSIF => 2.5; # for comparision only

use constant ELSE    => 3;
use constant ENDIF   => 4;

use constant LOOP    => 5;
use constant ENDLOOP => 6;

use constant ECHO    => 7;
use constant SET     => 8;
use constant INCLUDE => 9;

use constant COMMENT => 10;
use constant ENDCOMMENT => 11;

use constant UNKNOWN => 12;

our %COMMAND_MAP = (
    root    => ROOT,
    if      => IF,
    elsif   => ELSIF,
    else    => ELSE,
    endif   => ENDIF,
    loop    => LOOP,
    endloop => ENDLOOP,
    echo    => ECHO,
    set     => SET,
    include => INCLUDE,
    comment => COMMENT,
    endcomment => ENDCOMMENT,
    unknown => UNKNOWN,
);

#-------------------------------------------
# Used internally -- opens a file, reads it, and turns it into
# tokens which then get passed to _render_tokens().
# We try to do as much error checking as we can at this
# stage to reduce the burden on _render_tokens() which gets
# called a lot more because it's recursive and also can't be cached.
#-------------------------------------------
sub _tokenize_file {

    my ($self, $filename, $incl_token) = @_;

    my $file_mod_time;
    if (USE_TOKEN_CACHE) {
        $file_mod_time = ((-M $filename)||0) * 86400;
        if ( $TOKEN_CACHE{$filename}
                and $TOKEN_CACHE{$filename}{file_mod_time} <= $file_mod_time) {
            return $TOKEN_CACHE{$filename}{tokens};
        }
    }

    if (not open TMPL, $filename) {
        if ($incl_token) {
            warn "Couldn't open template $filename: $! " .
                "at line $incl_token->[LINE] of $incl_token->[FILE]\n";
        } else {
            croak "Couldn't open template $filename: $!";
        }
        return [];
    }

    my $text_token = "";

    #-------------------------------------------
    # the goal here is to break up the file into easy to manage
    # tokens.  There are two types: text tokens, which are just flat
    # text scalars, and command tokens, which are arrayrefs containing:
    # [ $command, $args, $line, $filename [ subtokens ] ];
    #-------------------------------------------

    #-------------------------------------------
    # The "token" array itself is somewhat complex:
    # if a token can contain subtokens (if, elsif, else, loop),
    # then we collect those tokens.  Since the tokens can be
    # nested we use this as a stack: each element represents a
    # nesting level: an arrayref who's first element is a parent 
    # token, as described above, and whose second element is an arrayref
    # of subtokens.  When all is said and done, it should be a single
    # arrayref that contains all the top level tokens, with each token
    # containing it's own subtokens. Furthermore, since we don't
    # know whether the current token is the top level or a nested token,
    # we have to give the top token the same format as if it were
    # nested token - a "root" token in a sense, so we can push
    # tokens onto the fifth element of the arrayref (index 4)
    # like this:
    #-------------------------------------------
    my @tokens = [ ROOT, "", "root", $filename, []];

    #-------------------------------------------
    # we'll eliminate the "root" token after tokenizing.
    # here's an example of what the returned token arraref
    # should look like when we're done:
    #
    # [
    #     "plain text",
    #     [ IF  , "$foo", "2", "bar.html", [subtokens] ],
    #     [ ELSE, ""    , "3", "bar.html", [subtokens] ],
    #     "more plain text",
    #     [ LOOP, "$baz", "5", "bar.html", [subtokens] ],
    #     "even more plain text",
    # ];
    #
    # where "subtokens" are just more structures just like this.
    #-------------------------------------------

    #-------------------------------------------
    # The main reason we go by line instead of slurping the file is so
    # we can indicate the line number on warnings.  Testing indicates
    # that this is not a performance concern.
    #-------------------------------------------
    while (my $line = <TMPL>) {

        #-------------------------------------------
        # no template tag: optimize plain text lines
        # (yes, two regexes are faster than a regex "|")
        #-------------------------------------------
        if ($line !~ /<%/o and $line !~ /%>/o) {
            $text_token .= $line;
            next;
        }

        #-------------------------------------------
        # Remove whitespace from around lines where there's
        # no text or "echo" commands. Those letters capture
        # everything but an "echo".
        # I feel this results in cleaner, more intuitive output.
        #-------------------------------------------
        if ($line =~ /^(?:\s*<%\s*[ifelsndoptcum]+(?:\s+[^\%>]+)?\s*%>\s*)+$/) {
            $line =~ s/^\s+//g;
            $line =~ s/\s+$//g;
        }

        while ($line) {
            #-------------------------------------------
            # the /s modifier is important to keep from discarding
            # trailing newlines...
            #-------------------------------------------
            if ($line =~ /^(.*?)<%\s*([a-z]+?)(?:\s+(.*?))?\s*%>(.*)/s) {


                #-------------------------------------------
                # possible optimization: eliminate this copy;
                # -- or quit clobbering the line with end_text each time
                #-------------------------------------------
                my $start_text  = $text_token . $1;
                my $raw_command = $2;
                my $command     = ($COMMAND_MAP{$raw_command}||UNKNOWN);
                my $args        = $3;
                my $end_text    = $4;

                #-------------------------------------------
                # We have to clear out the backreferences like
                # this so the values don't get used below by any
                # failed pattern matches.  I wish there was a
                # better way, but we can't put the regex in its
                # own block because it _is_ the block.
                #-------------------------------------------
                "." =~ /./o;

                #-------------------------------------------
                # Text::Tmpl compatibility
                #-------------------------------------------
                if ($raw_command eq "ifn") {
                    $command = IF;
                    $args = "! $args";
                } elsif ($raw_command eq "endifn") {
                    $command = ENDIF;
                }

                #-------------------------------------------
                # deal with the preceding text first
                # - save away the text under the current token
                # (it's faster to concat text than to leave as seperate tokens)
                #-------------------------------------------
                push @{$tokens[0][SUBTOKENS]}, $start_text
                    unless $start_text eq "";

                #-------------------------------------------
                # create this token in all it's glory
                #-------------------------------------------
                my $token  = [ $command, $args, $., $filename ];

                if ($command == ECHO) {

                    $token->[ARGS] =~ /^\$([\w\.]+)$/;

                    #-------------------------------------------
                    # We don't need to even keep it if the arg is bad
                    #-------------------------------------------
                    if (not $1) {
                        warn "Invalid args to <\% echo \%> " .
                            "at line $token->[LINE] of $token->[FILE]\n";
                    } else {
                        #-------------------------------------------
                        # 1. replace the original arg with the clean one
                        # 2. put this command token in it's proper place
                        #-------------------------------------------
                        $token->[ARGS] = $1;
                        push @{$tokens[0][SUBTOKENS]}, $token ;
                    }

                } elsif ($command < IF_OR_ELSIF) {

                    #-------------------------------------------
                    # this is a common error for newbie users
                    #-------------------------------------------
                    if ($token->[ARGS] =~ /\b(?:and|or|not)\b/) {
                        warn "Invalid args to <\% $raw_command \%> " .
                            "( use '&& || !' instead of 'and or not' ) " .
                            "at line $token->[LINE] of $token->[FILE]\n";
                        $token->[ARGS] = ["0"];

                    #-------------------------------------------
                    # The common case is a single arg (and optional "!"),
                    # which we just pass along.  The advanced case is
                    # converted into an arrayref of punctuation and vars
                    #-------------------------------------------
                    } elsif ($token->[ARGS] !~ /^!?\s*\$[\w\.]+$/) {
                        #-------------------------------------------
                        # clean the args and break it into variables
                        # and punctuation: () ! && ||
                        #-------------------------------------------
                        $token->[ARGS] =~ s/[^\w\.\$\!\(\)\|\&]//g;
                        $token->[ARGS] = [ grep(
                            $_, split( /(\$[\w\.]+)/, ($token->[ARGS]||"") )
                        ) ];
                    }

                    #-------------------------------------------
                    # check the template is opening an elsif or else
                    # in a reasonable context
                    #-------------------------------------------
                    if ($command == IF) {

                        #-------------------------------------------
                        # 1. put this command token in it's proper place
                        # 2. start collecting subtokens under this token
                        #-------------------------------------------
                        push @{$tokens[0][SUBTOKENS]}, $token;
                        unshift @tokens, $token;

                    } else {

                        if (        $tokens[0][COMMAND] != IF
                                and $tokens[0][COMMAND] != ELSIF) {
                            warn "Malformed Template: " .
                                "<\% elsif \%> not inside <\% if \%> " .
                                "at $token->[LINE] of $token->[FILE]\n";
                        } else {

                            #-------------------------------------------
                            # 1. close the most recent subtoken stack
                            # 2. put this command token in it's proper place
                            # 3. open a new stack
                            #-------------------------------------------
                            shift @tokens;
                            push @{$tokens[0][SUBTOKENS]}, $token ;
                            unshift @tokens, $token ;
                        }

                    }

                } elsif ($command == ENDIF) {

                    #-------------------------------------------
                    # check the template is closing the right tag - worth
                    # doing now because it would be difficult to give an
                    # informative error later if too many tags are closed
                    #-------------------------------------------
                    if (    $tokens[0][COMMAND] != IF
                        and $tokens[0][COMMAND] != ELSE
                        and $tokens[0][COMMAND] != ELSIF
                    ) {
                        warn "Malformed Template: " .
                            "<\% endif \%> not inside <\% if \%> " .
                            "at $token->[LINE] of $token->[FILE]\n";
                    } else {

                        #-------------------------------------------
                        # just stop collecting under the current token -- we
                        # don't bother storing closing tokens since the
                        # subtokens are in an array we just fall off the end
                        # when rendering
                        #-------------------------------------------
                        shift @tokens;

                    }

                } elsif ($command == LOOP) {

                    $token->[ARGS] =~ /^"([\w\.]+)"$/;

                    #-------------------------------------------
                    # Even if the loop arg is bad, we need to put
                    # it on the stack so the later endloop will
                    # work... otherwise we'd get a fatal
                    # "Malformed Template" error
                    #-------------------------------------------
                    if (not $1) {
                        warn "Invalid args to <\% loop \%> " .
                            "at line $token->[LINE] of $token->[FILE]\n";
                        $token->[ARGS] = "";
                    } else {
                        #-------------------------------------------
                        # replace the original arg with the clean one
                        #-------------------------------------------
                        $token->[ARGS] = $1;
                    }

                    #-------------------------------------------
                    # 1. put this command token in it's proper place
                    # 2. start collecting subtokens under this token
                    #-------------------------------------------
                    push @{$tokens[0][SUBTOKENS]}, $token;
                    unshift @tokens, $token;

                } elsif ($command == ENDLOOP) {

                    #-------------------------------------------
                    # check the template is closing the right tag - worth
                    # doing now because it would be difficult to give an
                    # informative error later if too many tags are closed
                    #-------------------------------------------
                    if ($tokens[0][COMMAND] != LOOP) {
                        warn "Malformed Template: " .
                            "<\% endloop \%> not inside <\% loop \%> " .
                            "at $token->[LINE] of $token->[FILE]\n";
                    } else {

                        #-------------------------------------------
                        # we don't bother storing closing tokens - since
                        # the subtokens are in an array we just fall off the end
                        #-------------------------------------------
                        shift @tokens;
                    }

                } elsif ($command == ELSE) {

                    #-------------------------------------------
                    # check the template is opening an elsif or else
                    # in a reasonable context
                    #-------------------------------------------
                    if (    $tokens[0][COMMAND] != IF
                        and $tokens[0][COMMAND] != ELSIF) {
                        warn "Malformed Template: " .
                            "<\% else \%> not inside <\% if \%> " .
                            "at $token->[LINE] of $token->[FILE]\n";
                    } else {

                        #-------------------------------------------
                        # 1. close the most recent subtoken stack
                        # 2. put this command token in it's proper place
                        # 3. open a new stack
                        #-------------------------------------------
                        shift @tokens;
                        push @{$tokens[0][SUBTOKENS]}, $token ;
                        unshift @tokens, $token ;

                    }

                } elsif ($command == SET) {

                    $token->[ARGS] =~ /^"([\w\.]+)"\s*,\s*"(.*)"/;

                    #-------------------------------------------
                    # we can ignore it if the args are bad
                    #-------------------------------------------
                    if (not ($1 and defined $2)) {
                        warn "Invalid args to <\% set \%> " .
                            "at line $token->[LINE] of $token->[FILE]\n";
                    } else {
                        #-------------------------------------------
                        # 1. replace the original arg with the clean one
                        # 2. put this command token in it's proper place
                        #-------------------------------------------
                        $token->[ARGS] = [ $1, $2 ];
                        push @{$tokens[0][SUBTOKENS]}, $token ;
                    }

                } elsif ($command == INCLUDE) {

                    #-------------------------------------------
                    # is this safe enough?  This arg will be used
                    # in an open() command later... what damage can
                    # the template author do without spaces?
                    #-------------------------------------------
                    my @args = $token->[ARGS] =~ /("\S+"|\$[\w\.]+)/g;
                    foreach my $a (@args) {
                        $a =~ s/"//g;
                    }

                    #-------------------------------------------
                    # we can ignore it if the args are bad
                    #-------------------------------------------
                    if (not @args) {
                        warn "Invalid args to <\% include \%> " .
                            "at line $token->[LINE] of $token->[FILE]\n";
                    } else {
                        #-------------------------------------------
                        # 1. replace the original arg with the clean one
                        # 2. put this command token in it's proper place
                        #-------------------------------------------
                        $token->[ARGS] = \@args;
                        push @{$tokens[0][SUBTOKENS]}, $token ;
                    }

                } elsif ($command == COMMENT) {

                    #-------------------------------------------
                    # 1. put this command token in it's proper place
                    # 2. start collecting subtokens under this token
                    #-------------------------------------------
                    push @{$tokens[0][SUBTOKENS]}, $token;
                    unshift @tokens, $token;

                } elsif ($command == ENDCOMMENT) {

                    #-------------------------------------------
                    # check the template is closing the right tag - worth
                    # doing now because it would be difficult to give an
                    # informative error later if too many tags are closed
                    #-------------------------------------------
                    if ($tokens[0][COMMAND] != COMMENT) {
                        warn "Malformed Template: " .
                            "<\% endcomment \%> not inside <\% comment \%> " .
                            "at $token->[LINE] of $token->[FILE]\n";
                    } else {

                        #-------------------------------------------
                        # stop collecting under this token
                        #-------------------------------------------
                        shift @tokens;

                        #-------------------------------------------
                        # throw the whole thing away (yes, it's a bit
                        # of a waste to tokenize stuff that's not being
                        # used, but the tokenizing logic is robust wheras
                        # a hack to deal with comments as a special case is not.
                        #-------------------------------------------
                        pop @{$tokens[0][SUBTOKENS]};

                    }

                } else {

                    warn "Invalid template command <\% $raw_command \%> " .
                        "at line $token->[LINE] of $token->[FILE]\n";

                }

                $text_token = "";
                $line = $end_text;

            } else {

                #-------------------------------------------
                # this checks every line without a templating tag a second time
                # for possibly malformed templating tags
                # (yes, two regexes are faster than a regex "|")
                #-------------------------------------------
                if ($line =~ /<%/ or $line =~ /%>/) {
                    warn "Template Warning: possible incomplete tag " .
                        "at line $. of $filename\n";
                }

                $text_token .= $line;

                $line = "";

            }

        }

    }

    #-------------------------------------------
    # take care of any remaining text
    #-------------------------------------------
    push @{$tokens[0][SUBTOKENS]}, $text_token unless $text_token eq "";

    close TMPL;

    #-------------------------------------------
    # check that we closed all the opening tags
    #-------------------------------------------
    while (@tokens > 1) {
        my $token = shift @tokens;
        # note this will show "if" as the command even if it was
        # really "ifn"...
        my %command_unmap = reverse %COMMAND_MAP;
        my $command = $command_unmap{$token->[COMMAND]};
        warn "Malformed Template: unclosed tag <\% $command \%> " .
            "at $token->[LINE] of $token->[FILE]\n";
    }

    #-------------------------------------------
    # check that we haven't totally buggered things up
    #-------------------------------------------
    if ($tokens[0][COMMAND] != ROOT) {
        die "Internal templating error (1) while parsing $filename\n";
    }

    #-------------------------------------------
    # check that we got any tokens at all
    #-------------------------------------------
    if (not @{$tokens[0][SUBTOKENS]}) {
        warn "No tokens (file empty?) while parsing $filename\n";
        return [];
    }

    #-------------------------------------------
    # cache and return the contents of the root token
    # (not the root token itself)
    #-------------------------------------------
    if (USE_TOKEN_CACHE) {
        $TOKEN_CACHE{$filename}{tokens} = $tokens[0][SUBTOKENS];
        $TOKEN_CACHE{$filename}{file_mod_time} = $file_mod_time;
    }

    return  $tokens[0][SUBTOKENS];

}

#-------------------------------------------
# used internally -- this takes an arrayref of tokens (as
# created by _tokenize_file) and it renders them to a string
# -- you must also pass in an env_stack which is just an empty
# array on the first call, but becomes populated when the sub
# calls itself recursively in a loop.  And you must pass in
# a blank scalar reference so it can build the final string up
# without having to copy it around so much.
#-------------------------------------------
sub _render_tokens {

    #-------------------------------------------
    # We may call ourselves recursively if we're
    # going to render a loop, for example - in that
    # case we'll get the environment passed in by our parent.
    # We'll also get a copy of the root template object,
    # which we need for looking up the set directory (we
    # may do an include inside a loop and we don't want
    # every loop to have to have a copy of the directory)
    #-------------------------------------------
    my ($self, $tokens, $env_stack, $final_output, $root_self) = @_;

    #-------------------------------------------
    # this lets us handle the if/elsif/else logic by
    # telling us to skip sections if already handled
    #-------------------------------------------
    my $logic_mask = 0;

    foreach my $token (@$tokens) {

        if (not ref $token) {
            ++$SEEN{text} if SHOW_TOKENS_SEEN;
            # just text
            $$final_output .= $token;
            next;
        }

        my ($command, $args)  = @$token;

        #-------------------------------------------
        # no pretense of being extendable... this is just
        # pure hardcoded goodness from years of using templates
        # - you can thank me for the speed later...
        #-------------------------------------------
        if ($command == ECHO) {
            ++$SEEN{echo} if SHOW_TOKENS_SEEN;
            $logic_mask = 0;

            #-------------------------------------------
            # this check seems to be only for debugging the templating library
            #-------------------------------------------
            if ($token->[SUBTOKENS]) {
                die "Internal templating error (2) " .
                    "at line $token->[LINE] of $token->[FILE]\n";
            }

            # look through the stack for this variable
            foreach my $env ($self, @{$env_stack||[]}) {
                if (exists $env->[VALUES]{$args}) {
                    $$final_output .= $env->[VALUES]{$args}
                        unless not defined $env->[VALUES]{$args};
                    last;
                }
            }

        } elsif ($command < IF_OR_ELSIF) {

            #-------------------------------------------
            # slightly different handling for these two, either:
            # 1. consider this a new logic set
            # 2. skip if we've already handled this logic set
            #-------------------------------------------
            my $token_type;
            if ($command == IF) {
                ++$SEEN{if} if SHOW_TOKENS_SEEN;
                $logic_mask = 0;
                $token_type = "if";
            } else {
                ++$SEEN{elsif} if SHOW_TOKENS_SEEN;
                next if $logic_mask;
                $token_type = "elsif";
            }

            #-------------------------------------------
            # This determines if it's a complex expression:
            # the tokenizer puts complex expressions into an array.
            # We have to do quite a bit of work in that case.
            #-------------------------------------------
            if (ref $args) {

                #-------------------------------------------
                # I tried doing the whole variable interpolation thing
                # using s///eg, but this turns out this is slightly faster:
                #   s///eg         52.03/s
                #   this method    53.48/s
                #-------------------------------------------
                my $argstring = "";

                #-------------------------------------------
                # now we go through the args, and replace each of the
                # variables with a "0" or "1", based on it's perl-truth,
                # plus we cat them together into an evalable string
                #-------------------------------------------
                foreach my $argchunk (@$args) {

                    #-------------------------------------------
                    # skip anything that's not a variable (i.e. punctuation)
                    #-------------------------------------------
                    if ($argchunk =~ /^\$([\w\.]+)$/) {
                        #-------------------------------------------
                        # assume false: we still want to replace it with
                        # something if we don't find anything in the
                        # environment. Then go through the evironment stack
                        # until we find a defined value or run out of
                        # environments
                        #-------------------------------------------
                        my $val = 0;
                        foreach my $env ($self, @{$env_stack||[]}) {
                            if (exists $env->[VALUES]{$1}) {
                                    # use perl's sense of truth
                                $val = $env->[VALUES]{$1} ? 1 : 0;
                                last;
                            }
                        }
                        $argstring .= $val;

                    } else {
                        $argstring .= $argchunk;
                    }

                }

                #-------------------------------------------
                # So now we've got a complex expression consisting of just
                # ones, zeros, and punctuation.  We're gonna let perl figure it
                # out for us.  However, we will cache the results.  The
                # argstring is something like "(0||1)", which we can use as a
                # hash key to store the results in a hash.  This lets us skip
                # the eval for any pattern we've seen before.  Tests indicate
                # a 60% speed increase over the eval in the best case: if
                # you've got a lot of complex expressions inside loops, for
                # example.  In the worst case it uses a miniscule amount of
                # extra memory and performs about as well.  Also, in addition
                # to the result of expression, we have to capture any eval
                # errors caused by a malformed token.  Here we go:
                #-------------------------------------------
                if (not exists $LOGIC_CACHE{$argstring}) {
                    no warnings; # if they 
                    $LOGIC_CACHE{$argstring}[0] = eval $argstring;
                    $LOGIC_CACHE{$argstring}[1] = $@;
                } 
                $logic_mask = $LOGIC_CACHE{$argstring}[0];

                #-------------------------------------------
                # Alert them if their args caused an error during eval()
                # (since we guarantee only 0 or 1 replacements,
                # perhaps this check can be moved to tokenizing?)
                #-------------------------------------------
                if ($LOGIC_CACHE{$argstring}[1]) {
                    my $errmsg = $LOGIC_CACHE{$argstring}[1];
                    chomp($errmsg);
                    warn "Invalid args to <\% $token_type \%> ($errmsg) " .
                        "at line $token->[LINE] of $token->[FILE]\n";
                }

            #-------------------------------------------
            # If it's not a complex expression, we can handle it
            # without an eval
            #-------------------------------------------
            } else {
                # pull out the stuff
                my ($neg, $arg) = $args =~ /^(!?)\s*\$([\w\.]+)/;
                $logic_mask = 0;
                foreach my $env ($self, @{$env_stack||[]}) {
                    if (exists $env->[VALUES]{$arg}) {
                        # use perl's sense of truth
                        $logic_mask = $env->[VALUES]{$arg} ? 1 : 0;
                        last;
                    }
                }
                $logic_mask = not $logic_mask if $neg;
            }

            #-------------------------------------------
            # Now we have determined the final truthfulness/falsehood
            # of the arguments, taking into account all the variables
            # as defined by all the environments.  Now we can decide
            # whether to render the subtokens or not
            #-------------------------------------------
            $self->_render_tokens(
                $token->[SUBTOKENS], $env_stack, $final_output,
                ($root_self||$self)
            ) if $logic_mask;

        } elsif ($command == ELSE) {
            ++$SEEN{else} if SHOW_TOKENS_SEEN;

            #-------------------------------------------
            # skip if this logic set has already been handled
            #-------------------------------------------
            next if $logic_mask;

            #-------------------------------------------
            # simple - just render all the tokens if
            # we've not already been masked
            #-------------------------------------------
            $self->_render_tokens(
                $token->[SUBTOKENS], $env_stack, $final_output,
                ($root_self||$self)
            );

        } elsif ($command == LOOP) {

            ++$SEEN{loop} if SHOW_TOKENS_SEEN;

            $logic_mask = 0;
                
            # look through the stack for this loop
            foreach my $env ($self, @{$env_stack||[]}) {
                if (exists $env->[LOOPS]{$args}) {
                    # once found we iterate through the loop
                    foreach my $loop (@{$env->[LOOPS]{$args}}) {
                        $loop->_render_tokens(
                            $token->[SUBTOKENS], [ $self, @$env_stack ],
                            $final_output, ($root_self||$self)
                        );
                    }
                    # we found a valid loop - no need to search further
                    last;
                }
            }
                
        } elsif ($command == INCLUDE) {
            ++$SEEN{include} if SHOW_TOKENS_SEEN;

            $logic_mask = 0;

            my $filename = "";
            foreach my $a (@$args) {
                if ($a =~ /^\$([\w\.]+)$/) {
                    my $val = "";
                    foreach my $env ($self, @{$env_stack||[]}) {
                        if (exists $env->[VALUES]{$1}) {
                            $val = $env->[VALUES]{$1};
                            last;
                        }
                    }
                    $filename .= $val;
                } else {
                    $filename .= $a;
                }
            }

            $filename = (($root_self||$self)->[DIR]||"") .  $filename;

            if ($self->[TEMPLATE_RECORD]{ $filename }++) {
                warn "Recursive <\% include \%>: $filename " .
                    "at line $token->[LINE] of $token->[FILE]\n";
            } else {

                $self->_render_tokens(
                    $self->_tokenize_file( $filename, $token ),
                    $env_stack, $final_output, ($root_self||$self)
                );
    
                $self->[TEMPLATE_RECORD]{ $filename } = 0;

            }

        } elsif ($command == SET) {
            ++$SEEN{set} if SHOW_TOKENS_SEEN;

            $logic_mask = 0;
            $self->[VALUES]{ $args->[0] } = $args->[1];

        } else {

            warn "Bad Token got through: $command";

        }
                
    }

    # we don't return anything, we work on a reference...
    # this avoids some extra copying and provides a modest performance gain

}

#-------------------------------------------
# Convenience methods
#-------------------------------------------

#-------------------------------------------
# export an arrayref of hashrefs to the template -
# in other words, the data structure that is usually
# returned from the DB
#-------------------------------------------
sub export_loop {
    my ($self, $loop_name, $data) = @_;
    if ( $loop_name and $data and @$data ) {
        foreach my $val (@$data) {
            my $loop = $self->loop_iteration($loop_name);
            $loop->export_hashref($val);
        }
    }
}

#-------------------------------------------
# export a hashref with arbitrary contents.
# catches recursive self-references.
#-------------------------------------------
sub export_hashref {
    my ($self, $data) = @_;
    if ($data and ref $data eq "HASH") {
        my $seen = { $data => ref $data };
        foreach my $key (sort keys %$data) {
            _export_helper($key, $data->{$key}, $self, $seen);
        }
    }
}

#-------------------------------------------
# this function will export any data structure
# you throw at it into the template
#-------------------------------------------
sub _export_helper {

    my ($key, $val, $t, $seen, $whence) = @_;

    $seen = {} unless $seen;

    if ( ref $val eq "HASH" and not $seen->{$val} ) {
        $seen->{$val} = ref $val;
        my $u = ($whence) ? $t : $t->loop_iteration($key);
        foreach my $sv ( sort keys %$val ) {
            _export_helper($key, $val->{$key}, $u, $seen);
        }
    } elsif ( ref $val eq 'ARRAY' and not $seen->{$val} ) {
        $seen->{$val} = ref $val;
        foreach my $data (@$val) {
            my $u = $t->loop_iteration($key);
            _export_helper($key, $data, $u, $seen, 1);
        }
    } else {
        $t->set_value($key, $val);
    }

}

#-------------------------------------------
# Duplicated from JF::ApacheRequest, but recent
# projects convinced me this is worth having in
# here when building stuff offline
#-------------------------------------------
sub html_escape {
    my $string = shift;
    $string =~ s/\&/&amp;/g;
    $string =~ s/\"/&quot;/g;
    $string =~ s/\</&lt;/g;
    $string =~ s/\>/&gt;/g;
    return $string;
}

#-------------------------------------------
# Text::Tmpl compatibility
#-------------------------------------------
sub set_values {
    goto &set_value;
} 

sub loop_iteration {
    goto &get_loop;
} 

sub handler { }
sub destroy { }
sub set_strip { }

1;

=head1 NAME

JF::Template - pure perl replacement for Text::Tmpl

=head1 SYNOPSIS

  use JF::Template;

  my $t = JF::Template->new;

  $t->set_value( name => "Jonathan");

  $t->set_value({
      one => 1,
      two => 2,
  });

  foreach my $l (qw(a b c d)) {
      my $loop = $t->get_loop("letters");
      $loop->set_value( letter => $l );
  }

  $t->set_dir( "/home/jfield/templates" );

  print $t->parse_file( "foo.html" );

=head1 USAGE

I've written the usage documentation from two angles: usage for people
who never used this stuff before, and usage for people who know Text::Tmpl,
which this module is more-or-less compatible with.  Here we go...

=head2 Usage For Newbies

Working on it... for now go read the Text::Tmpl docs, then the section below.

=head2 Usage For Text::Tmpl Users

If you've used Text::Tmpl, this is very similar.  Here are the difference,
or, the top ten reasons to use this instead:

  1. The tag delimiters are done <% like this %>

  2. There is a new template command:
       <% set "foo", "bar" %>
     in the template is exactly equivalaent to:
       $t->set_value( foo => "bar" )
     in the script.  It takes precedence over
     the script values, as well.

  3. $t->set_dir() works with or without the trailing slash

  4. There is no ifn/endifn tag pair, instead you use an "!"
     before the argument like this: <% if ! $foo %> no foo <% endif %>

  5. There are elsif and else tags that work like you'd expect:
        <% if $foo %>
            FOO
        <% elsif $bar %>
            BAR
        <% else %>
            BAZ
        <% endif %>

  6. You can do simple logic in your if statements like this:
        <% if $foo && !($bar || $baz) %>
            HELLO
        <% endif %>
      ...but that's it!  we want to give the template owners some
      power, but let's keep the perl in the script!

  7. There are plenty of verbose warnings to help debug:
     like warnings when the directory or file can't be opened, and
     malformed/misnested template tags generate warnings with line
     numbers.

  8. set_value() takes either a single key/value pair or a hashref,
     and warns if you give it invalid arguments.  get_loop() is
     easier to type than loop_iteration()

  9. It uses less memory right up front, and it doesn't leak

 10. It's pure perl so you can hack it and see how it works.

The downside is that it can be slower in some cases, but read on...

=head1 PERFORMANCE

The only downside of this module in comparison to Text::Tmpl is  that it's
slower.  In fact Text::Tmpl is about twice as
fast.  That seems like a lot, but given the improved memory usage and
conveniences, it may be worth it unless you have an blinding need for
speed and speed alone.  1000 reps on a G4 1.33mhz with a smallish template:

 david:  4 secs ( 2.50 usr +  1.16 sys =  3.66 CPU) @ 273.22/s (n=1000)
   jon:  7 secs ( 6.50 usr +  0.10 sys =  6.60 CPU) @ 151.52/s (n=1000)

Note that the specifics of the template have a huge effect on speed.  Notably,
the enhanced logic operators allowed in if/elsif arguments incur an eval,
which causes a performance hit: worst case is 30% slower than simple
args to if/elsif.  "Simple args" in this case means a single variable,
optionally preceded by "!".  If you use any of "( ) || &&" then you incur
the enhanced logic code.  However, don't sweat it too much as some clever
caching eliminates most of the performance hit in most cases -- especially
inside loops and in subsequent calls in mod_perl processes; where it counts
most.

The template used in the above benchmark does not use any enhanced logic.
This is only fair since Text::Tmpl doesn't even support enhanced logic.

I have put a fair effort into optimizing, but it'll never be as fast as
Text::Tmpl -- seems the majority of time is spent in _render_tokens() which
does a lot of recursing, and C functions recurse faster than perl's.  Heck
I even tried the crazy &_func notation to avoid repassing @_, but couldn't
get it any faster.  I also tried a weird method where I contiually spliced
tokens onto the token array as we rendered instead of recursing -- still no
win.  _tokenize_file() is where the next most time is spent.  The main thing
seems to be that there's no good way to tokenize without copying the string
bit by bit.  In C you can just point to the template strings directly from
the tokens.  I've tried tricks with split() and pos() and whatnot, but this
is as good as I could get it in perl.

At this point I've tried about everything I can think of.  Feel free to offer
suggestions, though, other than rewriting it in C ;)

Here's some data for memory usage; note the RSIZE and VSIZE numbers...

               #MREGS  RPRVT  RSHRD  RSIZE  VSIZE

JF::Template
  500 reps           22  1.13M   404K  1.39M  26.8M
 1000 reps           22  1.13M   404K  1.39M  26.8M
 2000 reps           22  1.13M   404K  1.39M  26.8M

Text::Tmpl
  500 reps           26  5.57M   544K  5.89M  28.2M 
 1000 reps           28  10.1M   544K  10.4M  30.2M
 2000 reps           31  19.2M   544K  19.5M  40.3M

So basically, a bit better than half the speed, but with a much better memory
footprint, no memory leaks, enhanced logic operators and better debugging
output.  A more than fair trade, says I.

=head2 Performance Secret

Okay, so in an effort to be humble and realistic, I've not been totally
honest.  The fact is that in practice, this module is actually faster
than Text::Tmpl.  This is achieved by caching the results of the tokenizing
stage for each template.  This means that the majority of the work is done
only once for a template the first time it is used, and any subsequent
calls to parse_file() will do much less work.  Since the most common use
for this module is to run under an Apache webserver dishing out page after
page of the same template, it's actually a big win.  Text::Tmpl re-tokenizes
the template on every call.  Here is a comparison:

  # 150 iterations of the same template
  Text::Tmpl   :   95.54/sec
  JF::Template :  147.06/sec

So, if the same template is likely to be reused before the process shuts
down, you can actually see quite a speedup with this module over Text::Tmpl.
The first call is a bit slower, and all subsequent calls are a bit faster.

The system is smart enough to pick up new files when they change.

This caching is turned on by default, and I haven't come across a good
reason not to use it.  It does use more memory, but unless you've got an
absolutely huge template collection, it's negligable.  Even if you do,
it's probably still worth it.  But a constant is provided at the top of the
module to disable it if you want: just set USE_TOKEN_CACHE to "0".

=head1 NOTES

I think it's neat that something this useful is under 500 lines of
actual code.  And that it took me so many hours (spread over so many months)
to get it all working smoothly.  I am quite proud of this module :)

I should come up with some method to make it easier for template writers
to detect misnested tags.

I should expand the tests and clean up the code a bit.

I should call my family more often.

=head1 DEPENDENCIES

None.

=head1 AUTHOR

Jonathan Field - jfield@gmail.com

...but based on the concepts of Neil Mix and David Lowe.
Oh, and Dave Bailey wrote the cool export_*() functions!

