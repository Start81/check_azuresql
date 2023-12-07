## check_azuresql

Check if an azuresql database is up, get a metric or check the longTerm Retention Backup

### prerequisites

This script uses theses libs : REST::Client, Data::Dumper, DateTime, JSON, Monitoring::Plugin

to install them type :

```
sudo cpan  REST::Client Data::Dumper JSON DateTime File::Basename Readonly Monitoring::Plugin
```

### use case

```bash
check_azuresql.pl 2.0.0

This nagios plugin is free software, and comes with ABSOLUTELY NO WARRANTY.
It may be used, redistributed and/or modified under the terms of the GNU
General Public Licence (see http://www.fsf.org/licensing/licenses/gpl.txt).

check_azuresql.pl is a Nagios check that uses Azure s REST API to get azuresql state backup and metrics

Usage: check_azuresql.pl  [-v] -T <TENANTID> -I <CLIENTID> -s <SUBID> -p <CLIENTSECRET> [-m <METRICNAME> -T <INTERVAL>]|[-b -r <REGION>] -H <SERVERNAME> -d <DATABASENAME> [-w <WARNING> -c <CRITICAL>]

 -?, --usage
   Print usage information
 -h, --help
   Print detailed help screen
 -V, --version
   Print version information
 --extra-opts=[section][@file]
   Read options from an ini file. See https://www.monitoring-plugins.org/doc/extra-opts.html
   for usage and examples.
 -T, --tenant=STRING
 The GUID of the tenant to be checked
 -I, --clientid=STRING
 The GUID of the registered application
 -p, --clientsecret=STRING
 Access Key of registered application
 -s, --subscriptionid=STRING
 Subscription GUID
 -e, --earliestRestoreDate
 Flag to check earliestRestoreDate. when used --metrics is ignored
 -m, --metric=STRING
 METRICNAME=cpu_percent | physical_data_read_percent | log_write_percent | dtu_consumption_percent | connection_successful | connection_failed | blocked_by_firewall
           | deadlock | storage_percent | xtp_storage_percent | sessions_percent | workers_percent | sqlserver_process_core_percent | sqlserver_process_memory_percent | tempdb_log_used_percent
 -i, --time_interval=STRING
 TIME INTERVAL use with metric PT1M | PT5M | PT15M | PT30M | PT1H | PT6H | PT12H | P1D
 -H, --Host=STRING
Host name
 -D, --databasename=STRING
Database name
 -w, --warning=threshold
   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT for the threshold format.
 -c, --critical=threshold
   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT for the threshold format.
 -b, --backup
 Flag to check long term backup creation date. when used --metrics is ignored
 -r, --region=<REGION>
   Mandatory with backup flag, region (location) of the long term backup.
 -z, --zeroed
 disable unknown status when receive empty data for a metric
 -t, --timeout=INTEGER
   Seconds before plugin times out (default: 30)
 -v, --verbose
   Show details for command-line debugging (can repeat up to 3 times)
```

sample to get cpu usage: :

```bash
./check_azuresql.pl --tenant=<TENANTID> --clientid=<CLIENTID> --subscriptionid=<SUBID> --clientsecret=<CLIENTSECRET> --Host=devsupervision --databasename=sqlazuresupervision --metric=cpu_percent --Timeinterval=PT5M --warning=80 --critical=90
```

you may get  :

```bash
  OK - CPU percentage = 42.05% | cpu_percent=42.05;80;90
```

Sample for long term backup :

```bash
./check_azuresql.pl --tenant=<TENANTID> --clientid=<CLIENTID> --subscriptionid=<SUBID> --clientsecret=<CLIENTSECRET> --Host=devsupervision --databasename=sqlazuresupervision --backup --region=francecentral --warning=9 --critical=10
```

you may get  :

```bash
  OK - backup is 6 day old  | backup_age=6;9;10
```

