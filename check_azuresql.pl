#!/usr/bin/perl -w
#===============================================================================
# Script Name   : check_azuresql.pl
# Usage Syntax  : check_azuresql.pl [-v] -T <TENANTID> -I <CLIENTID> -s <SUBID> -p <CLIENTSECRET> [-m <METRICNAME> -T <INTERVAL>]|[-b -r <REGION>]
#                                   -H <SERVERNAME> -d <DATABASENAME> [-w <WARNING>] [-c <CRITICAL>]
# Author        : DESMAREST JULIEN (Start81)
# Version       : 2.0.0
# Last Modified : 10/11/2023
# Modified By   : DESMAREST JULIEN (Start81)
# Description   : Check Azure SQL database
# Depends On    : REST::Client, Data::Dumper, DateTime, Getopt::Long
#
# Changelog:
#    Legend:
#       [*] Informational, [!] Bugix, [+] Added, [-] Removed
#
# - 21/05/2021 | 1.0.0 | [*] initial realease
# - 27/05/2021 | 1.0.1 | [!] bug fix
# - 10/06/2021 | 1.0.2 | [+] check if -d|--databasename parameter is present
# - 28/07/2021 | 1.1.0 | [+] add -b option to check long term backup
# - 24/07/2023 | 1.2.0 | [+] save authentication token for next call
# - 18/08/2023 | 1.3.0 | [+] Now the script can only check if the db is running
# - 10/11/2023 | 2.0.0 | [*] implement Monitoring::Plugin lib
#===============================================================================
use REST::Client;
use Data::Dumper;
use JSON;
use Encode qw(decode encode);
use utf8;
use DateTime;
use Getopt::Long;
use File::Basename;
use strict;
use warnings;
use Readonly;
use Monitoring::Plugin;
Readonly our $VERSION => '2.0.0';

my $o_verb;
sub verb { my $t=shift; print $t,"\n" if ($o_verb) ; return 0}
my $me = basename($0);
my $np = Monitoring::Plugin->new(
    usage => "Usage: %s  [-v] -T <TENANTID> -I <CLIENTID> -s <SUBID> -p <CLIENTSECRET> [-m <METRICNAME> -T <INTERVAL>]|[-b -r <REGION>] -H <SERVERNAME> -d <DATABASENAME> [-w <WARNING> -c <CRITICAL>]\n",
    plugin => $me,
    shortname => " ",
    blurb => "$me is a Nagios check that uses Azure s REST API to get azuresql state backup and metrics",
    version => $VERSION,
    timeout => 30
);
my %metrics = ('cpu_percent' => ['%', 'average'],
    'physical_data_read_percent' => ['%', 'average'],
    'log_write_percent' => ['%', 'average'],
    'dtu_consumption_percent' => ['%', 'average'],
    'connection_successful' => ['', 'total'],
    'connection_failed' => ['', 'total'],
    'blocked_by_firewall' => ['', 'total'],
    'deadlock' => ['', 'total'],
    'storage_percent' => ['%', 'maximum'],
    'xtp_storage_percent' => ['%', 'average'],
    'sessions_percent' => ['%', 'average'],
    'workers_percent' => ['%', 'average'],
    'sqlserver_process_core_percent' => ['%', 'maximum'],
    'sqlserver_process_memory_percent' => ['%', 'maximum'],
#    'tempdb_data_size' => ['Kb', 'maximum'],
#    'tempdb_log_size' => ['Kb', 'maximum'],
    'tempdb_log_used_percent' => ['%', 'maximum'],
);

my %interval = ('PT1M' => '1',
    'PT5M' => '5',
    'PT15M' => '15',
    'PT30M' => '30',
    'PT1H' => '60',
    'PT6H' => '360',
    'PT12H' => '720',
    'P1D' => '1440');

#write content in a file
sub write_file {
    my ($content,$tmp_file_name) = @_;
    my $fd;
    verb("write $tmp_file_name");
    if (open($fd, '>', $tmp_file_name)) {
        print $fd $content;
        close($fd);       
    } else {
        my $msg ="unable to write file $tmp_file_name";
        $np->plugin_exit('UNKNOWN',$msg);
    }
    
    return 0
}

