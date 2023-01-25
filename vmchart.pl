#!/usr/bin/perl -w

# VMchart - browser-based generator for nice charts of LVM and BTRFS usage across different file servers
# (c) 2021 Christian Herzog <daduke@phys.ethz.ch> and Patrick Schmid <schmid@phys.ethz.ch>
# incremental AJAX loading by Philip Ezhukattil <philipe@phys.ethz.ch> and Claude Becker
# <beckercl@phys.ethz.ch>
# distributed under the terms of the GNU General Public License version 2 or any later version.
# project website: http://wiki.phys.ethz.ch/readme/lvmchart

#TODO
#btrfs on LVM!!!
#btrfs subvolumes?
#zfs on iSCSI devices
#zfs datasets?


use strict;
use Math::Round qw(nearest);
use JSON;
use File::Glob ':bsd_glob';
use Data::Dumper;

my %VMdata;	#JSON data format
# VMdata{pv}{vg}{lv}
#     |   |   |
#     |	  |   -size
#     |	  |   -inLV
#     |	  |   -inFS
#     |	  |   -FSLevel
#     |	  |
#     |	  -lvs
#     |	  -size
#     |	  -sum := inVG + inLV + inFS
#     |   -inVG
#     |   -inLV
#     |   -inFS
#     |   -FSLevel
#     |
#     -vgs
#     -size
#     -sum := unalloc + inPV + inVG + inLV + inFS
#     -unalloc
#     -inPV
#     -inVG
#     -inLV
#     -inFS
#     -FSLevel
#     |
#     -unit
#     -warning
#     |
#     -backends{backend}{slices}{slice}
#                                |
#                                -vg
#                                -size
#                                -vmtype

my $WARNINGPERCENTAGE = 0.5;	#percentage threshold for size mismatch warnings;
my ($UNIT, $PVpattern, @excludeVG);
my @takenSlices;   #iSCSI slices that have been assigned to LVM or BTRFS

if (-e "/opt/remotesshwrapper/vmchart.conf") {	#try to read config file
	open CONF, "/opt/remotesshwrapper/vmchart.conf";
	$UNIT = <CONF>;
	chomp $UNIT;


    #check for device regexp
    my $nextLine = <CONF>;
    if ($nextLine =~ m#/dev/#) {
        chomp($PVpattern = $nextLine);
    } else {
        push @excludeVG, $nextLine;
    }

	push @excludeVG, <CONF>;
	chomp @excludeVG;
	close CONF;
} else {
	$UNIT = 'g';	#g or t for Gb or Tb
	@excludeVG = qw(vg0);	#exclude system vg0
}

