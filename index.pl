#!/usr/bin/perl -w

# LVMchart - browser-based generator for nice charts of LVM usage across different file servers
# (c) 2011 Christian Herzog <daduke@phys.ethz.ch> and Patrick Schmid <schmid@phys.ethz.ch>
# incremental AJAX loading by Philip Ezhukattil <philipe@phys.ethz.ch> and Claude Becker
# <beckercl@phys.ethz.ch>
# distributed under the terms of the GNU General Public License version 2 or any later version.
# project website: http://wiki.phys.ethz.ch/readme/lvmchart

# 2011/08/04 v1.0 - initial working version
# 2012/04/22 v2.0 - added backend information
# 2012/04/25 v2.1 - added PV change log to detect defective backends

use strict;
use JSON;
use Number::Format;
use POSIX qw(ceil strftime);
use File::Copy;
use MLDBM qw(DB_File);  #to store hashes of hashes
use Fcntl;              #to set file permissions
use Clone qw(clone);   #to close hashes of hashes


my @servers;
my (%info, %PVlayout);
my %PVhistory = ();
open HOSTS, "hostlist";
while (<HOSTS>) {
    my ($host, $info) = split / - /;
    chomp $info;
    push @servers, $host;
    $info{$host} = $info;
}
close HOSTS;
my $numberOfServers = @servers;


my %labels = ( 'fsfill' => 'FS filling level', 'infs' => 'available in FS', 'inlv' => 'available in LV', 'invg' => 'available in VG', 'inpv' => 'available in PV');
my $BARSPERCHART = 8;    #number of LV in bar chart
my $ORGSPERCHART = 10;   #number of LV in org chart
my $CHARTSPERLINE = 3;  #number of LV charts in one line
my $MAXCHARTFACTOR = 10; #max factor in one LV chart
my $GLOBALUNIT = 'TB';   #summary data is in TB

my (%lvm, $UNIT);
my ($markup, $javascript);
my $warnings = '';
my $backends = '';
my $format = new Number::Format(-thousands_sep   => '\'', -decimal_point   => '.');

my $option = $ENV{'QUERY_STRING'};

#verification of the query string
if ($option eq 'data'){
    print "Content-type:text/plain\r\n\r\n";
    $| = 1;     # Flush output continuously
    &getdata();
} else {
    print "Content-type:text/html\r\n\r\n";
    print html();
}

