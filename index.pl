#!/usr/bin/perl

# VMchart - browser-based generator for nice charts of LVM and BTRFS usage across different file servers
# (c) 2011 Christian Herzog <daduke@phys.ethz.ch> and Patrick Schmid <schmid@phys.ethz.ch>
# incremental AJAX loading by Philip Ezhukattil <philipe@phys.ethz.ch> and Claude Becker
# <beckercl@phys.ethz.ch>
# multithreading by Philip Ezhukattil <philipe@phys.ethz.ch> and Claude Becker <beckercl@phys.ethz.ch>
# distributed under the terms of the GNU General Public License version 2 or any later version.
# project website: https://readme.phys.ethz.ch/services/lvmchart/

# 2011/08/04 v1.0 - initial working version
# 2012/04/22 v2.0 - added backend information
# 2012/04/25 v2.1 - added PV change log to detect defective backends
# 2012/07/10 v3.0 - added BTRFS support
# 2012/07/11 v3.1 - added navigation menu
# 2012/07/31 v3.2 - added threads

use strict;
use warnings;
use JSON;
use POSIX qw(ceil strftime);
use MLDBM qw(DB_File);  #to store hashes of hashes
use Clone qw(clone);    #to clone hashes of hashes
use Fcntl;              #to set file permissions
use File::Copy;
use File::Basename;
use threads qw(yield);
use threads::shared;
use Thread::Queue;
use List::MoreUtils qw(uniq);
use Math::Round qw(nearest);
use Data::Dumper;

my $myself = basename($0);
my @servers;
my %info;
my %PVhistory = ();
my $warnings  = '';
my (%VMdata, $UNIT);
my ($markup, $javascript);
my %backends              :shared = ();
my %PVlayout              :shared = ();
my %emptySlices           :shared = ();

my $lastUpdate = strftime "%H:%M:%S %d.%m.%Y", localtime;

my $grandTotal            :shared;
my $grandTotalUsed        :shared;

my $grandFSLevel :shared;
my $grandInFS    :shared;
my $grandInLV    :shared;
my $grandInVG    :shared;
my $grandInPV    :shared;
my $grandUnalloc :shared;
my $grandPVSize  :shared;

#define parameters
use constant NTHREADS => 6;
my $BARSPERCHART   =  8;    #number of LV in bar chart
my $ORGSPERCHART   =  9;    #number of LV in org chart
my $CHARTSPERLINE  =  3;    #number of LV charts in one line
my $MAXCHARTFACTOR = 10;    #max factor in one LV chart
my $GLOBALUNIT     = 'TiB';  #summary data is in TiB
my %labels = (
    'fsfill'  => 'FS filling level',
    'infs'    => 'available in FS',
    'inlv'    => 'available in LVM2 LV',
    'invg'    => 'available in LVM2 VG',
    'inpv'    => 'available in LVM2 PV',
    'unalloc' => 'not allocated',
);

#read hostnames from file
open HOSTS, "hostlist";
while (<HOSTS>) {
    my ($host, $info) = split / - /;
    chomp $info;
    push @servers, $host;
    $info{$host} = $info;
}
close HOSTS;
my $numberOfServers = @servers;

#determine whether we are in HTML or AJAX mode
my $option = $ENV{QUERY_STRING} || '';
if ($option eq 'data'){
    print "Content-type:text/plain\r\n\r\n";
    $| = 1;     # Flush output continuously

    my $Q = Thread::Queue->new;
    my @threads = map threads->create( \&getdata, $Q ), 1 .. NTHREADS;  #create N threads
    $Q->enqueue($_) for @servers;                                       #queue all servers
    $Q->enqueue( (undef) x NTHREADS );                                  #flush queue
    $_->join for @threads;                                              #start threading

    while ($Q->pending()) {                                             #wait till queue is done
        select(undef, undef, undef, 0.1);                               #sleep for 0.1 s
    }
    &getBackends();
} else {
    print "Content-type:text/html\r\n\r\n";
    print html();
}

