#!/usr/bin/perl
use strict;
use warnings;
use lib "../lib";
use WP::Tools;
use Data::Dumper;

# figure out if it's for real or a dry run
my $FOR_REAL = 1;
if (grep /-n/, @ARGV) { $FOR_REAL = 0; }
# get a list of specified modules, if it's there
my @moddirs = grep { !/-n/ } @ARGV;
my $and_moddir_in_list = "";
if (@moddirs) {
    $and_moddir_in_list = "AND moddir IN (" .
        join(", ", map( "'$_'", @moddirs ) ) .
    ")";
}

my $modroot = "/var/modules";

my $d = WP::Tools->database();

my $modules = $d->select_multiple(qq(
    SELECT module_id, moddir, title, ksize, lang,
           kiwix_url, kiwix_date
      FROM modules
     WHERE kiwix_url IS NOT NULL
       AND is_hidden = "No"
      $and_moddir_in_list
           /* never updated, and would need more logic to
              get since it's just a different "desc" for
              wikipedia */
       AND moddir != 'en-wikipedia_for_schools'
     ORDER BY ksize
));

# gets a list of modules and dates from the actual kiwix site
my $kiwixdata = getkiwixdata($modules);

#print Dumper($kiwixdata);
#exit;

my $changed = 0;
foreach my $mod (@$modules) {

    # some of our modules are availabe in both zim and non-zim
    # forms -- by convetion we append "-zim" to clarify -- we
    # remove it here to match the kiwix naming convention
    my $kmodname = $mod->{moddir};
    $kmodname =~ s/-zim$//;
    my $kmod = $kiwixdata->{ $kmodname };
    print "$mod->{moddir}: $kmod->{date}\n";

    if (($mod->{kiwix_date}||"") ne $kmod->{date}) {

        print "\tUpdating $mod->{moddir}...\n";
        print "\tOld Version: " . ($mod->{kiwix_date}||"n/a") . "\n";
        print "\tNew Version: $kmod->{date}\n";
        print "\tZim Size: $kmod->{size}\n";

        # download the zim archive
        if ($FOR_REAL) {

            # large zims with indexes come in a zip file and handled differently
            # than smaller zim files which come as-is
            my $filename;
            if ($kmod->{url} =~ /^http.+\.zip$/) {

                # get the zip file
                $filename = "$kmod->{moddir}-$kmod->{date}.zip";
                system("wget -q --show-progress $kmod->{url} -O $filename")
                    == 0 or die($!);

                # clear away old stuff and unzip just the parts we want
                my $tmpdir = "$filename-$$";
                system("rm -rf $tmpdir"); # just in case
                system("unzip $filename 'data/content/*' 'data/index/*' -d $tmpdir")
                    == 0 or die($!);

                # copy new files to modules directory
                system("rsync -avm --del $tmpdir/data/ $modroot/$mod->{moddir}/data/")
                    == 0 or die($!);

                # clean up
                system("rm -rf $filename $tmpdir")
                    == 0 or die($!);

            } elsif ($kmod->{zim} =~ /^http.+\.zim$/) {

                # get the zim file
                ($filename) = $kmod->{zim} =~ /\/([^\/]+)$/;
                system("wget -q --show-progress $kmod->{zim} -O $filename")
                    == 0 or die($!);

                my $dest = "$modroot/$mod->{moddir}/data/content";

                # make sure the sub directories are there
                system("mkdir -p $dest/")
                    == 0 or die($!);

                # copy new file to modules directory
                system("rsync -avm --del $filename $dest/")
                    == 0 or die($!);

                # clean up
                system("rm -rf $filename")
                    == 0 or die($!);
                
            }

            # bump the version number in both the filesystem
            my $regex = "s/<!--\\s*version.+?>/<!-- version=\"$kmod->{date}\" -->/";
            my $indexfile = "$modroot/$mod->{moddir}/rachel-index.php";
            system("perl -pi -e '$regex' '$indexfile'") == 0 or die($!);

            # we let the db version number get updated as part of the
            # general version number update process later -- this gives us
            # a chance to test and correct problems before clients
            # are instructed to download a new version (this doesn't
            # protect against people downloading a given module
            # manually, however).

            # record the zim date
            $d->update("modules",
                { kiwix_date => $kmod->{date}, },
                { module_id => $mod->{module_id} }
            );

        }

    }

}

