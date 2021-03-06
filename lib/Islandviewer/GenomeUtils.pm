=head1 NAME

    Islandviewer::Islandpick::GenomeUtils

=head1 DESCRIPTION

    Object to load, convert and store custom genomes in to
    the internal formats needed by IslandViewer

    Most of this code is cut and pasted from Morgan's
    original run_custom_islandviewer.pl script, just updating it to match
    the overall style of the updated IslandViewer.

=head1 SYNOPSIS

    use Islandviewer::Islandpick::GenomeUtils;

    my $genome_obj = Islandviewer::Islandpick::GenomeUtils->new(
                                           { workdir => '/tmp/dir/'});

    # $genome_name optional name, will be custom_genome otherwise
    $genome_obj->read_and_convert($filename, $genome_name);

    my $success = $genome_obj->insert_custom_genome();

=head1 AUTHOR

    Matthew Laird
    Brinkman Laboratory
    Simon Fraser University
    Email: lairdm@sfu.ca

=head1 LAST MAINTAINED

    Oct 30, 2013

=cut

package Islandviewer::GenomeUtils;

use strict;
use Moose;
use Log::Log4perl qw(get_logger :nowarn);
use File::Copy;
use File::Basename;

use Islandviewer::DBISingleton;
use Islandviewer::Constants qw(:DEFAULT $STATUS_MAP $REV_STATUS_MAP $ATYPE_MAP);

use MicrobeDB::Replicon;
use MicrobeDB::Search;

use Bio::SeqIO;
use Bio::Seq;

my $cfg; my $logger;

sub BUILD {
    my $self = shift;
    my $args = shift;

    $cfg = Islandviewer::Config->config;

    $logger = Log::Log4perl->get_logger;

    if($args->{microbedb_ver}) {
	$self->{microbedb_ver} = $args->{microbedb_ver};
    }

#    die "Error, work dir not specified: $args->{workdir}"
#	unless( -d $args->{workdir} );
#    $self->{workdir} = $args->{workdir};

}

# Read in a genbank or Embl file and convert it to
# the other needed formats
#
# Puts the resulting files in the same directory
# as the input genome
#
# Most code recycled from run_custom_islandviewer.pl
# function gbk_or_embl_to_other_formats