sub getdata {
    my %backends;
    foreach my $server (@servers) {
        my $json_text;
        if (!($json_text = `ssh -o IdentitiesOnly=yes -i /var/www/.ssh/remotesshwrapper root\@$server /usr/local/bin/remotesshwrapper lvm2.pl`)) {
            $warnings .= "could not fetch JSON from server $server! $!<br />\n";
        } else {
            my $json = JSON->new->allow_nonref;
            my $lvm;
            if (!($lvm = $json->decode($json_text))) {
                $warnings .= "could not get LVM data from server $server<br />\n"; next;
            }
            %lvm = %$lvm;

            my $numLVs = 0; #count LV
            foreach my $vg (keys %{$lvm{'vgs'}}) {
                foreach my $lv (keys %{$lvm{$vg}{'lvs'}}) {
                    $numLVs++;
                }
            }

            my $serverID = $server;
            $serverID =~ s/-/_/g;   #Google chart API needs underscores
            $UNIT = $lvm{'unit'};   #TB or GB comes from the JSON

            if ($lvm{'warning'}) {
                $warnings .= "Host $server: ".$lvm{'warning'}."<br />\n";
            }
            next unless (keys %{$lvm{'vgs'}});  #skip host if no vgs present

            foreach my $backend (sort keys %{$lvm{'backends'}}) {
                foreach my $slice (sort { $a cmp $b } keys %{$lvm{'backends'}{$backend}{'slices'}}) {
                    my $vg = $lvm{'backends'}{$backend}{'slices'}{$slice}{'vg'} || '<span class="free">free space</span>';
                    my $size = units($lvm{'backends'}{$backend}{'slices'}{$slice}{'size'}, $UNIT, $GLOBALUNIT);
                    $backends{$backend}{'size'} += $size;
                    $backends{$backend}{$server}{'size'} += $size;
                    $backends{$backend}{$server}{$vg}{'size'} += $size;
                    $backends{$backend}{'slices'} .= "$slice, \\n";
                    $backends{$backend}{$server}{'slices'} .= "$slice, \\n";
                    $backends{$backend}{$server}{$vg}{'slices'} .= "$slice, \\n";
                    $backends{'global'}{$server}{$vg}{'slices'} .= "$backend-$slice, \\n";
                    $PVlayout{$server}{$vg}{"$backend-$slice"} = 1;
                }
            }

            my $PVFSLevel = $lvm{'FSLevel'};    #get PV data
            my $PVInFS = $lvm{'inFS'} - $PVFSLevel;
            my $PVInLV = $lvm{'inLV'};
            my $PVInVG = $lvm{'inVG'};
            my $PVInPV = $lvm{'inPV'};
            my $PVSize = $lvm{'size'};
            $PVSize = $format->format_number($PVSize);
            $PVSize =~ s/'/\\'/;
            $javascript .= pvData($serverID, $PVFSLevel, $PVInFS, $PVInLV, $PVInVG, $PVInPV, $PVSize, $UNIT);

            my (%vgs, %lvs, $vgRows, $lvRows, $orgRows);
            my $lvGrpOrg = 0;
            my $orgcount = 0;
            my $orgChart .= "<div class=\"orgchart\" id=\"org_chart_${serverID}_$lvGrpOrg\"></div>";
            foreach my $vg (reverse sort { $lvm{'pv'}{$a}{'size'} <=> $lvm{'pv'}{$b}{'size'} } keys %{$lvm{'vgs'}}) {
                my $VGFSLevel = $lvm{'pv'}{$vg}{'FSLevel'}; #get VG data
                my $VGInFS = $lvm{'pv'}{$vg}{'inFS'} - $VGFSLevel;
                my $VGInLV = $lvm{'pv'}{$vg}{'inLV'};
                my $VGInVG = $lvm{'pv'}{$vg}{'inVG'};
                my $VGSize = $lvm{'pv'}{$vg}{'size'};

                $vgs{$vg}{'size'} = $VGSize;
                $VGSize = $format->format_number($VGSize);
                $VGSize =~ s/'/\\'/;

                $vgs{$vg}{'js'} = " {c:[{v: '$vg'},{v: $VGFSLevel, f:'$VGFSLevel $UNIT'},{v: $VGInFS, f:'$VGInFS $UNIT'},{v: $VGInLV, f:'$VGInLV $UNIT'},{v: $VGInVG, f:'$VGInVG $UNIT'}]},";


                my $VGslices;
                if ($VGslices = $backends{'global'}{$server}{$vg}{'slices'}) {
                    $VGslices = "LUNs for this VG: \\n" . $VGslices;
                    $VGslices = substr $VGslices, 0, -4;
                } else {
                    $VGslices = "Volume group";
                }
                $orgRows .= "[{v: '$vg',f: '$vg<div class=\"parent\">$VGSize $UNIT</div>'}, '','$VGslices'],";
                foreach my $lv (reverse sort { $lvm{'pv'}{$vg}{$a}{'size'} <=> $lvm{'pv'}{$vg}{$b}{'size'} } keys %{$lvm{$vg}{'lvs'}}) {    #sort by LV size
                    my $LVFSLevel = $lvm{'pv'}{$vg}{$lv}{'FSLevel'};    #get LV data
                    my $LVInFS = $lvm{'pv'}{$vg}{$lv}{'inFS'} - $LVFSLevel;
                    my $LVInLV = $lvm{'pv'}{$vg}{$lv}{'inLV'};
                    my $LVSize = $lvm{'pv'}{$vg}{$lv}{'size'};

                    my $key = "${lv}_$vg";
                    $lvs{$key}{'size'} = $LVSize;
                    $LVSize = $format->format_number($LVSize);
                    $LVSize =~ s/'/\\'/;

                    if ($orgcount && !($orgcount % $ORGSPERCHART)) {  #if org chart is full, create a new one
                        $javascript .= orgChart("${serverID}_$lvGrpOrg", $orgRows);
                        $lvGrpOrg++;
                        $orgChart .= "<br /><br /><div class=\"orgchart\" id=\"org_chart_${serverID}_$lvGrpOrg\"></div>\n";
                        $orgRows = "[{v:'$vg',f:'$vg<div class=\"parent\">$VGSize $UNIT</div>'}, '','Volume group'],\n";
                    }

                    $lvs{$key}{'js'} = "{c:[{v: '$lv ($vg)'},{v: $LVFSLevel, f: '$LVFSLevel $UNIT'},{v: $LVInFS, f: '$LVInFS $UNIT'},{v: $LVInLV, f: '$LVInLV $UNIT'}]},";   #fill LV and org chart data
                    $orgRows .= "[{v:'$lv<div class=\"child\">$LVSize $UNIT</div>'},'$vg','Logical volume'],\n";

                    $orgcount++;
                }
            }


            my $maxInVGGraph = 0;
            my $vgcount = 0;
            my $vgGrpChart = 0;
            foreach my $vg (reverse sort { $vgs{$a}{'size'} <=> $vgs{$b}{'size'} } keys %vgs) {
                if ($vgcount == 0) {
                    $maxInVGGraph = $vgs{$vg}{'size'};
                }
                if ( ($vgcount && !($vgcount % $BARSPERCHART)) 
                    || ($vgs{$vg}{'size'} && (($maxInVGGraph / $vgs{$vg}{'size'})) > $MAXCHARTFACTOR) ) {
                        #if VG chart is full or bars get too short, create a new one
                    $javascript .= vgData("${serverID}_$vgGrpChart", $vgRows);
                    $vgGrpChart++;
                    $vgRows = '';
                    $vgcount = 0;
                    $maxInVGGraph = $vgs{$vg}{'size'};
                }
                $vgRows .= $vgs{$vg}{'js'};
                $vgcount++;
            }

            my $maxInLVGraph = 0;
            my $lvcount = 0;
            my $lvGrpChart = 0;
            foreach my $lv (reverse sort { $lvs{$a}{'size'} <=> $lvs{$b}{'size'} } keys %lvs) {
                if ($lvcount == 0) {
                    $maxInLVGraph = $lvs{$lv}{'size'};
                }
                if ( ($lvcount && !($lvcount % $BARSPERCHART))
                    || ($lvs{$lv}{'size'} && (($maxInLVGraph / $lvs{$lv}{'size'})) > $MAXCHARTFACTOR) ) {
                        #if LV chart is full or bars get too short, create a new one
                    $javascript .= lvData("${serverID}_$lvGrpChart", $lvRows);
                    $lvGrpChart++;
                    $lvRows = '';
                    $lvcount = 0;
                    $maxInLVGraph = $lvs{$lv}{'size'};
                }
                $lvRows .= $lvs{$lv}{'js'};
                $lvcount++;
            }

            chop $vgRows;   #trim last comma
            chop $lvRows;
            chop $orgRows;

            $javascript .= vgData("${serverID}_$vgGrpChart", $vgRows);
            $javascript .= lvData("${serverID}_$lvGrpChart", $lvRows);
            $javascript .= orgChart("${serverID}_$lvGrpOrg", $orgRows);
            $markup .= chartTable($server, $serverID, $orgChart, $vgGrpChart+1, $lvGrpChart+1);

            #Print information about this server
            print $javascript;
            print "ENDOFELEMENT";
            print $markup;
            print "ENDOFELEMENT";
            print $warnings;
            print "ENDOFSERVER";

            #Clear variables for next server
            $javascript = $markup = $warnings = "";

        }
    }   #end foreach server

    $markup = "<div class=\"orgchart\" id=\"org_chart_backends_0\"></div>\n";
    $javascript = '';
    my $beGrpOrg = 0;
    my $orgcount = 0;
    my ($orgRows, $BEslices, $FEslices, $VGslices);
    foreach my $backend (sort keys %backends) {
        next if (grep /\b$backend\b/, qw(size global));
        my $backendSize = $backends{$backend}{'size'};
        $BEslices = "LUNs on this backend: \\n" . $backends{$backend}{'slices'};
        $BEslices = substr $BEslices, 0, -4;
        $orgRows .= "[{v: '$backend',f: '$backend<div class=\"parent\">$backendSize $GLOBALUNIT</div>'}, '', '$BEslices'],\n";
        foreach my $server (sort keys %{$backends{$backend}}) {
            next if (grep /\b$server\b/, qw(size slices));
            my $serverSize = $backends{$backend}{$server}{'size'};
            $FEslices = "LUNs for this frontend: \\n" . $backends{$backend}{$server}{'slices'};
            $FEslices = substr $FEslices, 0, -4;
            $orgRows .= "[{v: '$server-$backend',f: '$server<div class=\"child\">$serverSize $GLOBALUNIT</div>'}, '$backend', '$FEslices'],\n";
            foreach my $vg (sort keys %{$backends{$backend}{$server}}) {
                next if (grep /\b$vg\b/, qw(size slices));
                my $VGsize = $backends{$backend}{$server}{$vg}{'size'};
                $VGslices = "LUNs for this VG: \\n" . $backends{$backend}{$server}{$vg}{'slices'};
                $VGslices = substr $VGslices, 0, -4;

                if ($orgcount && !($orgcount % $ORGSPERCHART)) {  #if org chart is full, create a new one
                    $javascript .= orgChart("backends_$beGrpOrg", $orgRows);
                    $beGrpOrg++;
                    $markup .= "<br /><br /><div class=\"orgchart\" id=\"org_chart_backends_$beGrpOrg\"></div>\n";
                    $orgRows = "[{v: '$backend',f: '$backend<div class=\"parent\">$backendSize $GLOBALUNIT</div>'}, '', '$BEslices'],\n";
                    $orgRows .= "[{v: '$server-$backend',f: '$server<div class=\"child\">$serverSize $GLOBALUNIT</div>'}, '$backend', '$FEslices'],\n";
                }
                $orgRows .= "[{v: '$vg-$backend-$server',f: '$vg<div class=\"grandchild\">$VGsize $GLOBALUNIT</div>'}, '$server-$backend', '$VGslices'],\n";
                $orgcount++;
            }
        }
    }
    $javascript .= orgChart("backends_$beGrpOrg", $orgRows);
    print "BACKENDS";
    print "$markup";
    print "ENDOFELEMENT";
    print "show backends" if ($orgcount);
    print "ENDOFELEMENT";
    print "$javascript";
    print "ENDOFELEMENT";

    #create PV diff log
    my $changes;
    tie(%PVhistory, 'MLDBM', 'PVhistory.db', O_CREAT|O_RDWR, 0666);
    my %PVtemp = %{ clone (\%PVhistory) };  #needed b/c direct modify of tied HoH doesn't work
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
    %PVhistory = %{ clone (\%PVlayout) };
    untie %PVhistory;

    open OLDLOG, "< changelog";
    my @oldchanges = <OLDLOG>;
    close OLDLOG;

    if ($changes) {
        my $timestamp = POSIX::strftime("%Y/%m/%d %H:%M:%S", localtime);
        $changes = "$timestamp:<br />$changes";
        print "<table>$changes</table><br /><br />@oldchanges";

        open LOG, "> newlog";
        print LOG "<table>$changes</table><br /><br />@oldchanges";
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
    return $value;
}

sub html {  #HTML template
    my $css = css();
    my $javascript = javascript();
    return <<EOF;
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
    <meta http-equiv="content-type" content="text/html; charset=utf-8"/>
    <title>
      LVMchart - LVM Monitoring
    </title>
    <style type="text/css">
        $css
    </style>
    <script type="text/javascript" src="https://www.google.com/jsapi"></script>
    <script type="text/javascript">
        $javascript
    </script>
 </head>
  <div class="header"><a href="http://wiki.phys.ethz.ch/readme/lvmchart">LVMchart - LVM Monitoring</a></div>
  <body onload="init();">
    <div id="message"></div>
    <div align="center" id="data"><h2>Frontend information</h2></div>
    <div id="javascr"></div>
    <div align="center" id="backends"></div>
    <hr />
    <div align="left" id="changes"></div>
    <!--[if !IE]>-->
    <div id="warnings"></div>
    <!--<![endif]-->
    <!--[if IE]>
    <div id="warnings">Please make sure you have Internet Explorer's compatibility mode disabled.<br /></div>
    <![endif]-->
</body>
</html>
EOF
}

sub chartTable {    #chart table HTML
    my ($server, $serverID, $orgChart, $vgGrpChart, $lvGrpChart) = @_;
    my ($vgChart, $vgRows);
    my ($lvChart, $lvRows);

    if ($vgGrpChart > 1) {
        my $rows = ceil($vgGrpChart / $CHARTSPERLINE);
        $vgChart = "&nbsp;";
        my $num = 0;
        for my $row (1..$rows) {
            $vgRows .= "<tr>";
            for my $chart (1..$CHARTSPERLINE) {
                $vgRows .= "<td><div class=\"chart\" id=\"vg_chart_${serverID}_$num\"></div></td>";
                $num++;
            }
            $vgRows .= "</tr>";
        }
    } else {
        $vgChart = "<div class=\"chart\" id=\"vg_chart_${serverID}_0\"></div>";
        $vgRows = '';
    }

    if ($lvGrpChart > 1) {
        my $rows = ceil($lvGrpChart / $CHARTSPERLINE);
        $lvChart = "&nbsp;";
        my $num = 0;
        for my $row (1..$rows) {
            $lvRows .= "<tr>";
            for my $chart (1..$CHARTSPERLINE) {
                $lvRows .= "<td><div class=\"chart\" id=\"lv_chart_${serverID}_$num\"></div></td>";
                $num++;
            }
            $lvRows .= "</tr>";
        }
    } else {
        $lvChart = "<div class=\"chart\" id=\"lv_chart_${serverID}_0\"></div>";
        $lvRows = '';
    }

    return <<EOF;
      <tr><td>Host $server ($info{$server})</td></tr>
      <tr>
        <td>
          <div class="chart" id="pv_chart_$serverID"></div>
        </td>
        <td>
            $vgChart
        </td>
        <td>
            $lvChart
        </td>
    </tr>
        $vgRows
        $lvRows
    <tr>
       <td colspan="3">
       $orgChart
        </td>
      </tr>
      <tr><td colspan="3"><hr /></td></tr>
EOF
}

sub pvData {
    my ($serverID, $PVFSLevel, $PVInFS, $PVInLV, $PVInVG, $PVInPV, $PVSize, $UNIT) = @_;
    return <<EOF;
    //pv data
        var pv_data_$serverID = new google.visualization.DataTable(
          {
            cols: [{id:'PV',label:'PV', type:'string'},
                   {id:'FSFill',label:'$labels{"fsfill"}', type:'number'},  // FSLevel
                   {id:'UsedInFS',label:'$labels{"infs"}', type:'number'},  // inFS - FSLevel
                   {id:'inLV',label:'$labels{"inlv"}', type:'number'},      // inLV
                   {id:'inVG', label:'$labels{"invg"}',type:'number'},      // inVG
                   {id:'inPV',label:'$labels{"inpv"}',type:'number'}        // inPV
          ],
            rows: [{c:[{v:'Disk space'},{v: $PVFSLevel, f: '$PVFSLevel $UNIT'},{v: $PVInFS, f: '$PVInFS $UNIT'},{v: $PVInLV, f: '$PVInLV $UNIT'},{v: $PVInVG, f: '$PVInVG $UNIT'},{v: $PVInPV, f: '$PVInPV $UNIT'}]}
          ]
          });


    //pv chart
        var pv_chart_$serverID = new google.visualization.ColumnChart(document.getElementById('pv_chart_$serverID'));
            pv_chart_$serverID.draw(pv_data_$serverID, {'title':'Usage of Physical Volumes',
                                    'backgroundColor':'#C9D5E5',
                                    'legend': 'right',
                                    'legendTextStyle': {fontSize:10},
                                    'isStacked': true,
                                    'colors':['#3366cc','#3399ff','magenta','#dc3912','#ff9900'],
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
                                'backgroundColor':'#C9D5E5',
                                'legend': 'right',
                                'legendTextStyle': {fontSize:10},
                                'isStacked': true,
                                'colors':['#3366cc','#3399ff','magenta','#dc3912'],
                                'vAxis': {'title': '$UNIT','gridlineColor':'#808080'}});
EOF
}

sub lvData {
    my ($serverID, $lvRows) = @_;
    return <<EOF;
    //lv data
        var lv_data_$serverID = new google.visualization.DataTable(
          {
            cols: [{id:'LV',label:'LV', type:'string'},
                   {id:'FSFill', label:'$labels{"fsfill"}',type:'number'},  // FSLevel
                   {id:'UsedInFS', label:'$labels{"infs"}',type:'number'},  // inFS - FSLevel
                   {id:'inLV',label:'$labels{"inlv"}', type:'number'}       // inLV
          ],
        rows: [$lvRows
                  ]
          });


    //lv chart
        var lv_chart_$serverID = new google.visualization.ColumnChart(document.getElementById('lv_chart_$serverID'));
        lv_chart_$serverID.draw(lv_data_$serverID, {'title':'Usage of Logical Volumes',
                                    'backgroundColor':'#C9D5E5',
                                    'legend': 'right',
                                    'legendTextStyle': {fontSize:10},
                                    'isStacked': true,
                    'colors':['#3366cc','#3399ff','magenta','#dc3912'],
                                    'vAxis': {'title': '$UNIT', 'gridlineColor':'#808080'}});
EOF
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

sub css {
    return <<EOF;
.header {
    color: yellow;
    background-color:#C9D5E5;
    font-size: 40px;
    font-weight: bold;
    text-align: center;
}

#warnings {
    color: red;
}

#message {
    line-height: 3em;
    color: green;
    font-weight: bold;
    text-align: center;
}

body {
    background: #C9D5E5;
    font-family: Arial;
    border: 0 none;
}

h1 {
    font-size: 14px;
    font-weight: bold;
}

div.chart {
    width: 400px;
    height: 300px;
}

div.parent {
    color:#dc3912;
    font-style:italic;
}

div.child {
    color:#008800;
    font-style:italic;
}

div.grandchild {
    color:#000088;
    font-style:italic;
}

div#changes {
    padding-left: 40px;
    font-size: 70%;
}

