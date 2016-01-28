#!/usr/bin/perl -w
use strict;
use warnings;

use Mail::IMAPClient;
use MIME::Lite;
use Cwd 'abs_path';
use URI::URL;
use Data::Dumper;
use File::Basename;
use File::Temp qw(tempdir);

local $| = 1;

my $imap;
my $quota;
my %cfg;
my $seg=1; #seguimiento

sub type {
	my ($f)=@_;
	if ($f =~ /.+\.z(ip|\d+)$/) {return "application/zip"};
	if ($f =~ /.+\.rar$/) {return "application/x-rar-compressed"};
	if ($f =~ /.+\.part\d+\.exe$/) {return "application/x-msdownload"};
	return undef;
}

sub save {
	my($file,$txt,$total,$count) = @_;
	my $name=$file;
	$name=~ s/^.+\///;
	if ($total==1) {print "Subiendo $name ... ";}
	else {print "Subiendo $count de $total: $name ... ";}
	my $msg = MIME::Lite->new(
		From    =>'up@bot.com',
		To      =>'down@bot.com',
		Subject =>'Up [' .$count . '/' . $total . ']: ' . $name,
		Type    =>'multipart/mixed'
	);
	if ($txt) {
		$msg->attach(Type => 'TEXT', Data => $txt);
	}
	$msg->attach(
        	Type        => type($name),
	        Path        => $file,
	        Filename    => $name,
	        Disposition => 'attachment'
	);
	my $id=imap()->append_string(imap()->Folder(),$msg->as_string);
	print "OK\n";
}

sub space {
	my ($file) = @_;
	my $size=((-s $file)/1024);
	my $free=$quota-imap()->quota_usage();
	return if ($size<$free);
	print "Vaciando $cfg{papelera} para liberar espacio ... ";
	purge($cfg{papelera});
	my $aux=$quota-imap()->quota_usage();
	if ($aux<=$free) {
		print "KO\n";
	} else {
		print "OK\n";
	}
	$free=$aux;
	return if ($size<$free);
	if ($seg) {
		print "Esperando a que el usuario libere " . int(($size-$free)/1024 + 0.99) . "MB en el servidor... ";
		while ($size>($quota-imap()->quota_usage())) {sleep(10);}
		print "OK\n";
	} else {
		print "Pulse enter para purgar ". imap()->Folder() . " ...";
		<STDIN>;
		purge();
	}
}

sub purge {
	(my $fld, my $bak) = @_;
	if ($fld) {
		$bak=imap()->Folder();
		imap()->select($fld) or die "Could not select: $@\n";
	}
	my @dvs=imap()->messages or die "Could not messages: $@\n";
	foreach my $dv (@dvs){imap()->delete_message($dv);}
	imap()->expunge(imap()->Folder());
	if ($bak) {
		imap()->select($bak) or die "Could not select: $@\n";
	}
}

sub setCfg {
	my $fl=$_[0];
	if (! $fl) {
		$fl=$0;
		$fl=~ s/^.+\/|\..+$//g;
		$fl= $ENV{"HOME"} . "/." . $fl . ".cnf";
	}
	open (CFG, $fl) or die "No se puede abrir el fichero de configuracion: $fl\n" . $@;
	%cfg=();
	while (my $line=<CFG>) {
		$line=~ s/^\s+|\s+$|\s+#.*$//g;
		next if (substr($line, 0, 1) eq "#");
		(my $k,my $v) = split /\s*=\s*/, $line;
		$cfg{$k} = $v if $k and $v;
	}
	close(CFG);
}

sub imap {
	if (!$imap || $imap->IsUnconnected) {
		print "Conectando a $cfg{User}/$cfg{Folder} ... " ;
		$imap = Mail::IMAPClient->new(%cfg) or die "\n$@\n";
		$imap->select($imap->Folder());
		print "OK\n";
	}
	return $imap;
}
sub samedir {
	return 1 if scalar @_ ==1;
	my $dir=dirname(shift(@_));
	foreach (@_) {
		return 0 unless $dir eq dirname($_);
	}
	return 1;
}

my $tp=tempdir( CLEANUP => 1 );

my $purge=0;
my @files=();
my @zip=();
foreach my $a (@ARGV) {
	if ($a eq "--key") {$seg=0;}
	elsif ($a eq "--purge") {$purge=1;}
	elsif ($a =~ /^(http|ftp)s?:\/\//) {
		system("wget --trust-server-names --directory-prefix=" . $tp . "/wget \"" . $a . "\"");
		die "Error al descargar el archivo" if $? != 0;
		next;
	}
	next unless (-f $a);
	if ($a =~ /.+\.cnf$/) {setCfg($a);}
	elsif (type($a)) {push (@files, abs_path($a));}
	else {push (@zip, $a);} # abs_path($a));}
}
if (! %cfg) {setCfg()};

push(@zip,glob($tp . "/wget/*")) if -d ($tp . "/wget");
if (@zip) {
	my $junk="";
	$junk="--junk-paths" if samedir(@zip);
	mkdir($tp . "/zip/");
	system("zip -r " . $junk . " -s " . $cfg{"zip.size"} . "m -" . $cfg{"zip.level"} . " -P" . $cfg{"zip.pass"} . " " . $tp . "/zip/" . $cfg{"zip.name"} . ".zip \"" . join("\" \"",@zip) . "\"");
	die "Error al hacer el zip" if $? != 0;
	push (@files,glob($tp . "/zip/" . $cfg{"zip.name"}  . ".z*"));
}

my $t=scalar (@files);

die "Debe pasar una lista de ficheros\n" unless $t>0;

if ($purge) {purge();}

$quota=imap()->quota()-(1024*5);
my $free=($quota-$imap->quota_usage());

my $aux;
my $max=0;
foreach my $f (@files){
	$aux=(-s $f)/1024;
	die "El fichero $f [" . int(($aux/1024) + 0.99) . "MB] ocupa más de lo que el servidor puede almacenar [". int($quota/1024) . "MB]\n" unless $aux<$quota;
	if ($aux>$max) {$max=$aux};
}
die "Necesita liberar al menos " . int(($max/1024) + 0.99) . "MB antes de empezar\n" if ($max>$free);

my $c=1;
my $m=join(" ",@ARGV);

foreach my $f (@files){
	space($f);
	save($f,$m,$t,$c++);
}

if ($imap && $imap->IsConnected) {
	$imap->disconnect or die "Could not disconnect: $@\n";
}