sub getdata {
    my $Q   = shift;
    my $tid = threads->tid;

    while (my $server = $Q->dequeue) {
        my $frontendInfo;
        my $json_text;
        if (!($json_text = `ssh -o IdentitiesOnly=yes -i /var/www/.ssh/remotesshwrapper root\@$server /usr/local/bin/remotesshwrapper vmchart.pl`)) {
            $warnings .= "could not fetch JSON from server $server! $!<br />\n";
            print "ENDOFELEMENTENDOFELEMENTENDOFELEMENT${warnings}ENDOFSERVER";
            next;
        } else {
            # no autovivification for shared hashrefs
            $backends{global} //= &share({});
            my $json = JSON->new->allow_nonref;
            my $VMdata;
            if (!($VMdata = $json->decode($json_text))) {
                $warnings .= "could not get LVM data from server $server<br />\n";
                print "ENDOFELEMENTENDOFELEMENTENDOFELEMENT${warnings}ENDOFSERVER";
                next;
            }
            %VMdata = %$VMdata;
            next unless (keys %{$VMdata{vgs}});  #skip host if no vgs present

            my $numLVs = 0; #count LV
            foreach my $vg (keys %{$VMdata{vgs}}) {
                foreach my $lv (keys %{$VMdata{$vg}{lvs}}) {
                    $numLVs++;
                }
            }

            my $serverID = $server;
            $serverID    =~ s/-/_/g;        #Google chart API needs underscores
            $UNIT        = $VMdata{unit}; #TiB or GiB comes from the JSON

            if ($VMdata{warning}) {
                $warnings .= "Host $server: ".$VMdata{warning}."<br />\n";
            }

            #populate backend information hash
            foreach my $backend (sort keys %{$VMdata{backends}}) {
                $backends{$backend} //= &share({});
                $backends{$backend}{$server} //= &share({});
                my $j;
                foreach my $slice (sort { $a cmp $b } keys %{$VMdata{backends}{$backend}{slices}}) {
                    $backends{global}{$server} //= &share({});
                    my $vg = $VMdata{backends}{$backend}{slices}{$slice}{vg};
                    $backends{global}{$server}{$vg} //= &share({}); #TODO should move outside of backend loop for local storage
                    $backends{global}{$server}{btrfs} //= &share({});
                    $backends{global}{$server}{zfs} //= &share({});
                    $emptySlices{$backend} //= &share({});
                    $emptySlices{$backend}{$slice} //= &share({});
                    if ($vg eq 'freespace') {
                        my $size   = $VMdata{backends}{$backend}{slices}{$slice}{size};
                        my $vmtype = $VMdata{backends}{$backend}{slices}{$slice}{vmtype};
                        $backends{global}{$server}{$vmtype} //= &share({});
                        $emptySlices{$backend}{$slice}{$vmtype} //= &share({});
                        $emptySlices{$backend}{$slice}{$vmtype}{size} = $size;
                        $emptySlices{$backend}{$slice}{$vmtype}{unit} = $UNIT;
                        $backends{global}{$server}{$vmtype}{slices}   .= "$backend-$slice, \\n";
                    }
                    my $size = units($VMdata{backends}{$backend}{slices}{$slice}{size}, $UNIT, $GLOBALUNIT);
                    $backends{$backend}{$server}{$vg} //= &share({});
                    $backends{$backend}{size}                  += $size;
                    $backends{$backend}{$server}{size}         += $size;
                    $backends{$backend}{$server}{$vg}{size}    += $size;
                    $backends{$backend}{slices}                .= "$slice ($size $UNIT), \\n";
                    $backends{$backend}{$server}{slices}       .= "$slice ($size $UNIT), \\n";
                    $backends{$backend}{$server}{$vg}{slices}  .= "$slice ($size $UNIT), \\n";
                    $backends{global}{$server}{$vg}{slices}    .= "$backend-$slice ($size $UNIT), \\n";
                    $backends{global}{$server}{$vg}{vmtype}     = $VMdata{backends}{$backend}{slices}{$slice}{vmtype};
                    $backends{global}{$server}{$vg}{raidtype}   = $VMdata{backends}{$backend}{slices}{$slice}{raidtype} || '';
                    if ($backends{global}{$server}{$vg}{vmtype} eq 'btrfs') {
                        $backends{global}{$server}{btrfs}{slices} .= "$backend-$slice, \\n";
                    }
                    if ($backends{global}{$server}{$vg}{vmtype} eq 'zfs') {
                        $backends{global}{$server}{zfs}{slices} .= "$backend-$slice, \\n";
                    }
                    $PVlayout{$server} //= &share({});
                    $PVlayout{$server}{$vg} //= &share({});
                    $PVlayout{$server}{$vg}{"$backend-$slice"} = 1;
                }
            }

            my $PVFSLevel = $VMdata{FSLevel}; #get PV data
            my $PVInFS    = $VMdata{inFS} - $PVFSLevel;
            my $PVInLV    = $VMdata{inLV};
            my $PVInVG    = $VMdata{inVG};
            my $PVInPV    = $VMdata{inPV};
            my $unalloc   = $VMdata{unalloc};
            my $PVSize    = $VMdata{size};

            $grandFSLevel += nearest(.01, units($PVFSLevel, $UNIT, $GLOBALUNIT));
            $grandInFS    += nearest(.01, units($PVInFS, $UNIT, $GLOBALUNIT));
            $grandInLV    += nearest(.01, units($PVInLV, $UNIT, $GLOBALUNIT));
            $grandInVG    += nearest(.01, units($PVInVG, $UNIT, $GLOBALUNIT));
            $grandInPV    += nearest(.01, units($PVInPV, $UNIT, $GLOBALUNIT));
            $grandUnalloc += nearest(.01, units($unalloc, $UNIT, $GLOBALUNIT));
            $grandPVSize  += nearest(.01, units($PVSize, $UNIT, $GLOBALUNIT));
            $grandTotal   += nearest(.01, units($PVSize, $UNIT, $GLOBALUNIT));
            $grandTotalUsed += nearest(.01, units($PVFSLevel, $UNIT, $GLOBALUNIT));

            $javascript  .= pvData($serverID, $PVFSLevel, $PVInFS, $PVInLV, $PVInVG, $PVInPV, $unalloc, $PVSize, $UNIT);

            my (%vgs, %lvs, $vgRows, %lvRows, $orgRows, $haveLVM, $haveBTRFS, $haveZFS);
            my $VGslices;
            my $lvGrpOrg  = 0;
            my $orgcount  = 0;
            my $orgChart  = "<div class=\"orgchart\" id=\"org_chart_${serverID}_$lvGrpOrg\"></div>";

            foreach my $vg (reverse sort { $VMdata{pv}{$a}{size} <=> $VMdata{pv}{$b}{size} } keys %{$VMdata{vgs}}) {   #iterate over VGs
                my $VGSize = $VMdata{pv}{$vg}{size};
                my $vmType;
                if ($vg eq 'btrfs') {
                    $vmType = 'btrfs';
                } elsif ($vg eq 'zfs') {
                    $vmType = 'zfs';
                } else {
                    $vmType = 'lvm2';
                }
                if ($vmType eq 'lvm2') {
                    my $VGFSLevel = $VMdata{pv}{$vg}{FSLevel} || 0; #get VG data
                    my $VGInFS    = $VMdata{pv}{$vg}{inFS}    || 0;
                    $VGInFS -= $VGFSLevel;                              #subtract filling level
                    my $VGInLV = $VMdata{pv}{$vg}{inLV} || 0;
                    my $VGInVG = $VMdata{pv}{$vg}{inVG} || 0;

                    $vgs{$vg}{size} = $VGSize;

                    $vgs{$vg}{js} = " {c:[{v: '$vg'},{v: $VGFSLevel, f:'$VGFSLevel $UNIT'},{v: $VGInFS, f:'$VGInFS $UNIT'},{v: $VGInLV, f:'$VGInLV $UNIT'},{v: $VGInVG, f:'$VGInVG $UNIT'}]},";
                    $backends{global}{$server} //= &share({});  #TODO should be handled further up
                    $backends{global}{$server}{$vg} //= &share({});
                    if ($VGslices =  $backends{global}{$server}{$vg}{slices}) {
                        $VGslices = "LUNs for this VG: \\n" . $VGslices;
                        $VGslices = substr $VGslices, 0, -4;
                    } else {
                        $VGslices = "Volume group";
                    }
                    if ($VGInVG > 0 && $vg ne 'freespace') {
                        my $lv       = "free";
                        my $key       = "${lv}_$vg";
                        $orgRows .= "[{v:'$lv<div class=\"child freespace\">$VGInVG $UNIT</div>'},'$vg','free'],\n";
                    }
                } elsif ($vmType eq 'btrfs') {
                    $VGslices = $backends{global}{$server}{$vg}{slices};
                    if ($VGslices) {
                        $VGslices = "LUNs for this volume: \\n" . $VGslices;
                        $VGslices = substr $VGslices, 0, -4;
                    }
                } elsif ($vmType eq 'zfs') {
                    $VGslices = $backends{global}{$server}{$vg}{slices};
                    if ($VGslices) {
                        $VGslices = "devices for this pool: \\n" . $VGslices;
                        $VGslices = substr $VGslices, 0, -4;
                    }
                }
                my $vgName = ($vg eq 'freespace')?'<span class="free">free space</span>':$vg;
                $orgRows  .= "[{v: '$vg',f: '$vgName<div class=\"parent\">$VGSize $UNIT</div>'}, '','$VGslices'],";

                foreach my $lv (reverse sort { $VMdata{pv}{$vg}{$a}{size} <=> $VMdata{pv}{$vg}{$b}{size} } keys %{$VMdata{$vg}{lvs}}) {    #iterate over LVs, sorted by size
                    my $LVFSLevel = nearest(0.01, $VMdata{pv}{$vg}{$lv}{FSLevel});    #get LV data
                    my $LVInFS    = nearest(0.01, $VMdata{pv}{$vg}{$lv}{inFS} - $LVFSLevel);
                    my $LVInLV    = nearest(0.01, $VMdata{pv}{$vg}{$lv}{inLV});
                    my $LVSize    = nearest(0.01, $VMdata{pv}{$vg}{$lv}{size});
                    my $FSType    = nearest(0.01, $VMdata{pv}{$vg}{$lv}{FSType});
                    my $key       = "${lv}_$vg";

                    if ($orgcount && !($orgcount % $ORGSPERCHART)) {  #if org chart is full, create a new one
                        $javascript .= orgChart("${serverID}_$lvGrpOrg", $orgRows);
                        $lvGrpOrg++;
                        $orgChart .= "<br /><br /><div class=\"orgchart\" id=\"org_chart_${serverID}_$lvGrpOrg\"></div>\n";
                        $orgRows   = "[{v:'$vg',f:'$vg<div class=\"parent\">(cont\\'d)</div>'}, '','$VGslices'],\n";
                    }

                    if ($vg ne 'freespace') {   #we don't want VG and LV graphs for free space
                        $lvs{$vmType}{$key}{size} = $LVSize;
                        my $FSinfo = ($vmType eq 'btrfs' || $vmType eq 'zfs')?'':"($vg): $FSType";
                        $lvs{$vmType}{$key}{js} = "{c:[{v: '$lv $FSinfo'},{v: $LVFSLevel, f: '$LVFSLevel $UNIT'},{v: $LVInFS, f: '$LVInFS $UNIT'},{v: $LVInLV, f: '$LVInLV $UNIT'}]},";   #fill LV and org chart data
                    }
                    if ($vg eq 'freespace') {
                        my $LVslices = $backends{global}{$server}{$lv}{slices};
                        if ($LVslices) {
                            $LVslices = "LUNs for this volume: \\n" . $LVslices;
                            $LVslices = substr $LVslices, 0, -4;
                        }
                        $orgRows .= "[{v:'$lv<div class=\"child freespace\">$LVSize $UNIT ($FSType)</div>'},'$vg','$LVslices'],\n";
                    } elsif ($vmType eq 'lvm2') {
                        $haveLVM  = 1;
                        $orgRows .= "[{v:'$lv<div class=\"child\">$LVSize $UNIT ($FSType)</div>'},'$vg','Logical volume'],\n";
                    } elsif ($vmType eq 'btrfs') {
                        $haveBTRFS = 1;
                        my $LVslices = $backends{global}{$server}{$lv}{slices};
                        if ($LVslices) {
                            $LVslices = "LUNs for this volume: \\n" . $LVslices;
                            $LVslices = substr $LVslices, 0, -4;
                        }
                        if (my $raid = $backends{global}{$server}{$lv}{raidtype}) {
                            $raid    = uc($raid);
                            $FSType .= ", $raid";
                        }
                        $orgRows .= "[{v:'$lv<div class=\"child btrfs\">$LVSize $UNIT ($FSType)</div>'},'$vg','$LVslices'],\n";
                    } elsif ($vmType eq 'zfs') {
                        $haveZFS = 1;
                        my $LVslices = $backends{global}{$server}{$lv}{slices};
                        if ($LVslices) {
                            $LVslices = "devices for this pool: \\n" . $LVslices;
                            $LVslices = substr $LVslices, 0, -4;
                        }
                        $orgRows .= "[{v:'$lv<div class=\"child zfs\">$LVSize $UNIT ($FSType)</div>'},'$vg','$LVslices'],\n";
                    }
                    $orgcount++;
                }

            }

            #create VG and LV graphs
            my $maxInVGGraph = 0;
            my $vgcount      = 0;
            my $vgGrpChart   = 0;
            foreach my $vg (reverse sort { $vgs{$a}{size} <=> $vgs{$b}{size} } keys %vgs) {
                next if ($vg eq 'freespace');
                if ($vgcount == 0) {
                    $maxInVGGraph = $vgs{$vg}{size};
                }
                if ( ($vgcount && !($vgcount % $BARSPERCHART))
                    || ($vgs{$vg}{size} && (($maxInVGGraph / $vgs{$vg}{size})) > $MAXCHARTFACTOR) ) {
                        #if VG chart is full or bars get too short, create a new one
                    $javascript .= vgData("${serverID}_$vgGrpChart", $vgRows);
                    $vgGrpChart++;
                    $vgRows  = '';
                    $vgcount = 0;
                    $maxInVGGraph = $vgs{$vg}{size};
                }
                $vgRows .= $vgs{$vg}{js};
                $vgcount++;
            }

            my %GrpChart;
            foreach my $vmType (qw(lvm2 btrfs zfs)) {
                my $maxInLVGraph   = 0;
                my $lvcount        = 0;
                $GrpChart{$vmType} = 0;

                foreach my $lv (reverse sort { $lvs{$vmType}{$a}{size} <=> $lvs{$vmType}{$b}{size} } keys %{$lvs{$vmType}}) {
                    if ($lvcount == 0) {
                        $maxInLVGraph = $lvs{$vmType}{$lv}{size};
                    }
                    if ( ($lvcount && !($lvcount % $BARSPERCHART))
                        || ($lvs{$vmType}{$lv}{size} != 0 && (($maxInLVGraph / $lvs{$vmType}{$lv}{size})) > $MAXCHARTFACTOR) ) {
                            #if LV chart is full or bars get too short, create a new one
                        $javascript .= lvData("${serverID}_$GrpChart{$vmType}", $lvRows{$vmType}, $vmType);
                        $GrpChart{$vmType}++;
                        $lvRows{$vmType} = '';
                        $lvcount = 0;
                        $maxInLVGraph = $lvs{$vmType}{$lv}{size};
                    }
                    $lvRows{$vmType} .= $lvs{$vmType}{$lv}{js};
                    $lvcount++;
                }
            }

            chop $vgRows;   #trim last comma
            chop $lvRows{lvm2}  if ($lvRows{lvm2});
            chop $lvRows{btrfs} if ($lvRows{btrfs});
            chop $lvRows{zfs} if ($lvRows{zfs});
            chop $orgRows;

            $javascript .= vgData("${serverID}_$vgGrpChart", $vgRows) if ($vgRows);
            $javascript .= lvData("${serverID}_$GrpChart{lvm2}",  $lvRows{lvm2},  'lvm2')  if ($haveLVM);
            $javascript .= lvData("${serverID}_$GrpChart{btrfs}", $lvRows{btrfs}, 'btrfs') if ($haveBTRFS);
            $javascript .= lvData("${serverID}_$GrpChart{zfs}", $lvRows{zfs}, 'zfs') if ($haveZFS);
            $javascript .= orgChart("${serverID}_$lvGrpOrg", $orgRows);
            $markup .= chartTable($server, $serverID, $orgChart, $vgGrpChart+1, $GrpChart{lvm2}+1, $GrpChart{btrfs}+1, $GrpChart{zfs}+1, $haveLVM, $haveBTRFS, $haveZFS);

            #print information about this server
            $frontendInfo .= $javascript;
            $frontendInfo .= "ENDOFELEMENT";
            $frontendInfo .= $markup;
            $frontendInfo .= "ENDOFELEMENT";
            $frontendInfo .= "$server";
            $frontendInfo .= "ENDOFELEMENT";
            $frontendInfo .= "$warnings";
            $frontendInfo .= "ENDOFELEMENT";
            $frontendInfo .= "$grandTotal";
            $frontendInfo .= "ENDOFELEMENT";
            $frontendInfo .= "$grandTotalUsed";
            $frontendInfo .= "ENDOFELEMENT";
            $frontendInfo .= "$GLOBALUNIT";
            $frontendInfo .= "ENDOFSERVER";
            print $frontendInfo;

            #clear variables for next server
            $javascript = $markup = $warnings = "";
        }
    }
}

