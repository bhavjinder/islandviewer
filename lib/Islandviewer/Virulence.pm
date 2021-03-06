=head1 NAME

    Islandviewer::Virulence

=head1 DESCRIPTION

    Object to calculate virulence factors

=head1 SYNOPSIS

    use Islandviewer::Virulence;

    $vir_obj = Islandviewer::Virulence->new({workdir => '/tmp/workdir',
                                         microbedb_version => 80});

=head1 AUTHOR

    Matthew Laird
    Brinkman Laboratory
    Simon Fraser University
    Email: lairdm@sfu.ca

=head1 LAST MAINTAINED

    Dec 12, 2013

=cut

package Islandviewer::Virulence;

use strict;
use Moose;
use Log::Log4perl qw(get_logger :nowarn);
use File::Temp qw/ :mktemp /;
use Data::Dumper;

use Islandviewer::DBISingleton;
use Islandviewer::IslandFetcher;

use MicrobeDB::Replicon;
use MicrobeDB::Search;

my $cfg; my $logger; my $cfg_file;

my $module_name = 'Virulence';

sub BUILD {
    my $self = shift;
    my $args = shift;

    $cfg = Islandviewer::Config->config;
    $cfg_file = File::Spec->rel2abs(Islandviewer::Config->config_file);

    $logger = Log::Log4perl->get_logger;

    die "Error, work dir not specified:  $args->{workdir}"
	unless( -d $args->{workdir} );
    $self->{workdir} = $args->{workdir};

    die "Error, you must specify a microbedb version"
	unless($args->{microbedb_ver});
    $self->{microbedb_ver} = $args->{microbedb_ver};

    $logger->trace("Created Virulence object using microbedb_version " . $self->{microbedb_ver});
    
}

sub run {
    my $self = shift;
    my $accnum = shift;
    my $callback = shift;

    my $islands = $callback->fetch_islands();

    my $genes = $self->run_virulence($accnum, $islands);

    $callback->record_genes($genes);

    return 1;
}

sub run_virulence {
    my $self = shift;
    my $rep_accnum = shift;
    my $islands = shift;

    # We're given the rep_accnum, look up the files
    my ($name, $filename, $format_str) = $self->lookup_genome($rep_accnum);

    unless($filename) {
	$logger->logdie("Error, couldn't find genome file for accnum $rep_accnum");
    }

    $logger->trace("For accnum $rep_accnum found: $name, $filename, $format_str");

    my $fetcher_obj = Islandviewer::IslandFetcher->new({islands => $islands});

    my $genes = $fetcher_obj->fetchGenes("$filename.gbk");

    return $genes;
}

sub find_island_genes {
    my $self = shift;
    
}

# Lookup an identifier, determine if its from microbedb
# or from the custom genomes.  Return a package of
# information such as the base filename
# We allow to say what type it is, custom or microbedb
# if we know, to save a db hit

sub lookup_genome {
    my $self = shift;
    my $rep_accnum = shift;
    my $type = (@_ ? shift : 'unknown');

    unless($rep_accnum =~ /\D/ || $type eq 'microbedb') {
    # If we know we're not hunting for a microbedb genome identifier...
    # or if there are non-digits, we know custom genomes are only integers
    # due to it being the autoinc field in the CustomGenome table
    # Do this one first since it'll be faster

	# Only prep the statement once...
	unless($self->{find_custom_name}) {
	    my $dbh = Islandviewer::DBISingleton->dbh;

	    my $sqlstmt = "SELECT name, filename,formats from CustomGenome WHERE cid = ?";
	    $self->{find_custom_name} = $dbh->prepare($sqlstmt) or 
		die "Error preparing statement: $sqlstmt: $DBI::errstr";
	}

	$self->{find_custom_name}->execute($rep_accnum);

	# Do we have a hit? There should only be one row,
	# its a primary key
	if($self->{find_custom_name}->rows > 0) {
	    my ($name,$filename,$formats) = $self->{find_custom_name}->fetchrow_array;
	    return ($name,$filename,$formats);
	}
    }    

    unless($type  eq 'custom') {
    # If we know we're not hunting for a custom identifier    

	my $sobj = new MicrobeDB::Search();

	my ($rep_results) = $sobj->object_search(new MicrobeDB::Replicon( rep_accnum => $rep_accnum,
								      version_id => $self->{microbedb_ver} ));
	
	# We found a result in microbedb
	if( defined($rep_results) ) {
	    # One extra step, we need the path to the genome file
	    my $search_obj = new MicrobeDB::Search( return_obj => 'MicrobeDB::GenomeProject' );
	    my ($gpo) = $search_obj->object_search($rep_results);

	    return ($rep_results->definition(),$gpo->gpv_directory() . $rep_results->file_name(),$rep_results->file_types());
	}
    }

    # This should actually never happen if we're
    # doing things right, but handle it anyways
    return ('unknown',undef,undef);

}
