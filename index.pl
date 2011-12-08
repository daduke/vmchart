#!/usr/bin/perl -w

# LVMchart - browser-based generator for nice charts of LVM usage across different file servers
# (c) 2011 Christian Herzog <daduke@phys.ethz.ch> and Patrick Schmid <schmid@phys.ethz.ch>
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

my %labels = ( 'fsfill' => 'FS filling level', 'infs' => 'available in FS', 'inlv' => 'available in LV', 'invg' => 'available in VG', 'inpv' => 'available in PV');
my $LVSPERCHART = 8;	#number of LV in bar chart
my $ORGSPERCHART = 8;	#number of LV in org chart
my $CHARTSPERLINE = 3;	#number of LV charts in one line

my (%lvm, $UNIT);
my ($markup, $javascript);
my $warnings = '';
my $format = new Number::Format(-thousands_sep   => '\'', -decimal_point   => '.');

my $option = $ENV{'QUERY_STRING'};
my $counter;

#verification of the querystring
if ($option eq 'data'){
	print "Content-type:text/plain\r\n\r\n";
	$| = 1;		# Flush output continuously
	&getdata();
}else{
	print "Content-type:text/html\r\n\r\n";
	print html();
}



sub getdata {
	foreach my $server (@servers) {
		my $json_text;
		if (!($json_text = `ssh -o IdentitiesOnly=yes -i ~/.ssh/remotesshwrapper root\@$server /usr/local/bin/remotesshwrapper lvm2.pl`)) {
			$warnings .= "could not fetch JSON from server $server! $!<br />\n";
		} else {
			my $json = JSON->new->allow_nonref;
			my $lvm;
			if (!($lvm = $json->decode($json_text))) {
				$warnings .= "could not get LVM data from server $server<br />\n"; next;
			}
			%lvm = %$lvm;

			my $numLVs = 0;	#count LV
			foreach my $vg (keys %{$lvm{'vgs'}}) {
				foreach my $lv (keys %{$lvm{$vg}{'lvs'}}) {
					$numLVs++;
				}
			}

			my $serverID = $server;
			$serverID =~ s/-/_/g;	#Google chart API needs underscores
			$UNIT = $lvm{'unit'};	#TB or GB comes from the JSON

			if ($lvm{'warning'}) {
				$warnings .= "Host $server: ".$lvm{'warning'}."<br />\n";
			}
			next unless (keys %{$lvm{'vgs'}});	#skip host if no vgs present

			my $PVFSLevel = $lvm{'FSLevel'};	#get PV data
			my $PVInFS = $lvm{'inFS'} - $PVFSLevel;
			my $PVInLV = $lvm{'inLV'};
			my $PVInVG = $lvm{'inVG'};
			my $PVInPV = $lvm{'inPV'};
			my $PVSize = $lvm{'size'};
			$PVSize = $format->format_number($PVSize);
			$PVSize =~ s/'/\\'/;
			$javascript .= pvData($serverID, $PVFSLevel, $PVInFS, $PVInLV, $PVInVG, $PVInPV, $PVSize, $UNIT);

			my ($vgRows, $lvRows, $orgRows);
			my $lvGrpOrg = 0;
			my $lvGrpChart = 0;
			my $orgChart .= "<div class=\"orgchart\" id=\"org_chart_${serverID}_$lvGrpOrg\"></div>";
			foreach my $vg (sort keys %{$lvm{'vgs'}}) {
				my $VGFSLevel = $lvm{'pv'}{$vg}{'FSLevel'};	#get VG data
				my $VGInFS = $lvm{'pv'}{$vg}{'inFS'} - $VGFSLevel;
				my $VGInLV = $lvm{'pv'}{$vg}{'inLV'};
				my $VGInVG = $lvm{'pv'}{$vg}{'inVG'};
				my $VGSize = $lvm{'pv'}{$vg}{'size'};
				$VGSize = $format->format_number($VGSize);
				$VGSize =~ s/'/\\'/;

				$vgRows .= " {c:[{v:'$vg'},{v:$VGFSLevel},{v:$VGInFS},{v:$VGInLV},{v:$VGInVG}]},";
				$orgRows .= "{c:[{v:'$vg',f:'$vg<div class=\"parent\">$VGSize$UNIT</div>'}, '','VG size']},";

				my $lvcount = 0;
				foreach my $lv (sort keys %{$lvm{$vg}{'lvs'}}) {
					my $LVFSLevel = $lvm{'pv'}{$vg}{$lv}{'FSLevel'};	#get LV data
					my $LVInFS = $lvm{'pv'}{$vg}{$lv}{'inFS'} - $LVFSLevel;
					my $LVInLV = $lvm{'pv'}{$vg}{$lv}{'inLV'};
					my $LVSize = $lvm{'pv'}{$vg}{$lv}{'size'};
					$LVSize = $format->format_number($LVSize);
					$LVSize =~ s/'/\\'/;

					if ($lvcount && !($lvcount % $LVSPERCHART)) {	#if LV chart is full, create a new one
						$javascript .= lvData("${serverID}_$lvGrpChart", $lvRows);
						$lvGrpChart = int($lvcount / $LVSPERCHART);
						$lvRows = '';
					}	

					if ($lvcount && !($lvcount % $ORGSPERCHART)) {	#if org chart is full, create a new one
						$javascript .= orgChart("${serverID}_$lvGrpOrg", $orgRows);
						$lvGrpOrg = int($lvcount / $ORGSPERCHART);
						$orgChart .= "<br /><br /><div class=\"orgchart\" id=\"org_chart_${serverID}_$lvGrpOrg\"></div>\n";
						$orgRows = "{c:[{v:'$vg',f:'$vg<div class=\"parent\">$VGSize$UNIT</div>'}, '','VG size']},";
					}
					$lvcount++;

					$lvRows .= "{c:[{v:'$lv'},{v:$LVFSLevel},{v:$LVInFS},{v:$LVInLV}]},";	#fill LV and org chart data
					$orgRows .= "{c:[{v:'$lv<div class=\"child\">$LVSize$UNIT</div>'},{v:'$vg'},'LV size']},";
				}
			}
			chop $vgRows;	#trim last comma
			chop $lvRows;
			chop $orgRows;

			$javascript .= vgData($serverID, $vgRows);
			$javascript .= lvData("${serverID}_$lvGrpChart", $lvRows);
			$javascript .= orgChart("${serverID}_$lvGrpOrg", $orgRows);
			$markup .= chartTable($server, $serverID, $orgChart, $numLVs);

			#Print information about this server
                        print $javascript;
			print "ENDOFELEMENT";
			print $markup;
			print "ENDOFELEMENT";
			print $warnings;
			print "ENDOFSERVER";

			#Clear variables for next iteration
			$javascript = $markup = $warnings = "";
		}
	}
}