sub read_and_convert {
    my $self = shift;
    my $filename = shift;
    my $genome_name = (@_ ? shift : 'custom_genome');

    #seperate extension from filename
    $filename =~ s/\/\//\//g;
    my ( $file, $extension ) = $filename =~ /(.+)\.(\w+)/;

    $logger->debug("From filename $filename got $file, $extension");

    # We're going to check what files we have, then only
    # generate the ones we need.  Because this code is
    # so nicely compact and to avoid duplication, we're
    # just going to trick the code so if a file exists
    # it gets written to /dev/null
    $self->{base_filename} = $file;
    my $formats = $self->parse_formats($self->find_file_types());

    my $in;

    if ( $extension =~ /embl/ ) {

	$in = Bio::SeqIO->new(
	    -file   => $filename,
	    -format => 'EMBL'
	    );
	$logger->info("The genome sequence in $filename has been read.");
    } elsif ( ($extension =~ /gbk/) || ($extension =~ /gb/) ) {
	# Special case, our general purpose code likes .gbk...
	if($extension =~ /gb/) {
	    move($filename, "$file.gbk");
	    $filename = "$file.gbk";
	}

	$in = Bio::SeqIO->new(
	    -file   => $filename,
	    -format => 'GENBANK'
	    );
	$logger->info("The genome sequence in $filename has been read.");
    } else {
	$logger->logdie("Can't figure out if file is genbank (.gbk) or embl (.embl)");
    }

    while ( my $seq = $in->next_seq() ) {
	my $out;    
	if ( $extension =~ /embl/ ) {
	    my $outfile = ($formats->{gbk} ? '/dev/null' : $file . '.gbk');
	    $out = Bio::SeqIO->new(
		-file   => ">" . $outfile,
		-format => 'GENBANK'
		);
	} elsif ( ($extension =~ /gbk/) || ($extension =~ /gb/) ) {
	    my $outfile = ($formats->{embl} ? '/dev/null' : $file . '.embl');
	    $out = Bio::SeqIO->new(
		-file   => ">" . $outfile,
		-format => 'EMBL'
		);
	} else {
	    $logger->logdie("Can't figure out if file is genbank (.gbk) or embl (.embl)");
	}

	my $outfile = ($formats->{faa} ? '/dev/null' : $file . '.faa');
	my $faa_out = Bio::SeqIO->new(
	    -file   => ">" . $outfile,
	    -format => 'FASTA'
	    );
	$outfile = ($formats->{ffn} ? '/dev/null' : $file . '.ffn');
	my $ffn_out = Bio::SeqIO->new(
	    -file   => ">" . $outfile,
	    -format => 'FASTA'
	    );
	$outfile = ($formats->{fna} ? '/dev/null' : $file . '.fna');
	my $fna_out = Bio::SeqIO->new(
	    -file   => ">" . $outfile,
	    -format => 'FASTA'
	    );

	$outfile = ($formats->{ptt} ? '/dev/null' : $file . '.ptt');
	open( my $PTT_OUT, '>', $outfile );

	my $total_length = $seq->length();
	my $total_seq    = $seq->seq();

	my $success = 0;

	#Create gbk or embl file
	$success = $out->write_seq($seq);
	if ($success == 0) {		
	    $logger->error(".gbk or .embl file is not generated successfully.");
	}

	#Create fna file
	$success = $fna_out->write_seq($seq);
	if ($success == 0) {		
	    $logger->error(".fna file is not generated successfully.");
	}

	#Only keep those features coding for proteins
	my @cds = grep { $_->primary_tag eq 'CDS' } $seq->get_SeqFeatures;

	#Remove any pseudogenes
	my @tmp_cds;
	foreach (@cds) {
	    unless ( $_->has_tag('pseudo') ) {
		push( @tmp_cds, $_ );
	    }
	}
	@cds = @tmp_cds;

	my $num_proteins = scalar(@cds);

	#Create header for ptt file
	print $PTT_OUT $seq->description, " - 1..", $seq->length, "\n";
	print $PTT_OUT $num_proteins, " proteins\n";
	print $PTT_OUT join(
	    "\t", qw(Location Strand Length PID Gene Synonym Code COG
			  Product)
	    ),
	    "\n";

	my $count = 0;

	#Step through each protein
	foreach my $feat (@cds) {
	    $count++;

	    #Get the general features
	    my $start  = $feat->start;
	    my $end    = $feat->end;
	    my $strand = $feat->strand;
	    my $length = $feat->length;

	    if ($length <= 2) {
		throw Bio::Root::Exception("Something's wrong with one of the protein sequences! CDS info: start=$start end=$end strand=$strand");
	    }

	    #Get more features associated with gene (not all of these will neccesarily exist)
	    my ( $product, $protein_accnum, $gene_name, $locus_tag ) =
		( '', '', '', '' );
	    ($product) = $feat->get_tag_values('product')
		if $feat->has_tag('product');
	    ($protein_accnum) = $feat->get_tag_values('protein_id')
		if $feat->has_tag('protein_id');
	    ($gene_name) = $feat->get_tag_values('gene')
		if $feat->has_tag('gene');
	    ($locus_tag) = $feat->get_tag_values('locus_tag')
		if $feat->has_tag('locus_tag');

	    my $gi = $count;
	    $gi = $1 if tag( $feat, 'db_xref' ) =~ m/\bGI:(\d+)\b/;

	    my $strand_expand  = $strand >= 0 ? '+' : '-';
	    my $strand_expand2 = $strand >= 0 ? ''  : 'c';
	    my $desc = "\:$strand_expand2" . "$start-$end";

	    $desc = "gi\|$gi\|" . $desc;

	    #Create the ffn seq
	    my $ffn_seq = $seq->trunc( $start, $end );
	    if ( $strand == -1 ) {
		$ffn_seq = $ffn_seq->revcom;
	    }
	    $ffn_seq->id($desc);
	    $ffn_seq->desc($product);
	    $success = $ffn_out->write_seq($ffn_seq);
	    if ($success == 0) {		
		$logger->error(".ffn file is not generated successfully.");
	    }	

	    #Create the faa seq
	    my $faa_seq;
	    if ( $feat->has_tag('translation') ) {
		my ($translation) = $feat->get_tag_values('translation');
		$faa_seq = new Bio::Seq( -seq => $translation ) or throw Bio::Root::Exception("Cannot read protein sequence: $!");
	    } else {
		$faa_seq =
		    $ffn_seq->translate( -codontable_id => 11, -complete => 1 );
	    }

	    $faa_seq->id($desc);
	    $faa_seq->desc($product);
	    $success = $faa_out->write_seq($faa_seq);
	    if ($success == 0) {
		$logger->error(".faa file is not generated successfully.");
	    }

	    #Print out ptt line
	    my $cog = '-';
	    $cog = $1 if tag( $feat, 'product' ) =~ m/^(COG\S+)/;
	    my @col = (
		$start . '..' . $end,
		$strand_expand,
		( $length / 3 ) - 1,
		$gi,
		tag( $feat, 'gene' ),
		tag( $feat, 'locus_tag' ),
		'-',
		$cog,
		tag( $feat, 'product' ),
		);
	    print $PTT_OUT join( "\t", @col ), "\n";

	    #load annotation into microbedb
#	    insert_record(
#		'gene',
#		{
#		    version_id     => 0,
#		    rpv_id         => $rpv_id,
#		    gpv_id         => $gpv_id,
#		    protein_accnum => $protein_accnum,
#		    pid            => $gi,
#		    gene_start     => $start,
#		    gene_end       => $end,
#		    gene_length    => $length,
#		    gene_strand    => $strand_expand,
#		    gene_name      => $gene_name,
#		    locus_tag      => $locus_tag,
#		    gene_product   => $product,
#		    gene_seq       => $ffn_seq->seq(),
#		    protein_seq    => $faa_seq->seq(),
#		}
#		);
	}    #end of foreach

#	update_record(
#	    'replicon',
#	    { rpv_id => $rpv_id },
#	    {
#		cds_num    => $num_proteins,
#		rep_size   => $total_length,
#		rep_seq    => $total_seq,
#		file_types => '.gbk .fna .faa .ffn .ptt .embl',
#	    }
#	    );

	# Save the details of the file we just loaded
	$self->{name} = $genome_name;
	$self->{num_proteins} = $num_proteins;
	$self->{total_length} = $total_length;
	$self->{base_filename} = $file;
	$self->{ext} = $extension;
	$self->{orig_filename} = $filename;
	$self->{formats} = $self->parse_formats($self->find_file_types());
#	$self->{type} = 'custom';
	$self->{genome_read} = 1;

	close($PTT_OUT);
    }    #end of while
    
}    #end of gbk_or_embl_to_other_formats