span.free {
    color:#0b0;
    font-weight: bold;
}

span.remove {
    color:#f00;
    font-weight: bold;
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
        ajaxLoad("index.pl?data", ajaxOnResult);
    }

    function ajaxLoad(url, callback){
        req.open("GET", url, true);
        req.send(null);

        req.onreadystatechange = callback;                  //Start ajaxOnResult function after the stream
        window.setTimeout( function() {ajaxOnProgress(req);},500);
    }

    function ajaxOnProgress(req) {
        if (req.readyState !=4){                        //while the data are received
             var msg = document.getElementById("message");
             if(msg.innerHTML == ''){
              msg.innerHTML = 'Loading Server 1 of $numberOfServers';
             }
            ajaxDisplayServer();
            window.setTimeout( function() {ajaxOnProgress(req);},500);
        }
    }

    function ajaxDisplayServer(){
        if(req.responseText.match(/ENDOFSERVER/g)){
            var server = req.responseText.split(/ENDOFSERVER/g);        //Split the stream into individual servers
            var numberOfServersReceived = server.length -1;         //the number of servers in the array

            for(i=numberOfServersDisplayed; i< numberOfServersReceived; i++){           //check if all the server data will be displayed
                var serverdata = server[i].split(/ENDOFELEMENT/g);                      //Split into elements(js/markup/wanings)
                var div=document.createElement('div');                                  //create container for new table
                div.innerHTML += "<table class='table'>" + serverdata[1] + "</table>";  //workaround for friggin IE that can't dynamically modify tables
                document.getElementById('data').appendChild(div);                       //load new table into DOM

                var javascr=document.getElementById('javascr'); //javascript element
                var JSchild=document.createElement('script');   //create new js block
                JSchild.type='text/javascript';
                JSchild.text=serverdata[0];
                var jsid = 'js'+i;
                JSchild.id = jsid;
                javascr.appendChild(JSchild);                   //and append it
                eval(document.getElementById(jsid).innerHTML);  //FF needs explicit eval

                document.getElementById('warnings').innerHTML += serverdata[2];
                document.getElementById('message').innerHTML = "Loading Server " + parseInt(numberOfServersReceived+1) + " of $numberOfServers";
                numberOfServersDisplayed++;
            }
        }
    }

    function ajaxOnResult(){
        if ((req.readyState == 4) && (req.status == 200 || req.status == 0)) {
            ajaxDisplayServer();                                    //double check if all the server data was displayed
            document.getElementById('message').style.visibility = 'hidden';
            var backends = req.responseText.split(/BACKENDS/g);
            var content = backends[1].split(/ENDOFELEMENT/g);
            var markup = content[0];
            var orgchart = content[1];
            var javascript = content[2];
            var changes = content[3];
            if (orgchart.length > 0) document.getElementById('backends').innerHTML += '<h2>Backend information</h2>'+markup;
            if (changes.length > 0) document.getElementById('changes').innerHTML += '<h2>PV change log</h2>'+changes;

            var javascr=document.getElementById('javascr'); //javascript element
            var JSchild=document.createElement('script');   //create new js block
            JSchild.type='text/javascript';
            JSchild.text=javascript;
            var jsid = 'jsbackend';
            JSchild.id = jsid;
            javascr.appendChild(JSchild);                   //and append it
            eval(document.getElementById(jsid).innerHTML);  //FF needs explicit eval
        }
    }
EOF
}