$VMdata{'unalloc'} = $VMdata{'inPV'} = $VMdata{'inVG'} = $VMdata{'inLV'} = $VMdata{'inFS'} = 0;
#BTRFS support
if (`which btrfs`) {
    my %btrfs;
    my $btrfsInfo = `btrfs fi show --all-devices 2>/dev/null`;
    my %deviceList;
    my @completeList = bsd_glob("/dev/iscsi/*");  #get bkpX-lun-Y -> sdXY mapping
    my @relevantList = grep { $_ =~ /$PVpattern/ } @completeList;
    foreach my $device (@relevantList) {
        my $link = readlink($device);
        $link =~ s#\.\./##;
        $deviceList{$link} = $device;
    }
    foreach my $fs (split /\n\n/, $btrfsInfo) {
        my @lines = split /\n/, $fs;
        my ($fsInfo) = shift @lines;
        my ($total) = shift @lines;
        if ($total) {
            $VMdata{'vgs'}{'btrfs'}=1;
            my @devices;
            my ($label, $uuid) = $fsInfo =~ /Label: '([^']+)' +uuid: +(.+)$/;
            my ($numDevices, $fsUsedNum, $fsUsedUnit) = $total =~ /Total devices +(\d+) +FS bytes used +([\d.]+)(\w+)/;
            my $fsUsed = units($fsUsedNum, $fsUsedUnit);
            my $numChunks = 0;
            my ($id, $sizeNum, $sizeUnit, $usedNum, $usedUnit, $device);
            $VMdata{'FSLevel'} += nearest(.01, $fsUsed);
            $VMdata{'pv'}{'btrfs'}{$label}{'FSLevel'} = nearest(.01, $fsUsed);
            $VMdata{'pv'}{'btrfs'}{$label}{'inLV'} = 0;
            $VMdata{'pv'}{'btrfs'}{$label}{'FSType'} = 'btrfs';
            foreach my $chunk (@lines) {
                if (($id, $sizeNum, $sizeUnit, $usedNum, $usedUnit, $device) = $chunk =~ /devid +(\d+) +size +([\d.]+)(\w+) +used +([\d.]+)(\w+) +path +(\S+)$/) {
                    my $used = units($usedNum, $usedUnit);
                    my $size = units($sizeNum, $sizeUnit);
                    if (my ($bd) = $device =~ m#/dev/(sd\w+)#) {    #BTRFS shows us /dev/sdX, but we want iSCSI devices
                        $device = $deviceList{$bd};
                    }
                    push @devices, $device;
                    $btrfs{$label}{$device} = $size;
                    $numChunks++;

                    if (my ($backend, $slice) = $device =~ m#$PVpattern#) {
                        push @takenSlices, "$backend-$slice";
                    }
                }
            }

            my $isRAID1 = 0;
            my @mounts = `mount -t btrfs`;  #find mount point for filesystem - is there a better way?
            my $mounted = '';
            my $mountUsed;
            foreach my $mount (@mounts) {
                my ($dev, $mountpoint) = $mount =~ m#(\S+) +on +(\S+) +type#;
                if (grep /^$dev$/, @devices) {
                    $mounted = $mountpoint;
                }
            }
            if ($mounted) {
                my @mountInfo = `btrfs fi df $mounted`;
                    foreach my $line (@mountInfo) {
                        if (my ($type, $raidLevel, $totalNum, $totalUnit, $usedNum, $usedUnit) = $line =~ /(\w+), ([^:]+): +total=([\d.]+)(\w*), used=([\d.]+)(\w*)/) {
                        my $used = units($usedNum, $usedUnit);
                        $mountUsed += $used;
                        if ($type eq 'Data' && $raidLevel eq 'RAID1') {
                            $isRAID1 = 1;
                        }
                    }
                }
            }

            foreach my $device (@devices) {
                my $size = $btrfs{$label}{$device};
                if ($PVpattern) { #create PV overview
                    if (my ($backend, $slice) = $device =~ m#$PVpattern#) {
                        $VMdata{'backends'}{$backend}{'slices'}{$slice}{'size'} = nearest(.01, $size);
                        $VMdata{'backends'}{$backend}{'slices'}{$slice}{'vg'} = $label;
                        $VMdata{'backends'}{$backend}{'slices'}{$slice}{'vmtype'} = 'btrfs';
                        $VMdata{'backends'}{$backend}{'slices'}{$slice}{'raidtype'} = 'raid1' if ($isRAID1);
                    }
                }
                if ($isRAID1) {
                    $size /= 2;
                }

                $VMdata{'inFS'} += nearest(.01, $size);
                $VMdata{'size'} += nearest(.01, $size);	#add to grand total
                $VMdata{'btrfs'}{'lvs'}{$label}=1;

                $VMdata{'pv'}{'btrfs'}{'size'} += nearest(.01, $size);
                $VMdata{'pv'}{'btrfs'}{$label}{'size'} += nearest(.01, $size);
                $VMdata{'pv'}{'btrfs'}{$label}{'inFS'} += nearest(.01, $size);
            }

            if ( $mountUsed && $fsUsed && (($mountUsed - $fsUsed) / $mountUsed) > $WARNINGPERCENTAGE )  {
                $VMdata{'warning'} .= "BTRFS size differs for $label ($mountUsed <-> $fsUsed)!\n";

            }
            if ($numChunks != $numDevices) {
                $VMdata{'warning'} .= "BTRFS number of slices differs for $label ($numChunks <-> $numDevices)!\n";
            }


        }
    }
}