sub regenerate_files {
    my $self = shift;

    unless($self->{base_filename}) {
	$logger->error("Error, we can't regenerate the files unless we have a base filename");
	return 0;
    }

    if($self->{formats}->{gbk}) {
	$logger->trace("Regenerating based on genbank format");
	$self->read_and_convert($self->{base_filename} . '.gbk', $self->{name});
    } elsif($self->{formats}->{embl}) {
	$logger->trace("Regenerating based on Embl format");
	$self->read_and_convert($self->{base_filename} . '.embl', $self->{name});
    } else {
	$logger->error("Error, we don't have either genbank or embl, can't generate needed files");
	return 0;
    }

    if($cfg->{expected_exts} eq $self->find_file_types()) {
	# The regeneration was successful!
	return 1;
    } else {
	$logger->error("Error, we didn't regenerate all the files we expected to, failed");
	return 0;
    }

}

sub find_file_types {
    my $self = shift;

    unless($self->{base_filename}) {
	$logger->error("Error, a genome must be read before you can testthe file types");
	return '';
    }

    # Fetch and parse the formats we expect to find...
    my @expected;
    foreach (split /\s+/, $cfg->{expected_exts}) { 
	$_ =~ s/^\.//; 
	push @expected, $_; 
    }

#    my $expected_formats = $self->parse_formats($cfg->{expected_exts});

    my @formats;
    foreach my $ext (@expected) {
	# For each format we expect to find, does the file exist?
	# And is non-zero
	if(-f "$self->{base_filename}.$ext" &&
	   -s "$self->{base_filename}.$ext") {
	    push @formats, ".$ext";
	}
    }

    return join ' ', @formats;
}