#Read previous token  
sub read_token_file {
    my ($tmp_file_name) = @_;
    my $fd;
    my $token ="";
    verb("read $tmp_file_name");
    if (open($fd, '<', $tmp_file_name)) {
        while (my $row = <$fd>) {
            chomp $row;
            $token=$token . $row;
        }
        close($fd);
    } else {
        my $msg ="unable to read $tmp_file_name";
        $np->plugin_exit('UNKNOWN',$msg);
    }
    return $token
    
}

#get a new acces token
sub get_access_token{
    my ($clientid,$clientsecret,$tenantid) = @_;
    verb(" tenantid = " . $tenantid);
    verb(" clientid = " . $clientid);
    verb(" clientsecret = " . $clientsecret);
    #Get token
    my $client = REST::Client->new();
    my $payload = 'grant_type=client_credentials&client_id=' . $clientid . '&client_secret=' . $clientsecret . '&resource=https%3A//management.azure.com/';
    my $url = "https://login.microsoftonline.com/" . $tenantid . "/oauth2/token";
    $client->POST($url,$payload);
    if ($client->responseCode() ne '200') {
        my $msg = "response code : " . $client->responseCode() . " Message : Error when getting token" . $client->{_res}->decoded_content;
        $np->plugin_exit('UNKNOWN',$msg);
    }
    return $client->{_res}->decoded_content;
}

$np->add_arg(
    spec => 'tenant|T=s',
    help => "-T, --tenant=STRING\n"
          . ' The GUID of the tenant to be checked',
    required => 1
);
$np->add_arg(
    spec => 'clientid|I=s',
    help => "-I, --clientid=STRING\n"
          . ' The GUID of the registered application',
    required => 1
);
$np->add_arg(
    spec => 'clientsecret|p=s',
    help => "-p, --clientsecret=STRING\n"
          . ' Access Key of registered application',
    required => 1
);
$np->add_arg(
    spec => 'subscriptionid|s=s',
    help => "-s, --subscriptionid=STRING\n"
          . ' Subscription GUID ',
    required => 1
);
$np->add_arg(
    spec => 'earliestRestoreDate|e',
    help => "-e, --earliestRestoreDate\n"  
         . ' Flag to check earliestRestoreDate. when used --metrics is ignored',
    required => 0
);
$np->add_arg(
    spec => 'metric|m=s',
    help => "-m, --metric=STRING\n"  
        . " METRICNAME=cpu_percent | physical_data_read_percent | log_write_percent | dtu_consumption_percent | connection_successful | connection_failed | blocked_by_firewall\n"
        . "           | deadlock | storage_percent | xtp_storage_percent | sessions_percent | workers_percent | sqlserver_process_core_percent | sqlserver_process_memory_percent | tempdb_log_used_percent",
    required => 0
);
$np->add_arg(
    spec => 'time_interval|i=s',
    help => "-i, --time_interval=STRING\n"   
         . ' TIME INTERVAL use with metric PT1M | PT5M | PT15M | PT30M | PT1H | PT6H | PT12H | P1D ',
    required => 0
);
$np->add_arg(
    spec => 'Host|H=s', 
    help => "-H, --Host=STRING\n"  
         . 'Host name',
    required => 1
);
$np->add_arg(
    spec => 'databasename|D=s', 
    help => "-D, --databasename=STRING\n"  
         . 'Database name',
    required => 1
);
$np->add_arg(
    spec => 'warning|w=s',
    help => "-w, --warning=threshold\n" 
          . '   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT for the threshold format.',
);
$np->add_arg(
    spec => 'critical|c=s',
    help => "-c, --critical=threshold\n"  
          . '   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT for the threshold format.',
);
$np->add_arg(
    spec => 'backup|b',
    help => "-b, --backup\n"  
         . ' Flag to check long term backup creation date. when used --metrics is ignored',
    required => 0
);
$np->add_arg(
    spec => 'region|r=s',
    help => "-r, --region=<REGION>\n"  
          . '   Mandatory with backup flag, region (location) of the long term backup.',
    required => 0
);
$np->add_arg(
    spec => 'zeroed|z',
    help => "-z, --zeroed\n"  
         . ' disable unknown status when receive empty data for a metric',
    required => 0
);