#create backend information orgchart
sub getBackends {
    my $i        = 0;
    my $beGrpOrg = 0;
    my $orgcount = 0;
    $markup      = "<div class=\"orgchart\" id=\"org_chart_backends_0\"></div>\n";
    $javascript  = '';
    my $emptyTable;
    my ($orgRows, $BEslices, $FEslices, $VGslices);

    foreach my $backend (sort keys %backends) {
        my ($class, $j);
        next if ($backend eq 'size' || $backend eq 'global');
        my $backendSize = $backends{$backend}{size};
        $BEslices = "LUNs on this backend: \\n" . $backends{$backend}{slices};
        $BEslices = substr $BEslices, 0, -4;
        $orgRows .= "[{v: '$backend',f: '$backend<div class=\"parent\">$backendSize $GLOBALUNIT</div>'}, '', '$BEslices'],\n";

        foreach my $server (sort keys %{$backends{$backend}}) {
            next if (grep /\b$server\b/, qw(size slices));
            my $serverSize = $backends{$backend}{$server}{size};
            $FEslices = "LUNs for this frontend: \\n" . $backends{$backend}{$server}{slices};
            $FEslices = substr $FEslices, 0, -4;
            $orgRows .= "[{v: '$server-$backend',f: '$server<div class=\"child\">$serverSize $GLOBALUNIT</div>'}, '$backend', '$FEslices'],\n";

            foreach my $vg (sort keys %{$backends{$backend}{$server}}) {
                next if (grep /\b$vg\b/, qw(size slices));
                my $VGsize = $backends{$backend}{$server}{$vg}{size};
                my $vmType = '';
                if ( exists $backends{global}{$server}{$vg}{vmtype} ) {
                    $vmType = $backends{global}{$server}{$vg}{vmtype};
                }
                if ($vmType eq 'btrfs') {
                    $VGslices = "LUNs in BTRFS: \\n" . $backends{$backend}{$server}{$vg}{slices};
                    $VGslices = substr $VGslices, 0, -4;
                } elsif ($vmType eq 'zfs') {
                    $VGslices = "LUNs in ZFS \\n" . $backends{$backend}{$server}{$vg}{slices};
                    $VGslices = substr $VGslices, 0, -4;
                } else {    #LVM
                    $VGslices = "LUNs for this VG: \\n" . $backends{$backend}{$server}{$vg}{slices};
                    $VGslices = substr $VGslices, 0, -4;
                    $vmType = 'lvm';
                }

                if ($orgcount && !($orgcount % $ORGSPERCHART)) {  #if org chart is full, create a new one
                    $javascript .= orgChart("backends_$beGrpOrg", $orgRows);
                    $beGrpOrg++;
                    $markup  .= "<br /><br /><div class=\"orgchart\" id=\"org_chart_backends_$beGrpOrg\"></div>\n";
                    $orgRows  = "[{v: '$backend',f: '$backend<div class=\"parent\">(cont\\'d)</div>'}, '', '$BEslices'],\n";
                    $orgRows .= "[{v: '$server-$backend',f: '$server<div class=\"child\">$serverSize $GLOBALUNIT</div>'}, '$backend', '$FEslices'],\n";
                }
                my $vgName = ($vg eq 'freespace')?'<span class="free">free space</span>':"$vg ($vmType)";
                $orgRows  .= "[{v: '$vg-$backend-$server',f: '$vgName<div class=\"grandchild\">$VGsize $GLOBALUNIT</div>'}, '$server-$backend', '$VGslices'],\n";
                $orgcount++;
            }
        }
        $class = ($i % 2)?'class="bg2"':'class="bg1"';

        foreach my $slice (sort keys %{$emptySlices{$backend}}) {
            foreach my $vm (sort keys %{$emptySlices{$backend}{$slice}}) {
                my $size = $emptySlices{$backend}{$slice}{$vm}{size};
                my $unit = $emptySlices{$backend}{$slice}{$vm}{unit};
                $emptyTable .= "<tr $class><td>$backend</td><td>$slice</td><td>$vm</td><td class=\"r\">$size $unit</td></tr>\n";
                $j = 1;
            }
        }
        $i++ if ($j);
    }

    $javascript .= orgChart("backends_$beGrpOrg", $orgRows) if ($orgcount);
    my $totalChart = pvData('grandtotal', $grandFSLevel, $grandInFS, $grandInLV, $grandInVG, $grandInPV, $grandUnalloc, $grandPVSize, $GLOBALUNIT);

    print "BACKENDS";
    print "$markup" if ($orgcount);
    print "ENDOFELEMENT";
    print "<br /><br /><a name=\"slices\"></a><h3 id=\"avail\" align=\"center\">Available slices</h3><table id=\"avail\" align=\"center\"><tr><th>Backend</th><th>Slice</th><th>Volume Mgmt.</th><th>Size</th></tr>$emptyTable</table>" if ($emptyTable);
    print "ENDOFELEMENT";
    print "$javascript";
    print "ENDOFELEMENT";
    print "$grandTotal";
    print "ENDOFELEMENT";
    print "$grandTotalUsed";
    print "ENDOFELEMENT";
    print "$totalChart";
    print "ENDOFELEMENT";
    print "$GLOBALUNIT";
    print "ENDOFELEMENT";

    #create PV diff log
    my $changes;
    tie(%PVhistory, 'MLDBM', 'PVhistory.db', O_CREAT|O_RDWR, 0666);
    my %PVtemp = %{ clone (\%PVhistory) };  #needed b/c direct modify of tied HoH doesn't work
    #segfaults but still works?????

    foreach my $server (sort keys %PVlayout) {
        foreach my $vg (sort keys %{$PVlayout{$server}}) {
            foreach my $slice (sort keys %{$PVlayout{$server}{$vg}}) {
                if (exists($PVhistory{$server}{$vg}{$slice})) {
                    delete $PVtemp{$server}{$vg}{$slice};
                } else {
                    $changes .= "<tr><td><span class=\"free\">ADD</span> LUN <i>$slice</i></td><td> to VG <i>$vg</i></td><td> on frontend <i>$server</i></td></tr>\n";
                }
            }
        }
    }
    foreach my $server (sort keys %PVtemp) {
        foreach my $vg (sort keys %{$PVtemp{$server}}) {
            foreach my $slice (sort keys %{$PVtemp{$server}{$vg}}) {
                if ($PVtemp{$server}{$vg}{$slice}) {
                    $changes .= "<tr><td><span class=\"remove\">REMOVE</span> LUN <i>$slice</i></td><td> from VG <i>$vg</i></td><td> on frontend <i>$server</i></td></tr>\n";
                }
            }
        }
    }
    %PVhistory = %{ shared_clone(\%PVlayout) };
    untie %PVhistory;

    open OLDLOG, "< changelog";
    my @oldchanges = <OLDLOG>;
    close OLDLOG;

    if ($changes) {
        my $timestamp = POSIX::strftime("%Y/%m/%d %H:%M:%S", localtime);
        $changes      = "$timestamp:<br />$changes";
        print "<table>$changes</table><br /><br />@oldchanges";

        open LOG, "> newlog";
        print LOG "<table>$changes</table><br /><br />\n\n\n@oldchanges";
        close LOG;
        move("newlog", "changelog");
    } else {
        print "@oldchanges";
    }
}