sub insert_custom_genome {
    my $self = shift;

    # If we're trying to insert the genome without
    # calling read_and_convert first, fail
    return 0 unless($self->{genome_read});

    my $dbh = Islandviewer::DBISingleton->dbh;

    my $sqlstmt = "INSERT INTO CustomGenome (name, cds_num, rep_size, filename, formats) VALUES (?, ?, ?, ?, ?)";
    my $insert_genome = $dbh->prepare($sqlstmt) or 
	die "Error preparing statement: $sqlstmt: $DBI::errstr";

    $insert_genome->execute($self->{name}, $self->{num_proteins}, 
			    $self->{total_length}, $self->{base_filename},
			    '.gbk .fna .faa .ffn .ptt .embl');

    my $cid = $dbh->last_insert_id(undef, undef, undef, undef);
    unless($cid) {
	$logger->error("Error inserting custom genome $self->{base_filename}");
	return 0;
    }

    $self->{accnum} = $cid;

    return $cid;
}

# Move a custom genome and all its children to a new location,
# then update the database

sub move_and_update {
    my $self = shift;
    my $cid = shift;
    my $new_path = shift;

    # First let's ensure this is a directory
    unless( -d $new_path ) {
	$logger->error("Error, $new_path doesn't seem to be a directory");
	return 0;
    }

    # If we're trying to insert the genome without
    # calling read_and_convert first, fail
    return 0 unless($self->{genome_read});

    my($filename, $directory, $suffix) = 
	fileparse($self->{base_filename});

    # Move the files over to the new location
#    my @old_files = glob ($self->{base_filename} . '*');
    foreach my $f (glob ($self->{base_filename} . '*')) {
	move($f, $new_path);
    }

    # Now update the base name in the database
    my $newfile = "$new_path/$filename";
    $newfile =~ s/\/\//\//g;
    $self->{base_filename} = $newfile;
    my $dbh = Islandviewer::DBISingleton->dbh;
    $dbh->do("UPDATE CustomGenome SET filename=? WHERE cid = ?", undef, $newfile, $cid);

    return 1;
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

	    my $sqlstmt = "SELECT name, filename, formats, cds_num, rep_size from CustomGenome WHERE cid = ?";
	    $self->{find_custom_name} = $dbh->prepare($sqlstmt) or 
		die "Error preparing statement: $sqlstmt: $DBI::errstr";
	}

	$self->{find_custom_name}->execute($rep_accnum);

	# Do we have a hit? There should only be one row,
	# its a primary key
	if($self->{find_custom_name}->rows > 0) {
	    my ($name,$filename,$formats, $cds_num, $total_length) = $self->{find_custom_name}->fetchrow_array;

	    # Save the results
	    $self->{name} = $name;
	    $self->{accnum} = $rep_accnum;
	    $self->{base_filename} = $filename;
	    $self->{num_proteins} = $cds_num;
	    $self->{total_length} = $total_length;
	    $self->{formats} = $self->parse_formats($formats);
	    $self->{type} = 'custom';
	    $self->{atype} = $ATYPE_MAP->{custom};
	    $self->{genome_read} = 1;

	    return ($name,$filename,$formats);
	}
    }    

    unless($type  eq 'custom') {
    # If we know we're not hunting for a custom identifier    

	my $sobj = new MicrobeDB::Search();

	my ($rep_results) = $sobj->object_search(new MicrobeDB::Replicon( rep_accnum => $rep_accnum,
#));
									  
								      version_id => $self->{microbedb_ver} ));
	
	# We found a result in microbedb
	if( defined($rep_results) ) {
	    # One extra step, we need the path to the genome file
	    my $search_obj = new MicrobeDB::Search( return_obj => 'MicrobeDB::GenomeProject' );
	    my ($gpo) = $search_obj->object_search($rep_results);

	    $self->{name} = $rep_results->definition();
	    $self->{accnum} = $rep_accnum;
	    $self->{base_filename} = $gpo->gpv_directory() . $rep_results->file_name();
	    $self->{num_proteins} = $rep_results->protein_num();
	    $self->{total_length} = $rep_results->cds_num();
	    $self->{formats} = $self->parse_formats($rep_results->file_types());
	    $self->{type} = 'microbedb';
	    $self->{atype} = $ATYPE_MAP->{microbedb};
	    $self->{version} = $rep_results->version_id();
	    $self->{genome_read} = 1;

	    return ($rep_results->definition(),$gpo->gpv_directory() . $rep_results->file_name(),$rep_results->file_types());
	}
    }

    # This should actually never happen if we're
    # doing things right, but handle it anyways
    return ('unknown',undef,undef);

}


