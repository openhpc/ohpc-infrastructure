#!/usr/bin/env perl
#
# Simple utility to derive cluster-specific inputs for use with OpenHPC
# installation recipe. Typically used within CI environment.
#
# karl.w.schulz@intel.com
#------------------------------------------------------------------------

use warnings;
use strict;
use Getopt::Long;

# Optional command-line arguments
my $outputFile = "/tmp/input.local";
my $inputFile  = "/opt/ohpc/pub/doc/recipes/vanilla/input.local";

sub update_var {
    my $varname = shift;
    my $value   = shift;

    if($_[0] =~ /^($varname=\"\$\{$varname:-)(\S*)\}\"$/) {
	$_[0] = "$1"."$value}\"\n";
	return(1);
    } else {
	return(0);
    }
}

GetOptions ('o=s' => \$outputFile,
	    'i=s' => \$inputFile);

if ( $#ARGV < 0) {
    print STDERR "Usage: gen_inputs [OPTIONS] <hardware_mapfile>\n";
    print STDERR "\nwhere available OPTIONS are:\n";
    print STDERR "   -i input               Location of template input file (default=/opt/ohpc/pub/doc/recipes/vanilla)\n";
    print STDERR "   -o output              Location of output file (default=/tmp/input.local)\n";
    print STDERR "\n";
    exit 1;
}

my $BaseOS;
if( !defined $ENV{BaseOS} ) {
    print STDERR "BaseOS environment variable must be set to choice of OS\n";
    exit 1;
} else {
    $BaseOS=$ENV{BaseOS};
}

my $Architecture;
if( !defined $ENV{Architecture} ) {
    print STDERR "Architecture environment variable must be set to type of host architecture\n";
    exit 1;
} else {
    $Architecture=$ENV{Architecture};
}

my $Version;
if( !defined $ENV{Version} ) {
    print STDERR "Version environment variable must be set to desired version\n";
    exit 1;
} else {
    $Version=$ENV{Version};
}

my $mapfile      = shift;
my $master_host  = "";
my @computes     = ();
my $num_computes = 0;


# Test for CI environment

if ( defined $ENV{'NODE_NAME'} && defined $ENV{'COMPUTE_HOSTS'} ) {
    $master_host = $ENV{'NODE_NAME'};

    @computes = split(', ',$ENV{'COMPUTE_HOSTS'});
    $num_computes = @computes;
    print "--> number of computes = $num_computes\n"
} else {
    die "Unknown NODE_NAME or COMPUTE_HOSTS env variable";
}

# Obtain dynamic host info

my $nfs_ip           = "";
my $master_ip        = "";
my $master_ipoib     = "";
###my $netmask          = "";
my $internal_netmask = "";
my $internal_network = "";
my $ipoib_netmask    = "";
my $mgs_fs_name      = "";
my $sysmgmtd_host    = "";
my $bmc_username     = "";
my $bmc_password     = "";
my $nagios_password  = "";
my $sms_eth_internal = "";
my $eth_provision    = "";
my $iso_path         = "";
my $ohpc_repo_dir    = "";
my $epel_repo_dir    = "";
my $ntp_server       = "";
my $enable_kargs     = "";
my $enable_ib        = "";
my $enable_ipoib     = "";
my $enable_opa       = "";
my $enable_beegfs_client = "";
my $enable_lustre_client = "";
my $enable_nvidia_gpu_driver = "";
my $enable_ganglia   = "";
my $enable_nagios    = "";
my $enable_genders   = "";
my $enable_magpie    = "";
my $enable_geopm     = "";
my $enable_mrsh      = "";
my $enable_powerman  = "";
my $enable_ipmisol   = "";
my $enable_clustershell = "";
my $enable_mpich_ucx = "";

my @compute_ips      = ();
my @compute_ipoibs   = ();
my @compute_macs     = ();
my @compute_bmcs     = ();

# iso_path can be overridden by Jenkins env
if( defined $ENV{iso_path} ) {
    $iso_path = $ENV{iso_path};
}

open(IN,"<$mapfile")  || die "Cannot open file -> $mapfile\n";

while(my $line=<IN>) {
    if($line =~ /^$master_host\_ip=(\S+)/) {
	$master_ip = $1;
    } elsif ($line =~ /^$master_host\_ipoib=(\S+)$/) {
	$master_ipoib = $1;
    } elsif ($line =~ /^nfs_ip=(\S+)$/) {
	$nfs_ip = $1;
    } elsif ($line =~ /^enable_kargs_$Architecture=(\S+)$/) {
	$enable_kargs = $1;
    } elsif ($line =~ /^enable_ib=(\S+)$/) {
	$enable_ib = $1;
    } elsif ($line =~ /^enable_nvidia_gpu_driver=(\S+)$/) {
	$enable_nvidia_gpu_driver = $1;
    } elsif ($line =~ /^enable_ipoib=(\S+)$/) {
	$enable_ipoib = $1;
    } elsif ($line =~ /^enable_beegfs_client_$BaseOS=(\S+)$/) {
	$enable_beegfs_client = $1;
    } elsif ($line =~ /^enable_lustre_client_$BaseOS=(\S+)$/) {
	$enable_lustre_client = $1;
    } elsif ($line =~ /^enable_nagios_$BaseOS=(\S+)$/) {
	$enable_nagios = $1;
    } elsif ($line =~ /^enable_ganglia_$BaseOS=(\S+)$/) {
	$enable_ganglia = $1;
    } elsif ($line =~ /^enable_genders=(\S+)$/) {
	$enable_genders = $1;
    } elsif ($line =~ /^enable_magpie=(\S+)$/) {
	$enable_magpie = $1;
    } elsif ($line =~ /^enable_geopm=(\S+)$/) {
	$enable_geopm = $1;
    } elsif ($line =~ /^enable_mrsh=(\S+)$/) {
	$enable_mrsh = $1;
    } elsif ($line =~ /^enable_powerman=(\S+)$/) {
	$enable_powerman = $1;
    } elsif ($line =~ /^enable_ipmisol=(\S+)$/) {
	$enable_ipmisol = $1;
    } elsif ($line =~ /^enable_clustershell=(\S+)$/) {
	$enable_clustershell = $1;
    } elsif ($line =~ /^enable_mpich_ucx=(\S+)$/) {
	$enable_mpich_ucx = $1;
    } elsif ($line =~ /^mgs_fs_name=(\S+)$/) {
	$mgs_fs_name = $1;
    } elsif ($line =~ /^sysmgmtd_host=(\S+)$/) {
	$sysmgmtd_host = $1;
###    } elsif ($line =~ /^$master_host\_netmask=(\S+)$/) {
###	$netmask = $1;
    } elsif ($line =~ /^internal_netmask=(\S+)$/) {
	$internal_netmask = $1;
    } elsif ($line =~ /^internal_network=(\S+)$/) {
	$internal_network = $1;
    } elsif ($line =~ /^ipoib_netmask=(\S+)$/) {
	$ipoib_netmask = $1;
    } elsif ($line =~ /^bmc_username=(\S+)$/) {
	$bmc_username = $1;
    } elsif ($line =~ /^bmc_password=(\S+)$/) {
	$bmc_password = $1;
    } elsif ($line =~ /^sms_eth_internal_$BaseOS=(\S+)$/) {
	$sms_eth_internal = $1;
    } elsif ($line =~ /^eth_provision=(\S+)$/) {
	$eth_provision = $1;
    } elsif ($line =~ /^iso_path=(\S+)$/) {
	$iso_path = $1;
    } elsif ($line =~ /^ohpc_repo_dir=(\S+)$/) {
	$ohpc_repo_dir = $1;
    } elsif ($line =~ /^epel_repo_dir=(\S+)$/) {
	$epel_repo_dir = $1;
    } elsif ($line =~ /^ntp_server=(\S+)$/) {
	$ntp_server = $1;
    } elsif ($line =~ /^bmc_password=(\S+)$/) {
	$bmc_password = $1;
    } elsif ($line =~ /^nagios_web_password=(\S+)$/) {
	$nagios_password = $1;
    } else {
	foreach my $compute (@computes) {
	    if ($line =~ /^$compute\_ip=(\S+)$/) {
		push(@compute_ips,$1);
	    }
	    if ($line =~ /^$compute\_ipoib=(\S+)$/) {
		push(@compute_ipoibs,$1);
	    }
	    if ($line =~ /^$compute\_mac=(\S+)$/) {
		push(@compute_macs,$1);
	    }
	    if ($line =~ /^$compute\_bmc=(\S+)$/) {
		push(@compute_bmcs,$1);
	    }
	}
    }
}

close(IN);

# Check if certain vars are set in the environment. If so,
# go ahead and set in input file (convenience for interactive training)

if (defined $ENV{enable_ib} ) {
    $enable_ib=1            if ( $ENV{enable_ib}              eq "1" ) ;
}
if (defined $ENV{enable_ipoib} ) {
    $enable_ipoib=1         if ( $ENV{enable_ipoib}           eq "1" ) ;
}
if (defined $ENV{enable_opa} ) {
    $enable_opa=1           if ( $ENV{enable_opa}             eq "1" ) ;
}
if (defined $ENV{enable_lustre_client} ) {
    $enable_lustre_client=1 if ( $ENV{enable_lustre_client}   eq "1" ) ;
}

die "Unable to map compute IPs"  if (! @compute_ips);
die "Unable to map compute MACs" if (! @compute_macs);
die "Unable to map compute BMCs" if (! @compute_bmcs);

# Now, copy input -> output and update vars based on detected CI settings

open(IN,"<$inputFile")   || die ("Cannot open input  file -> $inputFile");
open(OUT,">$outputFile") || die ("Cannot open output file -> $outputFile");

while(my $line=<IN>) {

#    if( $line =~ m/^ohpc_repo=\S+/) {
#	if($Repo ne "Release") {
#	    print OUT "ohpc_repo=\"\${ohpc_repo:-http://tcgsw-obs.pdx.intel.com:82/ForestPeak:/${Version}:/${Repo}/CentOS-7.1_Intel/ForestPeak:${Version}:${Repo}.repo}\"";
#	} else {
#	    print OUT $line;
#	}
    if( update_var("sms_name",$ENV{'NODE_NAME'},$line) ) {
	print OUT $line;
    } elsif ( update_var("sms_ip",$master_ip,$line) ) {
	print OUT $line;
    } elsif ( update_var("sms_eth_internal",$sms_eth_internal,$line) ) {
	print OUT $line;
    } elsif ( update_var("internal_netmask",$internal_netmask,$line) ) {
	print OUT $line;
    } elsif ( update_var("internal_network",$internal_network,$line) ) {
	print OUT $line;
    } elsif ( update_var("eth_provision",$eth_provision,$line) ) {
	print OUT $line;
    } elsif ( update_var("iso_path",$iso_path,$line) ) {
	print OUT $line;
    } elsif ( update_var("ohpc_repo_dir",$ohpc_repo_dir,$line) ) {
	print OUT $line;
    } elsif ( update_var("epel_repo_dir",$epel_repo_dir,$line) ) {
	print OUT $line;
    } elsif ( update_var("ntp_server",$ntp_server,$line) ) {
	print OUT $line;
    } elsif ( update_var("bmc_username",$bmc_username,$line) ) {
	print OUT $line;
    } elsif ( update_var("bmc_password",$bmc_password,$line) ) {
	print OUT $line;
    } elsif ( update_var("nagios_web_password",$nagios_password,$line) ) {
	print OUT $line;
    } elsif ( update_var("num_computes",$num_computes,$line) ) {
	print OUT $line;
    } elsif ( update_var("sms_ipoib",$master_ipoib,$line) ) {
	print OUT $line;
    } elsif ( update_var("mgs_fs_name",$mgs_fs_name,$line) ) {
	print OUT $line;
    } elsif ( update_var("sysmgmtd_host",$sysmgmtd_host,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_kargs",$enable_kargs,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_ib",$enable_ib,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_ipoib",$enable_ipoib,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_ganglia",$enable_ganglia,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_nagios",$enable_nagios,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_beegfs_client",$enable_beegfs_client,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_lustre_client",$enable_lustre_client,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_genders",$enable_genders,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_magpie",$enable_magpie,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_geopm",$enable_geopm,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_mrsh",$enable_mrsh,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_powerman",$enable_powerman,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_ipmisol",$enable_ipmisol,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_clustershell",$enable_clustershell,$line) ) {
	print OUT $line;
    } elsif ( update_var("enable_mpich_ucx",$enable_mpich_ucx,$line) ) {
	print OUT $line;
    } elsif ($line =~ /^c_ip\[(\d)\]=\S+/) {
	next if ($1 >= $num_computes);
 	print OUT "c_ip[$1]=$compute_ips[$1]\n";
    } elsif ($line =~ /^c_mac\[(\d)\]=\S+/) {
	next if ($1 >= $num_computes);
 	print OUT "c_mac[$1]=$compute_macs[$1]\n";
    } elsif ($line =~ /^c_bmc\[(\d)\]=\S+/) {
	next if ($1 >= $num_computes);
 	print OUT "c_bmc[$1]=$compute_bmcs[$1]\n";
    } elsif ($line =~ /^c_ipoib\[(\d)\]=\S+/) {
	next if ($1 >= $num_computes);
 	print OUT "c_ipoib[$1]=$compute_ipoibs[$1]\n";
    } else {
 	print OUT $line;
    }
}

# Append any additional inputs for larger clusters

if ($num_computes > 4) {
    print OUT "\n# Additional node settings\n";
    for (my $i=4;$i<$num_computes;$i++) {
	printf OUT "c_name[$i]=c%i\n",$i+1;
    }
    print OUT "\n";
    for (my $i=4;$i<$num_computes;$i++) {
	printf OUT "c_ip[$i]=$compute_ips[$i]\n";
    }
    print OUT "\n";
    for (my $i=4;$i<$num_computes;$i++) {
	printf OUT "c_mac[$i]=$compute_macs[$i]\n";
    }
    print OUT "\n";
    for (my $i=4;$i<$num_computes;$i++) {
	printf OUT "c_bmc[$i]=$compute_bmcs[$i]\n";
    }
    print OUT "\n";
    for (my $i=4;$i<$num_computes;$i++) {
	printf OUT "c_ipoib[$i]=$compute_ipoibs[$i]\n";
    }
}

close OUT;
print "Localized cluster input saved to $outputFile\n";