#----------------
sub html {	#HTML template
	my $css = css();
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
	       google.load('visualization', '1', {packages: ['corechart']});
	       google.load('visualization', '1', {packages:['orgchart']});
     		
    var numberOfServersDisplayed = 0;	
    var req = (window.XMLHttpRequest) ? new XMLHttpRequest() : new ActiveXObject("Microsoft.XMLHTTP"); // Create Ajax request object
	
	function init(){
		//Use ajax to load server data
		ajaxLoad("https://admin.phys.ethz.ch/lvm2FS/index.pl?data", ajaxOnResult);
	}
        
	function ajaxLoad(url, callback){
		req.open("GET", url, true);
		req.send(null);								
		
		req.onreadystatechange = callback;					//Start ajaxOnResult function after the stream
		window.setTimeout( function() {ajaxOnProgress(req);},500);
	}
	
	function ajaxOnProgress(req) {
		if (req.readyState !=4){						//while the data are received
			var msg = document.getElementById("message");		
			msg.innerHTML = 'Loading Server Data...';
	
			ajaxDisplayServer();	
			window.setTimeout( function() {ajaxOnProgress(req);},500);  		
		}
	}

	function ajaxDisplayServer(){		
		if(req.responseText.match(/ENDOFSERVER/g)){								
			var server = req.responseText.split(/ENDOFSERVER/g);		//Split the Stream in Server                           
			var numberOfServersReceived = server.length -1;			//the number of servers in the array

			for(i=numberOfServersDisplayed; i< numberOfServersReceived; i++){			//check if all the server data will be displayed
				var serverdata = server[i].split(/ENDOFELEMENT/g);	//Split by elements(js/markup/wanings)
				document.getElementById('js').innerHTML += serverdata[0];			//insert data
				document.getElementById('data').innerHTML += "<table id='table'>" + serverdata[1] + "</table>";
				document.getElementById('warnings').innerHTML += serverdata[2];                                      
				eval(document.getElementById('js').innerHTML);
				numberOfServersDisplayed++;				
			}		
		}
	}	

	function ajaxOnResult(evt){
		if ((evt.currentTarget.readyState == 4) && (evt.currentTarget.status == 200 || evt.currentTarget.status == 0)) {
			ajaxDisplayServer();									//double check if all the server data was displayed					
			document.getElementById("message").style.visibility = 'hidden';		
			}
	}
</script>
 </head> 
  <div class="header">LVMchart - LVM Monitoring</div> 
  <body onload="init();"> 
	<div id="message"></div>
	<script type="text/javascript" id="js"></script>
        <div align="center" id="data"></div>
	<div id="warnings"></div>
</body> 
</html> 
EOF
}

sub chartTable {	#chart table HTML
	my ($server, $serverID, $orgChart, $numLVs) = @_;
	my ($lvChart, $lvRows);
	if ($numLVs > $LVSPERCHART) {
		my $charts = ceil($numLVs / $LVSPERCHART);
		my $rows = ceil($numLVs / $LVSPERCHART / $CHARTSPERLINE);
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
          <div class="chart" id="vg_chart_$serverID"></div> 
        </td> 
        <td> 
	   $lvChart
        </td> 
	</tr>
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
            cols: [{id:'FSFill',label:'$labels{"fsfill"}', type:'number'},	// FSLevel
                   {id:'UsedInFS',label:'$labels{"infs"}', type:'number'},	// inFS - FSLevel
                   {id:'inLV',label:'$labels{"inlv"}', type:'number'},		// inLV
                   {id:'inVG', label:'$labels{"invg"}',type:'number'},		// inVG
                   {id:'inPV',label:'$labels{"inpv"}',type:'number'}		// inPV
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
                   {id:'FSFill', label:'$labels{"fsfill"}',type:'number'},	// FSLevel
                   {id:'UsedInFS', label:'$labels{"infs"}',type:'number'},	// inFS - FSLevel
                   {id:'inLV',label:'$labels{"inlv"}', type:'number'},		// inLV
                   {id:'inVG',label:'$labels{"invg"}', type:'number'}		// inVG
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
                   {id:'FSFill', label:'$labels{"fsfill"}',type:'number'},	// FSLevel
                   {id:'UsedInFS', label:'$labels{"infs"}',type:'number'},	// inFS - FSLevel
                   {id:'inLV',label:'$labels{"inlv"}', type:'number'}		// inLV
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
                                    'vAxis': {'title': '$UNIT','gridlineColor':'#808080'}});
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