#----------------
sub units {
    my ($value, $unit, $globalunit) = @_;

    return $value if ($unit eq $globalunit);
    if ($globalunit eq 'GB') {
        $value *= 1024;
    } else {
        $value /= 1024;
    }
    return nearest(.01, $value);
}

sub pvData {
    my ($serverID, $PVFSLevel, $PVInFS, $PVInLV, $PVInVG, $PVInPV, $unalloc, $PVSize, $UNIT) = @_;
    $PVFSLevel = nearest(.01, $PVFSLevel);
    $PVInFS =    nearest(.01, $PVInFS);
    $PVInLV =    nearest(.01, $PVInLV);
    $PVInVG =    nearest(.01, $PVInVG);
    $PVInPV =    nearest(.01, $PVInPV);
    $unalloc =   nearest(.01, $unalloc);
    $PVSize =    nearest(.01, $PVSize);

    return <<EOF;
    //pv data
        var pv_data_$serverID = new google.visualization.DataTable(
          {
            cols: [{id:'PV',label:'PV', type:'string'},
                   {id:'FSFill',label:'$labels{"fsfill"}', type:'number'},  // FSLevel
                   {id:'UsedInFS',label:'$labels{"infs"}', type:'number'},  // inFS - FSLevel
                   {id:'inLV',label:'$labels{"inlv"}', type:'number'},      // inLV
                   {id:'inVG', label:'$labels{"invg"}',type:'number'},      // inVG
                   {id:'inPV',label:'$labels{"inpv"}',type:'number'},        // inPV
                   {id:'unalloc',label:'$labels{"unalloc"}',type:'number'}        // unallocated space
          ],
            rows: [{c:[{v:'Disk space'},{v: $PVFSLevel, f: '$PVFSLevel $UNIT'},{v: $PVInFS, f: '$PVInFS $UNIT'},{v: $PVInLV, f: '$PVInLV $UNIT'},{v: $PVInVG, f: '$PVInVG $UNIT'},{v: $PVInPV, f: '$PVInPV $UNIT'},{v: $unalloc, f: '$unalloc $UNIT'}]}
          ]
          });


    //pv chart
        var pv_chart_$serverID = new google.visualization.ColumnChart(document.getElementById('pv_chart_$serverID'));
            pv_chart_$serverID.draw(pv_data_$serverID, {'title':'Total disk space overview',
                                    'backgroundColor':'#eee',
                                    'legend': 'right',
                                    'legendTextStyle': {fontSize:10},
                                    'isStacked': true,
                                    'colors':['#3366cc','#3399ff','magenta','#dc3912','#ff9900','#3a3'],
                                    'vAxis': {'title': '$UNIT','gridlineColor':'#808080'},
                                    'hAxis':{'title':'Total: $PVSize$UNIT'}});
EOF
}