$np->getopts;
my $subid = $np->opts->subscriptionid;
my $tenantid = $np->opts->tenant;
my $clientid = $np->opts->clientid;
my $clientsecret = $np->opts->clientsecret; 
my $o_warning = $np->opts->warning;
my $o_critical = $np->opts->critical;
my $o_server_name = $np->opts->Host;
my $o_metric = $np->opts->metric;
my $o_database_name = $np->opts->databasename;
my $o_time_interval = $np->opts->time_interval;
my $o_backup = $np->opts->backup;
my $o_region = $np->opts->region;
my $o_zeroed = $np->opts->zeroed  if (defined $np->opts->zeroed);
$o_verb = $np->opts->verbose if (defined $np->opts->verbose);
if (defined($o_backup)) {
    if (!defined($o_region)) {
        $np->plugin_exit('UNKNOWN',"Region missing this is mandatory to check long term backup\n");
    }  
} else {

    if (defined($o_metric)) {
        if (!exists $metrics{$o_metric}) {
            my @keys = keys %metrics;
            my $list = join(', ',@keys);
            $np->plugin_exit('UNKNOWN',"Metric " . $o_metric . " not defined. Available metrics are $list\n");
        }
        if (defined($o_time_interval)) {
            if (!exists $interval{$o_time_interval}) {
                my @keys = keys %interval;
                my $list = join(', ',@keys);
                $np->plugin_exit('UNKNOWN',"Time interval " . $o_time_interval . " not defined. Available interval are $list\n");
            }
        } else {
            $np->plugin_exit('UNKNOWN',"Time interval missing\n");
        }
    }
}
my $result;
my @criticals = ();
my @warnings = ();
my @ok = ();
my $i = 0;
my $j = 0;
my $k = 0;
my $server_found = 0;
my $instance_found = 0;
my $resource_group_name;
my $msg_ok = "";
my $msg = "";
my $reponse_instances;
my $reponse_server;
my $server_name;
my $instance_name;
my $server_state;
my $instances_state;
my @server_list;
my @instance_list;
my $url;
my $response_json;
my $status;


verb(" subid = " . $subid);
verb(" tenantid = " . $tenantid);
verb(" clientid = " . $clientid);
verb(" clientsecret = " . $clientsecret);
#Get token
my $tmp_file = "/tmp/$clientid.tmp";
my $token;
my $token_json;
if (-e $tmp_file) {
    #Read previous token
    $token = read_token_file ($tmp_file);
    $token_json = from_json($token);
    #check token expiration
    my $expiration = $token_json->{'expires_on'} - 60;
    my $current_time = time();
    if ($current_time > $expiration ) {
        #get a new token
        $token = get_access_token($clientid,$clientsecret,$tenantid);
        write_file($token,$tmp_file);
        $token_json = from_json($token);
    }
} else {
    $token = get_access_token($clientid,$clientsecret,$tenantid);
    write_file($token,$tmp_file);
    $token_json = from_json($token);
}
verb(Dumper($token_json ));
$token = $token_json->{'access_token'};
verb("Authorization :" . $token);
#Get resourcegroups list
my $client = REST::Client->new();
$client->addHeader('Authorization', 'Bearer ' . $token);
$client->addHeader('Content-Type', 'application/json;charset=utf8');
$client->addHeader('Accept', 'application/json');