#ZFS support
if (`which zfs`) {
    my %zfs;
    my $zpoolInfo = `zpool list -H 2>/dev/null`;
    my @zpoolInfo = split "\n", $zpoolInfo;
    if (@zpoolInfo) {
        $VMdata{'vgs'}{'zfs'}=1;
        my $backend = `hostname`;   #TODO fix for ZFS on iSCSI
        chomp $backend;
        foreach my $line (@zpoolInfo) {
            my ($poolName, $poolSize, $rest) = $line =~ /^(\S+)\s+([\d.]+)([MGT])\s+(.+)/;
            my $poolDetails = `zfs list -H $poolName`;

            my ($name, $used, $usedUnit, $avail, $availUnit, $refer, $referUnit, $mountpoint) = $poolDetails =~ /^(\S+)\s+([\d.]+)([KMGT])\s+([\d.]+)([KMGT])\s+([\d.]+)([KMGT])\s+(.+)$/;
            $used = units($used, $usedUnit);
            $avail = units($avail, $availUnit);
            my $size = $used + $avail;
            $VMdata{'FSLevel'} += nearest(.01, $used);
            $VMdata{'pv'}{'zfs'}{$name}{'FSLevel'} = nearest(.01, $used);
            $VMdata{'pv'}{'zfs'}{$name}{'inFS'} = nearest(.01, $size);
            $VMdata{'pv'}{'zfs'}{$name}{'size'} = nearest(.01, $size);
            $VMdata{'pv'}{'zfs'}{$name}{'inLV'} = 0;
            $VMdata{'pv'}{'zfs'}{$name}{'FSType'} = 'zfs';

            $VMdata{'pv'}{'zfs'}{'size'} += nearest(.01, $size);

            $VMdata{'inFS'} += nearest(.01, $size);
            $VMdata{'size'} += nearest(.01, $size);	#add to grand total
            $VMdata{'zfs'}{'lvs'}{$name}=1;

            my @deviceInfo = `zpool status -P $poolName`;
            my @devices = grep { $_ =~ /\/dev\// } @deviceInfo;
            foreach my $device (@devices) {
                my ($path, $dev, $rest) = $device =~ /.+(\/dev\/disk\/by-.+\/)(\S+) (.+)/;
                my $devSize = `blockdev --getsize64 $path$dev` / (1024*1024*1024);
                $devSize = units($devSize, 'G');
                $VMdata{'backends'}{$backend}{'slices'}{$dev}{'size'} = nearest(.01, $devSize);
                $VMdata{'backends'}{$backend}{'slices'}{$dev}{'vg'} = $name;
                $VMdata{'backends'}{$backend}{'slices'}{$dev}{'vmtype'} = 'zfs';
            }
        }
    }
}


#get PV
my $pvs = `pvs --units=$UNIT --nosuffix --nohead --separator ^`;
my @pvs = split /\n/, $pvs;

$VMdata{'inPV'} = 0;
if (@pvs) {
    foreach my $pv (@pvs) {	#collect PV data
        my ($lun, $vg, $lvmversion, $pvattrs, $pvsize, $free) = split /\^/, $pv;
        $vg ||= 'freespace';
        $vg =~ s/\s//g;
        next if (grep /\b$vg\b/, @excludeVG);	#skip exclude VG from config file
        $VMdata{'vgs'}{$vg}=1;
        $VMdata{'size'} += nearest(.01, $pvsize);	#add to grand total

        if ($PVpattern) { #create PV overview
            if (my ($backend, $slice) = $lun =~ m#$PVpattern#) {
                $VMdata{'backends'}{$backend}{'slices'}{$slice}{'size'} = nearest(.01, $pvsize);
                $VMdata{'backends'}{$backend}{'slices'}{$slice}{'vg'} = $vg;
                $VMdata{'backends'}{$backend}{'slices'}{$slice}{'vmtype'} = 'lvm';

                my $device = "$backend-$slice";
                push @takenSlices, $device;  #add slice to taken list
            }
        }
        if ($vg eq 'freespace') {   #LVM2 LUNs not assigned to any VG
            $VMdata{'pv'}{'freespace'}{'size'} += nearest(.01, $pvsize);
            $VMdata{'pv'}{'freespace'}{'inVG'} += nearest(.01, $pvsize);
            $VMdata{'inPV'} += $pvsize;
            $VMdata{'freespace'}{'lvs'}{'lvm'}=1;
            $VMdata{'pv'}{'freespace'}{'lvm'}{'size'} += nearest(.01, $pvsize);
            $VMdata{'pv'}{'freespace'}{'lvm'}{'inLV'} = 0;
            $VMdata{'pv'}{'freespace'}{'lvm'}{'inFS'} = 0;
            $VMdata{'pv'}{'freespace'}{'lvm'}{'FSLevel'} = 0;
            $VMdata{'pv'}{'freespace'}{'lvm'}{'FSType'} = 'lvm';
        }
    }
}

my @allSlices = </dev/iscsi/*>; #treat unassigned iSCSI slices
foreach my $slice (@allSlices) {
    if (my ($backend, $device) = $slice =~ m#$PVpattern#) {
        next if (grep /\b$backend-$device\b/, @takenSlices);
        my $rawSize = `sfdisk -s $slice`;
        my $size = units($rawSize, '');
        $VMdata{'backends'}{$backend}{'slices'}{$device}{'size'} = nearest(.01, $size);
        $VMdata{'backends'}{$backend}{'slices'}{$device}{'vg'} = 'freespace';
        $VMdata{'backends'}{$backend}{'slices'}{$device}{'vmtype'} = 'unallocated';
        $VMdata{'unalloc'} += $size;
        $VMdata{'size'} += $size;

        $VMdata{'pv'}{'freespace'}{'size'} += nearest(.01, $size);
        $VMdata{'pv'}{'freespace'}{'inVG'} += nearest(.01, $size);
        $VMdata{'freespace'}{'lvs'}{'unallocated'}=1;
        $VMdata{'pv'}{'freespace'}{'unallocated'}{'size'} += nearest(.01, $size);
        $VMdata{'pv'}{'freespace'}{'unallocated'}{'inLV'} = 0;
        $VMdata{'pv'}{'freespace'}{'unallocated'}{'inFS'} = 0;
        $VMdata{'pv'}{'freespace'}{'unallocated'}{'FSLevel'} = 0;
        $VMdata{'pv'}{'freespace'}{'unallocated'}{'FSType'} = 'unallocated';
    }
}
#populate freespace vg if we have unallocated slices
$VMdata{'vgs'}{'freespace'}=1 if $VMdata{'freespace'}{'lvs'}{'unallocated'};

if (!keys %{$VMdata{'vgs'}}) {
	$VMdata{'warning'} .= "no volume management found!";
	my $json = JSON->new->allow_nonref;
	my $json_text   = $json->pretty->encode(\%VMdata);
	print "$json_text";
	exit;
}

foreach my $vg (sort keys %{$VMdata{'vgs'}}) {	#iterate over VG
  next if (grep /\b$vg\b/, qw(btrfs zfs freespace)); #BTRFS, ZFS and free slices are treated separately
	my $vgs = `vgs --units=$UNIT --nosuffix --nohead --separator ^ $vg` || die "couldn't get vgs numbers!";
	chomp $vgs;
	my ($vgname, $vgpvs, $vglvs, $snapshots, $vgattrs, $vgsize, $free) = split /\^/, $vgs;
	$vgname =~ s/\s//g;

	$VMdata{'pv'}{$vgname}{'size'} = nearest(.01, $vgsize);
	$VMdata{'pv'}{$vgname}{'inVG'} = nearest(.01, $free);
	$VMdata{'inVG'} += nearest(.01, $free);
	$VMdata{'pv'}{$vgname}{'inLV'} = 0;
	$VMdata{'pv'}{$vgname}{'inFS'} = 0;

	my $lvs = `lvs --units=$UNIT --nosuffix --nohead --separator ^ $vg`;
	chomp $lvs;
	my @lvs = split /\n/, $lvs;
	foreach my $lv (sort @lvs) {	#iterate over LV
		my ($lvname, $lvvg, $lvattrs, $lvsize) = split /\^/, $lv;
		$lvname =~ s/\s//g;
		$VMdata{$vgname}{'lvs'}{$lvname}=1;
		$VMdata{'pv'}{$vgname}{$lvname}{'size'} = nearest(.01, $lvsize);
		my $lvname1 = $lvname;
		$lvname1 =~ s/-/--/g;	#Linux device mapper uses two hyphens

		my $fsinfo = `df -P /dev/mapper/$vgname-$lvname1` || warn "couldn't get FS info!";	#for FS info, try df first
		my @fsinfo = split /\n/, $fsinfo;
		my ($fsname, $fssize, $fsused, $fsfree, $fsfill, $mount) = split /\s+/, $fsinfo[1];
        my $fsType;
		if ($fsname ne 'udev') {	#ok if FS is mounted
            $fssize = units($fssize, '');
            $fsused = units($fsused, '');
            my $mountOpts = `mount | grep /dev/mapper/$vgname-$lvname1`;
            ($fsType) = $mountOpts =~ /type (\S+) /;
		} else {	#if it isn't...
				my $fsInfo = `dd if=/dev/mapper/$vgname-$lvname1 count=1 bs=4k 2>/dev/null | file -`;	#try guessing FS
				($fsType) = $fsInfo =~ /^.+ ([a-zA-Z0-9]+) file(system)? .+$/;
				if ($fsType =~ /ext./) {	#if it's ext[234]
						my @extInfo = `tune2fs -l /dev/mapper/$vgname-$lvname1`;	#try tune2fs
						my %extInfo;
						foreach my $line (@extInfo) {
								if (my ($key, $value) = $line =~ /^(.+):\s+(\d+)$/) {
										$extInfo{$key} = $value;
								}
						}
						my $factor = $extInfo{'Block size'} / 1024;	#calculate FS size from block sizes and counts
						$fssize = units($factor * $extInfo{'Block count'}, '');
						$fsused = units($factor * ($extInfo{'Block count'} - $extInfo{'Free blocks'}), '');
				} elsif ($fsType eq 'swap') {	#swap space is always 'full'
						$fssize = $lvsize;
						$fsused = $lvsize;
				} else {	#unknown unounted FS => no info
						$fssize = 0;
						$fsused = 0;
				}
		}

		$VMdata{'pv'}{$vgname}{$lvname}{'inLV'} = nearest(.01, $lvsize-$fssize);	#fill LV info
		$VMdata{'pv'}{$vgname}{$lvname}{'inFS'} = nearest(.01, $fssize);
		$VMdata{'pv'}{$vgname}{$lvname}{'FSLevel'} = nearest(.01, $fsused);
		$VMdata{'pv'}{$vgname}{$lvname}{'FSType'} = $fsType;

		$VMdata{'pv'}{$vgname}{'inLV'} += nearest(.01, $lvsize-$fssize);	#fill VG sum
		$VMdata{'pv'}{$vgname}{'inFS'} += nearest(.01, $fssize);
		$VMdata{'pv'}{$vgname}{'FSLevel'} += nearest(.01, $fsused);

		$VMdata{'inLV'} += nearest(.01, $lvsize-$fssize);	#fill PV sum
		$VMdata{'inFS'} += nearest(.01, $fssize);
		$VMdata{'FSLevel'} += nearest(.01, $fsused);
	}
	#VG sanity checks
	my $sum = $VMdata{'pv'}{$vgname}{'inVG'} + $VMdata{'pv'}{$vgname}{'inLV'} + $VMdata{'pv'}{$vgname}{'inFS'};
	if ( (($VMdata{'pv'}{$vgname}{'size'} - $sum) / $VMdata{'pv'}{$vgname}{'size'}) > $WARNINGPERCENTAGE) {
		$VMdata{'warning'} .= "numbers in $vgname don't add up\n";
	}
}

#PV sanity checks
my $sum = $VMdata{'unalloc'} + $VMdata{'inPV'} + $VMdata{'inVG'} + $VMdata{'inLV'} + $VMdata{'inFS'};
if ( $VMdata{'size'} && (($VMdata{'size'} - $sum) / $VMdata{'size'}) > $WARNINGPERCENTAGE) {
	$VMdata{'warning'} .= "numbers in PVs don't add up $sum $VMdata{'size'}";
}
if ($UNIT eq 'g') {
	$VMdata{'unit'} = 'GiB';
} elsif ($UNIT eq 't') {
	$VMdata{'unit'} = 'TiB';
}

my $json = JSON->new->allow_nonref;	#generate and output JSON
my $json_text   = $json->pretty->encode(\%VMdata);
print "$json_text";

#---------------------------
sub units {
	my ($size, $sourceUnit) = @_;
  if ($sourceUnit eq 'TB' || $sourceUnit eq 'TiB' || $sourceUnit eq 'T') {    #we get TB
      if ($UNIT eq 'g') {
        $size *= 1024;
      }
  } elsif ($sourceUnit eq 'GB' || $sourceUnit eq 'GiB' || $sourceUnit eq 'G') {   #we get GB
      if ($UNIT eq 't') {
        $size /= 1024.0;
      }
  } else {  #we get kB
      if ($UNIT eq 'g') {
        $size /= 1024.0*1024.0;
      } elsif ($UNIT eq 't') {
        $size /= 1024.0*1024.0*1024.0;
      }
  }
	return nearest(.01, $size);
}