sub vgData {
    my ($serverID, $vgRows) = @_;

    return <<EOF;
    //vg data
        var vg_data_$serverID = new google.visualization.DataTable(
          {
            cols: [{id:'VG',label:'VG', type:'string'},
                   {id:'FSFill', label:'$labels{"fsfill"}',type:'number'},  // FSLevel
                   {id:'UsedInFS', label:'$labels{"infs"}',type:'number'},  // inFS - FSLevel
                   {id:'inLV',label:'$labels{"inlv"}', type:'number'},      // inLV
                   {id:'inVG',label:'$labels{"invg"}', type:'number'}       // inVG
          ],
        rows: [$vgRows
                  ]
          });


    //vg chart
        var vg_chart_$serverID = new google.visualization.ColumnChart(document.getElementById('vg_chart_$serverID'));
        vg_chart_$serverID.draw(vg_data_$serverID, {'title':'Usage of Volume Groups',
                                'backgroundColor':'#eee',
                                'legend': 'right',
                                'legendTextStyle': {fontSize:10},
                                'isStacked': true,
                                'colors':['#3366cc','#3399ff','magenta','#dc3912'],
                                'vAxis': {'title': '$UNIT','gridlineColor':'#808080'}});
EOF
}

sub lvData {
    my ($serverID, $lvRows, $vmType) = @_;

    my $output =<<EOF;
    //lv data
        var lv_data_${vmType}_${serverID} = new google.visualization.DataTable(
          {
            cols: [{id:'LV',label:'LV', type:'string'},
                   {id:'FSFill', label:'$labels{"fsfill"}',type:'number'},  // FSLevel
                   {id:'UsedInFS', label:'$labels{"infs"}',type:'number'}   // inFS - FSLevel
EOF
    if ($vmType eq 'lvm2') {
        $output .=<<EOF
                    , {id:'inLV',label:'$labels{"inlv"}', type:'number'}       // inLV
EOF
    }

    $output .=<<EOF;
          ],
        rows: [$lvRows
                  ]
          });


    //lv chart
        var lv_chart_${vmType}_${serverID} = new google.visualization.ColumnChart(document.getElementById('lv_chart_${vmType}_${serverID}'));
        lv_chart_${vmType}_${serverID}.draw(lv_data_${vmType}_${serverID}, {'title':'Usage of Logical Volumes',
                                    'backgroundColor':'#eee',
                                    'legend': 'right',
                                    'legendTextStyle': {fontSize:10},
                                    'isStacked': true,
                    'colors':['#3366cc','#3399ff','magenta','#dc3912'],
                                    'vAxis': {'title': '$UNIT', 'gridlineColor':'#808080'}});
EOF
    return $output;
}