# gets a list of modules and dates from the actual kiwix site
sub getkiwixdata {

    # we want to filter the list down to just the requested
    # modules (in fact it wouldn't matter if we let them all
    # through, but it greatly simplifies debugging when you
    # don't have a hundred rows of irrelevant data)
    my $modules = shift;
    my %wanted;
    foreach my $mod (@$modules) {
        my $kmodname = $mod->{moddir};
        $kmodname =~ s/-zim$//;
        $wanted{$kmodname} = 1;
    }

    # pull the content library from their website into memory (3MB+)
    my $rawpage = `wget -qO- http://wiki.kiwix.org/wiki/Content_in_all_languages`;
    # or use an on-disk version you just grabbed
#    my $rawpage  = `cat Content_in_all_languages`;

    # remove whitespace
    $rawpage =~ s/[\n\r\s]+/ /g;

    # this converts their HTML page table into a perl hash
    # so we can check dates and such...
    # this is roughly what we expect to find in each field:
    #    0 wikistage
    #    1 fr
    #    2 4.7G
    #    3 2015-07
    #    4 all
    #    5 <a rel="nofollow" [...links to unindexed zims...]
    #    6 <p><a rel="nofollow" [...links to indexed zims with software...]
    my %allrows;
    while ($rawpage =~ /<tr>(.+?)<\/tr>/g) {
        my $rawrow = $1;
        my @rowarr;
        while ($rawrow =~ /<td>(.+?)<\/td>/g) {
            my $field = $1;
            $field =~ s/^\s+//;
            $field =~ s/\s+$//;
            push @rowarr, $field;
        }
        my %row = (
            name => $rowarr[0],
            lang => $rowarr[1],
            size => $rowarr[2],
            date => $rowarr[3],
            desc => $rowarr[4],
            zim  => $rowarr[5],
            url  => $rowarr[6],
        );

        # remove parenthetical language from name
        $row{name} =~ s/\s+\(.+\)$//;

        # for some reason they changed language codes to mis-encoded language strings
        # sigh... so now we try pulling the language code from the URL -- we have to
        # look for a multipart language too, like "es-pe" so we can dismiss those in
        # favor of the exact match ("es" in that case)
        #($row{lang}) = $rowarr[5] =~ m[http://download.kiwix.org/zim/.+?_(..(-..)?)];
        # ...they fixed it

        $row{moddir} = $row{lang} . "-" . $row{name};

        # skip the stuff we aren't interested in
        next if not $wanted{ $row{moddir} };

        # pull the correct URL from the zim/url field
        $row{url} =~ s[.+href="(http://download.kiwix.org/.+?\.zip)".+][$1];
        $row{zim} =~ s[.+href="(http://download.kiwix.org/.+?\.zim)".+][$1];

        # We check if it has the same lang, name, and description,
        # and if so we take the most recent
        if ($allrows{ $row{moddir} }{ $row{desc} }) {
            if ($row{date} lt $allrows{ $row{moddir} }{ $row{desc} }{date}) {
                next; # skip if it's older
            }
        }

        $allrows{ $row{moddir} }{ $row{desc} } = \%row;
    }

    # now we've got all the options for each moddir:
    # there are multiple versions of each kiwix module, like
    # en-wikipedia ... there's "all", "nopic", and various subsets
    # we take the best one here
    my %myrows;
    foreach my $moddir (keys %allrows) {
        #print "$moddir:\n";
        if ($allrows{ $moddir }{"all"}) {
            #print "\tall\n";
            $myrows{ $moddir } = $allrows{ $moddir }{"all"};
        } elsif ($allrows{ $moddir }{"all novid"}) {
            #print "\tall novid\n";
            $myrows{ $moddir } = $allrows{ $moddir }{"all novid"};
        } else {
            print "\tNONE!!!\n";
            die "There was no valid version of $moddir\n";
        }
    }

    return \%myrows;

}
