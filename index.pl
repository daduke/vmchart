#!/usr/bin/perl -w

# LVMchart - browser-based generator for nice charts of LVM usage across different file servers
# (c) 2011 Christian Herzog <daduke@phys.ethz.ch> and Patrick Schmid <schmid@phys.ethz.ch>
# incremental AJAX loading by Philip Ezhukattil <philipe@phys.ethz.ch>
# distributed under the terms of the GNU General Public License version 2 or any later version.
# project website: http://wiki.phys.ethz.ch/readme/lvmchart

use strict;
use JSON;
use Number::Format;
use POSIX qw(ceil);

open HOSTS, "hostlist";
my @servers = <HOSTS>;
close HOSTS;
chomp @servers;
my $numberOfServers = @servers;

my %labels = ( 'fsfill' => 'FS filling level', 'infs' => 'available in FS', 'inlv' => 'available in LV', 'invg' => 'available in VG', 'inpv' => 'available in PV');
my $BARSPERCHART = 8;    #number of LV in bar chart
my $ORGSPERCHART = 8;   #number of LV in org chart
my $CHARTSPERLINE = 3;  #number of LV charts in one line
my $MAXCHARTFACTOR = 10; #max factor in one LV chart

my (%lvm, $UNIT);
my ($markup, $javascript);
my $warnings = '';
my $format = new Number::Format(-thousands_sep   => '\'', -decimal_point   => '.');

my $option = $ENV{'QUERY_STRING'};

#verification of the querystring
if ($option eq 'data'){
    print "Content-type:text/plain\r\n\r\n";
    $| = 1;     # Flush output continuously
    &getdata();
}else{
    print "Content-type:text/html\r\n\r\n";
    print html();
}

sub getdata {
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

                $vgs{$vg}{'js'} = " {c:[{v:'$vg'},{v:$VGFSLevel},{v:$VGInFS},{v:$VGInLV},{v:$VGInVG}]},";


                foreach my $lv (reverse sort { $lvm{'pv'}{$vg}{$a}{'size'} <=> $lvm{'pv'}{$vg}{$b}{'size'} } keys %{$lvm{$vg}{'lvs'}}) {    #sort by LV size
                    my $LVFSLevel = $lvm{'pv'}{$vg}{$lv}{'FSLevel'};    #get LV data
                    my $LVInFS = $lvm{'pv'}{$vg}{$lv}{'inFS'} - $LVFSLevel;
                    my $LVInLV = $lvm{'pv'}{$vg}{$lv}{'inLV'};
                    my $LVSize = $lvm{'pv'}{$vg}{$lv}{'size'};

                    $lvs{$lv}{'size'} = $LVSize;
                    $LVSize = $format->format_number($LVSize);
                    $LVSize =~ s/'/\\'/;

                    if ($orgcount && !($orgcount % $ORGSPERCHART)) {  #if org chart is full, create a new one
                        $javascript .= orgChart("${serverID}_$lvGrpOrg", $orgRows);
                        $lvGrpOrg++;
                        $orgChart .= "<br /><br /><div class=\"orgchart\" id=\"org_chart_${serverID}_$lvGrpOrg\"></div>\n";
                        $orgRows = "{c:[{v:'$vg',f:'$vg<div class=\"parent\">$VGSize$UNIT</div>'}, '','VG size']},";
                    }

                    $lvs{$lv}{'js'} = "{c:[{v:'$lv'},{v:$LVFSLevel},{v:$LVInFS},{v:$LVInLV}]},";   #fill LV and org chart data
                    $orgRows .= "{c:[{v:'$lv<div class=\"child\">$LVSize$UNIT</div>'},{v:'$vg'},'LV size']},";

                    $orgcount++;
                }
                $orgRows .= "{c:[{v:'$vg',f:'$vg<div class=\"parent\">$VGSize$UNIT</div>'}, '','VG size']},";
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
    }
}


#----------------
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
    <script type="text/javascript" src="http://www.google.com/jsapi"></script>
    <script type="text/javascript">
        $javascript
    </script>
 </head>
  <div class="header">LVMchart - LVM Monitoring</div>
  <body onload="init();">
    <div id="message"></div>
        <div align="center" id="data"></div>
    <div id="warnings"></div>
    <div id="javascr" />
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
      <tr><td>Host $server</td></tr>
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
        // Define a formatter for the Numbers
        var formatter = new google.visualization.NumberFormat({suffix:'$UNIT',groupingSymbol:'\\''});
        var pv_data_$serverID = new google.visualization.DataTable(
          {
            cols: [{id:'FSFill',label:'$labels{"fsfill"}', type:'number'},  // FSLevel
                   {id:'UsedInFS',label:'$labels{"infs"}', type:'number'},  // inFS - FSLevel
                   {id:'inLV',label:'$labels{"inlv"}', type:'number'},      // inLV
                   {id:'inVG', label:'$labels{"invg"}',type:'number'},      // inVG
                   {id:'inPV',label:'$labels{"inpv"}',type:'number'}        // inPV
          ],
            rows: [{c:[{v:$PVFSLevel},{v:$PVInFS},{v:$PVInLV},{v:$PVInVG},{v:$PVInPV}]}
          ]
          });

        formatter.format(pv_data_$serverID, 0); //Apply formatter to columns
        formatter.format(pv_data_$serverID, 1);
        formatter.format(pv_data_$serverID, 2);
        formatter.format(pv_data_$serverID, 3);
        formatter.format(pv_data_$serverID, 4);

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

        formatter.format(vg_data_$serverID, 1);
        formatter.format(vg_data_$serverID, 2);
        formatter.format(vg_data_$serverID, 3);
        formatter.format(vg_data_$serverID, 4);

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

        formatter.format(lv_data_$serverID, 1);
        formatter.format(lv_data_$serverID, 2);
        formatter.format(lv_data_$serverID, 3);

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
        var org_data_$serverID = new google.visualization.DataTable(
          {
            cols: [{id:'Name',label:'Name', type:'string'},
                   {id:'Parent', label:'Parent',type:'string'},
                   {id:'LV Size',label:'LV Size',type:'number'}
                  ],
            rows: [$orgRows
                ]
          });

        formatter.format(org_data_$serverID, 2);

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
    line-height: 6em;
    color: green;
    font-weight: bold;
    text-align: center;
}
body {
    background: #C9D5E5;
    font-family: Arial;
    border: 0 none;
}

h1{
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
EOF
}

sub javascript {
    return <<EOF;
    google.load('visualization', '1', {packages: ['corechart']});
    google.load('visualization', '1', {packages:['orgchart']});

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
            document.getElementById("message").style.visibility = 'hidden';
            }
    }
EOF
}