sub orgChart {
    my ($serverID, $orgRows) = @_;

    return <<EOF;
    //orgchart data
        var org_data_$serverID = new google.visualization.arrayToDataTable([
            ['Name', 'Parent', 'Tooltip'],
            ['', '', ''],
            $orgRows
          ]);


    //orgchart chart
        var org_chart_$serverID = new google.visualization.OrgChart(document.getElementById('org_chart_$serverID'));
            org_chart_$serverID.draw(org_data_$serverID, {allowHtml: true});
EOF
}

sub chartTable {
    my ($server, $serverID, $orgChart, $vgGrpChart, $lvGrpChart, $btrGrpChart, $zfsGrpChart, $haveLVM, $haveBTRFS, $haveZFS) = @_;
    my ($chart, %chartRows, %IDs);

    for my $id (0..$vgGrpChart-1) {
        push @{$IDs{lvm2}}, "vg_chart_${serverID}_$id";
    }
    for my $id (0..$lvGrpChart-1) {
        push @{$IDs{lvm2}}, "lv_chart_lvm2_${serverID}_$id";
    }
    for my $id (0..$btrGrpChart-1) {
        push @{$IDs{btrfs}}, "lv_chart_btrfs_${serverID}_$id";
    }
    for my $id (0..$zfsGrpChart-1) {
        push @{$IDs{zfs}}, "lv_chart_zfs_${serverID}_$id";
    }

    foreach my $vmType (qw(lvm2 btrfs zfs)) {
        my $rows = ceil(scalar @{$IDs{$vmType}} / $CHARTSPERLINE) || 0;
        my $num  = 0;
        for my $row (1..$rows) {
            $chartRows{$vmType} .= "<tr>";
            for my $chart (1..$CHARTSPERLINE) {
                my $td = ($IDs{$vmType}[$num])?"<div class=\"chart\" id=\"$IDs{$vmType}[$num]\"></div>":"&nbsp;";
                $chartRows{$vmType} .= "<td>$td</td>";
                $num++;
            }
            $chartRows{$vmType} .= "</tr>";
        }
    }

    my $LVMchart   = '';
    my $BTRFSchart = '';
    my $ZFSchart = '';
    if ($haveLVM) {
        $LVMchart =<<EOF
      <tr><td><h2>LVM2 overview</h2></td></tr>
        $chartRows{lvm2}
EOF
    }
    if ($haveBTRFS) {
        $BTRFSchart =<<EOF
      <tr><td><h2>BTRFS overview</h2></td></tr>
        $chartRows{btrfs}
EOF
    }
    if ($haveZFS) {
        $ZFSchart =<<EOF
      <tr><td><h2>ZFS zpool overview</h2></td></tr>
        $chartRows{zfs}
EOF
    }

    return <<EOF;
      <tr><td colspan="3" class="host"><a name="$server"></a>Host $server ($info{$server})</td></tr>
      <tr><td><h2>Disk space overview</h2></td></tr>
      <tr>
        <td>
          <div class="chart" id="pv_chart_$serverID"></div>
        </td>
      </tr>
      $LVMchart
      $BTRFSchart
      $ZFSchart
      <tr><tr><td><h2>Volume overview</h2></td></tr>
       <td colspan="3">
       $orgChart
        </td>
      </tr>
      <tr><td colspan="3"><hr /></td></tr>
EOF
}