#verb(Dumper($response_json));
if ($o_backup) { # backup
    $url = "https://management.azure.com/subscriptions/" . $subid . "/providers/Microsoft.Sql/locations/" . $o_region . "/longTermRetentionServers/"
         . $o_server_name;
    $url = $url . "/longTermRetentionDatabases/" . $o_database_name . "/longTermRetentionBackups?api-version=2021-02-01-preview&onlyLatestPerDatabase=true";
    $client->GET($url);
    if($client->responseCode() ne '200') {
        $msg = "response code : " . $client->responseCode() . " Message : Error when getting last backup" . $client->responseContent();
        $np->plugin_exit('UNKNOWN',$msg);
    }
    $response_json = from_json($client->responseContent());
    #verb(Dumper($response_json));

    my $dt_now = DateTime->now;
    my $backup_date = $response_json->{'value'}->[$i]->{"properties"}->{'backupTime'};
    verb('backupTime ' . $backup_date);

    my @temp = split('T', $backup_date);
    $backup_date = $temp[0];
    my $backup_time = $temp[1];
    @temp = split('-', $backup_date);
    my @temp_time = split(':', $backup_time);
    my $dt = DateTime->new(
        year       => $temp[0],
        month      => $temp[1],
        day        => $temp[2],
        hour       => $temp_time[0],
        minute     => $temp_time[1],
        second     => 0,
        time_zone  => 'UTC',
    );
    $result = $dt_now->delta_days($dt)->in_units('days');
    verb("backup age : " . $result);
    $msg = "backup is " . $result . " day old ";
    $np->add_perfdata(label => "backup_age", value => $result, warning => $o_warning, critical => $o_critical);
    if (defined($o_warning) && defined($o_critical)) {
        $np->set_thresholds(warning => $o_warning, critical => $o_critical);
        $status = $np->check_threshold($result);
        push( @criticals, $msg) if ($status==2);
        push( @warnings, $msg) if ($status==1);
        push (@ok,$msg) if ($status==0); 
    } else {
        push (@ok,$msg);
    }

} else { # Metrics & status
    $url = "https://management.azure.com/subscriptions/" . $subid . "/resourcegroups?api-version=2020-06-01";
    $client->GET($url);
    if($client->responseCode() ne '200') {
        $msg =  "response code : " . $client->responseCode() . " Message : Error when getting resource groups list" . $client->responseContent();
        $np->plugin_exit('UNKNOWN',$msg);
    }
    $response_json = from_json($client->responseContent());
    do {
        $resource_group_name = $response_json->{'value'}->[$i]->{"name"};
        verb("getting server list from resourceGroups :" . $resource_group_name);
        my $get_serveurlist_url = "https://management.azure.com/subscriptions/" . $subid . "/resourceGroups/" . $resource_group_name;
        $get_serveurlist_url = $get_serveurlist_url . "/providers/Microsoft.Sql/servers?api-version=2020-11-01-preview";
        verb($get_serveurlist_url);
        $client->GET($get_serveurlist_url);

        if($client->responseCode() ne '200') {
            $msg =  "response code : " . $client->responseCode() . " Message : Error when getting serveur list " . $client->responseContent();
            $np->plugin_exit('UNKNOWN',$msg);
        }
        $reponse_server = from_json($client->responseContent());
        $j = 0;
        while ((!($server_found)) and (exists $reponse_server->{'value'}->[$j])) {
            $server_name = $reponse_server->{'value'}->[$j]->{'name'};
            if ($server_name eq $o_server_name) {
                $server_found = 1;

                #get instance name by server
                verb($o_server_name . " is ok, getting database list from server");
                my $get_instances_url = "https://management.azure.com/subscriptions/" . $subid . "/resourceGroups/" . $resource_group_name;
                $get_instances_url = $get_instances_url . "/providers/Microsoft.Sql/servers/" . $server_name . "/databases?api-version=2020-11-01-preview";
                verb($get_instances_url);
                $client->GET($get_instances_url);
                if($client->responseCode() ne '200') {
                    $msg = "response code : " . $client->responseCode() . " Message : Error when getting database list " . $client->responseContent();
                    $np->plugin_exit('UNKNOWN',$msg);
                } 
                $reponse_instances = from_json($client->responseContent());

                while (exists $reponse_instances->{'value'}->[$k]) {
                    $instance_name = $reponse_instances->{'value'}->[$k]->{'name'};

                    if ($instance_name eq $o_database_name) {
                        $instance_found = 1;
                        #Getting metric
                        if ($o_metric) {
                            my $now = DateTime->now;
                            $now->set_time_zone("UTC");
                            my $begin = $now->clone;
                            $begin = $begin->subtract(minutes => $interval{$o_time_interval});
                            my $date_now_str = $now->ymd("-") . "T" . $now->hms('%3A') . "Z";
                            my $date_begin_str = $begin->ymd("-") . "T" . $begin->hms('%3A') . "Z";
                            my $get_metric_url = "https://management.azure.com/subscriptions/" . $subid . "/resourcegroups/" . $resource_group_name;
                            $get_metric_url = $get_metric_url . "/providers/Microsoft.Sql/servers/" . $server_name . "/databases/" . $instance_name;
                            $get_metric_url = $get_metric_url . "/providers/microsoft.insights/metrics?api-version=2018-01-01&timespan=" . $date_begin_str;
                            $get_metric_url = $get_metric_url . "%2F" . $date_now_str . "&interval=" . $o_time_interval . "&metricnames=" . $o_metric;
                            verb($get_metric_url);
                            $client->GET($get_metric_url);
                            if($client->responseCode() ne '200') {
                                $msg =  "response code : " . $client->responseCode() . " Message : Error when getting metric " . $client->responseContent();
                                $np->plugin_exit('UNKNOWN',$msg);
                            }
                            my $reponse_metrics = from_json($client->responseContent());
                            #Check if desired data exist
                            if (!exists $reponse_metrics->{'value'}->[0]->{'timeseries'}->[0]->{'data'}->[0]->{$metrics{$o_metric}->[1]}) {
                                if (defined $o_zeroed){
                                    $result = 0
                                } else {
                                    $msg =  "metric " . $o_metric . " unavailable or empty data " . Dumper($reponse_metrics);
                                    $np->plugin_exit('UNKNOWN',$msg);
                                } 
                            } else {
                                $result = sprintf("%.2f",$reponse_metrics->{'value'}->[0]->{'timeseries'}->[0]->{'data'}->[0]->{$metrics{$o_metric}->[1]});
                            }
                            $msg = $reponse_metrics->{'value'}->[0]->{'name'}->{'localizedValue'} . " = " . $result . $metrics{$o_metric}->[0];
                            $np->add_perfdata(label => $o_metric, value => $result, warning => $o_warning, critical => $o_critical);
                            if (defined($o_warning) && defined($o_critical)) {
                                $np->set_thresholds(warning => $o_warning, critical => $o_critical);
                                $status = $np->check_threshold($result);
                                push( @criticals, $msg) if ($status==2);
                                push( @warnings, $msg) if ($status==1);
                                push (@ok,$msg) if ($status==0); 
                            } else {
                                push (@ok,$msg);
                            }
                            #End get metric
                        } else {
                            #check db server state
                            $server_state = $reponse_server->{'value'}->[$j]->{'properties'}->{'state'}; #OK Ready
                            $msg = "$o_server_name status is $server_state";
                            if ($server_state ne "Ready") {
                                push( @criticals, $msg);
                            } else {   
                                push (@ok,$msg);
                            }
                            #Check db status
                            $instances_state = $reponse_instances->{'value'}->[$k]->{'properties'}->{'status'}; #OK Online
                            $msg =  "Database $o_database_name status is $instances_state ";
                            if ($instances_state ne "Online") {
                                push( @criticals, $msg);
                            
                            } else {
                                push (@ok,$msg);
                            }
                        }
                    } else {
                        push(@instance_list, $instance_name);
                    }
                    $k++;
                }
                if ($instance_found != 1) {
                    $msg = "database " . $o_database_name . " not found on " . $o_server_name . " available database(s) are : " . join(", ", @instance_list);
                    $np->plugin_exit('UNKNOWN',$msg);
                }
            } else {
                push(@server_list, $server_name);
            }
            $j++;
        }
        $i++;
    }  while (exists $response_json->{'value'}->[$i] and (!($server_found)));

    if ($server_found != 1) {
        $msg =  "server " . $o_server_name . " not found. Available server(s) are : " . join(", ", @server_list);
        $np->plugin_exit('UNKNOWN',$msg);
    }
}
$np->plugin_exit('CRITICAL', join(', ', @criticals)) if (scalar @criticals > 0);
$np->plugin_exit('WARNING', join(', ', @warnings)) if (scalar @warnings > 0);
$np->plugin_exit('OK',join(', ', @ok ));