sub parse_formats {
    my $self = shift;
    my $format_str = shift;

    my $formats;
    foreach (split /\s+/, $format_str) { $_ =~ s/^\.//; $formats->{$_} = 1; }

    return $formats;
}

#used to create ptt file
sub tag {
	my ( $f, $tag ) = @_;
	return '-' unless $f->has_tag($tag);
	return join( ' ', $f->get_tag_values($tag) );
}

# Store the GC values in the database for the front end

sub insert_gc {
    my $self = shift;
    my $cid = shift;

    my $dbh = Islandviewer::DBISingleton->dbh;

    my($seq_size, $min, $max, $mean, @gc_values)
	= $self->calculate_gc($self->{base_filename} . '.fna');

    my $update_gc = $dbh->prepare("INSERT IGNORE INTO GC (ext_id, min, max, mean, gc) VALUES (?, ?, ?, ?, ?)");
    $update_gc->execute($cid, $min, $max, $mean, join(',', @gc_values));
}

sub calculate_gc {
    my $self = shift;
    my $fna_file = shift;

    # For our sliding window to sample the GC
    my $window = 10000;
    my $sliding = $window;

    # Open the fna file for reading
    my $in = Bio::SeqIO->new(
	-file   => $fna_file,
	-format => 'Fasta'
       );

    # Since its an fna file there will only
    # be one sequence
    my $seq_obj = $in->next_seq();

    my $seq = $seq_obj->seq();
    my $seq_size = length($seq);

    # Set up the window to begin sliding
    my $start = 0 - $sliding;
    my $end = 0;

    my @gc_values;

    #intialize variables to keep track of min and max gc values
    my $min = [ 0, 0, 1 ];
    my $max = [ 0, 0, 0 ];

    do {
	$start += $sliding;
        if ( $start + $window > $seq_size ) {
            $end = $seq_size;
        } else {
            $end = $start + $window;
        }
        my $gc = $self->calc_gc( substr( $seq, $start, $window ) );

        if ( $gc < $min->[2] ) {
            $min = [ $start, $end, $gc ];
        }
        if ( $gc > $max->[2] ) {
            $max = [ $start, $end, $gc ];
        }
#        print $OUT_GC "bacteria $start $end $gc\n";
        push( @gc_values, $gc );

    } while( $end != $seq_size );

    #Create the avg line
    my $mean = mean(@gc_values);

    return $seq_size, $min->[2], $max->[2], $mean, @gc_values;
}

# Find the mean of an array of values

sub mean {
    my $self = shift;
    my $result;
    foreach (@_) { $result += $_ }
    return $result / @_;
}



sub calc_gc {
    my $self = shift;
    my $seq = $_[0];
    my $g = ( $seq =~ tr/g// );
    $g += ( $seq =~ tr/G// );
    my $c = ( $seq =~ tr/c// );
    $c += ( $seq =~ tr/C// );
    return ( $g + $c ) / length($seq);
}

1;