sub html {
    my $javascript = javascript();
    my $css        = css();

    return <<EOF;
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
    <meta http-equiv="content-type" content="text/html; charset=utf-8"/>
    <title>
      VMchart - LVM and BTRFS Monitoring
    </title>
    <script type="text/javascript" src="https://www.google.com/jsapi"></script>
    <script type="text/javascript">
        $javascript
    </script>
    <style type="text/css">
        $css
    </style>
 </head>
  <div id="navigation">go to: <span id="linklist"><a href="#frontends">Frontends</a> [<span id="felist"> </span>]</span><span id="total"></span></div>
  <div class="header"><a href="https://readme.phys.ethz.ch/services/lvmchart/">VMchart - LVM and BTRFS Monitoring</a></div>
  <body onload="init();">
    <div id="message"></div>
    <div id="grandtotal" style="display: none;">
        <a name="grandtotal"></a>
        <h1 align="center">Grand total</h1>
        <h3 align="center">Last update: $lastUpdate</h3>
        <div id="totalchart" align="center"></div>
    </div>
    <div align="center" id="data"><a name="frontends"></a><h1>Frontend information</h1></div>
    <div id="javascr"></div>
    <div align="center" id="backends"></div>
    <div id="emptySlices"></div>
    <hr />
    <a name="log"></a><div align="left" id="changes"></div>
    <!--[if !IE]>-->
    <a name="warnings"></a><div id="warnings"></div>
    <!--<![endif]-->
    <!--[if IE]>
    <div id="warnings">Please make sure you have Internet Explorer's compatibility mode disabled.<br /></div>
    <![endif]-->
</body>
</html>
EOF
}

sub css {
    return <<EOF;
body {
    background: #eee;
    font-family: Arial;
    border: 0;
    padding: 0;
    margin: 0;
    font-size: 90%;
}

a {
    text-decoration: none;
    color: #555;
}

a[name] {
    padding-top: 40px;
}

.header {
    font-size: 240%;
    font-weight: bold;
    text-align: center;
    padding-top: 40px;
}

#navigation {
    padding: 4px;
    margin: 0;
    position: fixed;
    background: #444;
    color: #fff;
    border-bottom: 1px solid #888;
    width: 100%;
    z-index: 1000;
}

#navigation a {
    font-weight: bold;
    color: #bbb;
}

#felist {
    font-size: 80%;
}

#total {
    float: right;
    padding-right: 10px;
}

h2 {
    border-bottom: 1px solid #aaa;
    font-size: 80%;
}

hr {
    width: 99%;
}

#warnings {
    color: red;
}

td.host {
    font-weight: bold;
    font-size: 150%;
}

#message {
    padding-top: 10px;
    color: green;
    font-weight: bold;
    text-align: center;
}

#counter {
}

div.chart {
    width: 450px;
    height: 350px;
}

div.parent {
    color:#dc3912;
    font-style:italic;
}

div.child {
    color:#880088;
    font-style:italic;
}

div.btrfs {
    color:#000088;
}

div.zfs {
    color:#000088;
}

div.freespace {
    color:#0c0;
}

div.grandchild {
    color:#000088;
    font-style:italic;
}

div#changes {
    padding-left: 20px;
    font-size: 80%;
}

span.free {
    color:#0d0;
    font-weight: bold;
}

span.remove {
    color:#f00;
    font-weight: bold;
}

#avail {
    padding-left: 20px;
}

#avail th {
    border-bottom: 2px solid #333;
    border-right: 1px solid #aaa;
}

#avail tr.bg1 {
    background-color: #ddd;
}

#avail tr.bg2 {
    background-color: #bbb;
}

#avail td {
    border-bottom: 1px solid #aaa;
    border-right: 1px solid #aaa;
    padding: 3px;
}

#avail .r {
    text-align: right;
}
EOF
}

sub javascript {
    return <<EOF;
    google.load('visualization', '1', {packages: ['corechart', 'orgchart'], 'language': 'ch'});

    var numberOfServersDisplayed = 0;
    var req = (window.XMLHttpRequest) ? new XMLHttpRequest() : new ActiveXObject("Microsoft.XMLHTTP"); // Create Ajax request object

    function init(){
        //Use ajax to load server data
        ajaxLoad("$myself?data", ajaxOnResult);
    }

    function ajaxLoad(url, callback){
        req.open("GET", url, true);
        req.send(null);

        req.onreadystatechange = callback;                  //Start ajaxOnResult function after the stream
        window.setTimeout( function() {ajaxOnProgress(req);},500);
    }

    function ajaxOnProgress(req) {
        if (req.readyState != 4) {                        //while the data are received
             var msg = document.getElementById("message");
             if(msg.innerHTML == ''){
              msg.innerHTML = '<div><img src="spinner.gif" /><div id="counter">Loading Server 1 of $numberOfServers</div></div>';
             }
            ajaxDisplayServer();
            window.setTimeout( function() {ajaxOnProgress(req);},500);
        }
    }

    function ajaxDisplayServer(){
        if(req.responseText.match(/ENDOFSERVER/g)){
            var server = req.responseText.split(/ENDOFSERVER/g);        //Split the stream into individual servers
            var numberOfServersReceived = server.length -1;             //the number of servers in the array

            for (i=numberOfServersDisplayed; i< numberOfServersReceived; i++){          //iterate over received server data
                var serverdata = server[i].split(/ENDOFELEMENT/g);                      //Split into elements(js/markup/name/wanings)
                var js=serverdata[0];
                var markup=serverdata[1];
                var servername=serverdata[2];
                var warnings=serverdata[3];
                var total=serverdata[4];
                var totalUsed=serverdata[5];
                var unit=serverdata[6];

                document.getElementById('warnings').innerHTML += warnings;

                if (servername.length > 0) {
                    var div=document.createElement('div');                                  //create container for new table
                    div.innerHTML += "<table class='table'>" + markup + "</table>";         //workaround for friggin IE that can't dynamically modify tables
                    document.getElementById('data').appendChild(div);                       //load new table into DOM

                    var javascr=document.getElementById('javascr'); //javascript element
                    var jsid = 'js'+i;
                    var JSchild=document.createElement('script');   //create new js block
                    JSchild.type='text/javascript';
                    JSchild.text=js;
                    JSchild.id = jsid;
                    javascr.appendChild(JSchild);                   //and append it
                    eval(document.getElementById(jsid).innerHTML);  //FF needs explicit eval

                    document.getElementById('felist').innerHTML +=  "<a href=\\"#" + servername + "\\">" + servername + "</a> | ";  //populate link list + warnings
                    document.getElementById('total').innerHTML =  totalUsed + " / " + total + " " + unit;  //show grand total
                    document.getElementById('message').innerHTML = "<div><img src=\\"spinner.gif\\" /><div id=\\"counter\\">Loading Server " + parseInt(numberOfServersReceived+1) + " of $numberOfServers</div></div>";
                }
                numberOfServersDisplayed++;
            }
        }
    }

    function ajaxOnResult() {
        if ((req.readyState == 4) && (req.status == 200 || req.status == 0)) {  //after all data has come in
            ajaxDisplayServer();                                                //make double sure all server data has been processed
            document.getElementById('message').style.display = 'none';     //hide server countdown
            var linklist = document.getElementById('felist').innerHTML;         //clean up server link list
            linklist=linklist.slice(0,-2);
            document.getElementById('felist').innerHTML = linklist;

            var backends = req.responseText.split(/BACKENDS/g);                 //get backend + changelog information
            var content = backends[1].split(/ENDOFELEMENT/g);
            var markup = content[0];
            var emptyslices = content[1];
            var javascript = content[2];
            var total = content[3];
            var totalUsed = content[4];
            var totalChart = content[5];
            var unit = content[6];
            var changes = content[7];
            var warnings = document.getElementById('warnings').innerHTML;
            var usedPercent = (100 / total * totalUsed).toFixed(1);

            if (markup.length > 0) {                                            //we have backends!
                document.getElementById('backends').innerHTML += '<a name="backends"></a><h1>Backend overview</h1>'+markup;
                document.getElementById('linklist').innerHTML += " • <a href=\\"#backends\\">Backends</a>";
            }

            if (emptyslices.length > 0) {                                       //we have free slices
                document.getElementById('emptySlices').innerHTML = emptyslices;
                document.getElementById('linklist').innerHTML += " • <a href=\\"#slices\\">Available slices</a>";
            }

            if (changes.length > 0) {                                           //we have a changelog
                document.getElementById('changes').innerHTML += '<h1>PV change log</h1>'+changes;
                document.getElementById('linklist').innerHTML += " • <a href=\\"#log\\">Volume history</a>";
            }

            if (warnings.length > 0) {                                           //we have a changelog
                document.getElementById('linklist').innerHTML += " • <a href=\\"#warnings\\">Warnings</a>";
            }


            document.getElementById('total').innerHTML =  '<a href="#grandtotal">' + totalUsed + " / " + total + " " + unit + ' (' + usedPercent + '%)</a>';  //show grand total

            var totalchart = document.getElementById('totalchart');
            totalchart.innerHTML = '<div id="pv_chart_grandtotal" class="chart" style="position: relative;">';
            document.getElementById('grandtotal').style.display = 'block';

            var javascr=document.getElementById('javascr'); //javascript element
            var JSchild=document.createElement('script');   //create new js block
            JSchild.type='text/javascript';
            JSchild.text=javascript + totalChart;
            var jsid = 'jsbackend';
            JSchild.id = jsid;
            javascr.appendChild(JSchild);                   //and append it
            eval(document.getElementById(jsid).innerHTML);  //FF needs explicit eval

        }
    }
EOF
}
