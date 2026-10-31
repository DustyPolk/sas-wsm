# Copyright © 2021, SAS Institute Inc., Cary, NC, USA.  All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# SAS-wsm: Script to Start/Stop Windows Services and validate MidTier Readiness
# Version: 2.2.0
# Author: Andy Foreman
# Much of the baseline code derived from previous work by Greg Wootton on 20AUG2020
# Special thanks to John Maxwell for auto-setup start/stop concept implemented in 2.0.0 on 12JUL2023.
####
# Revision History
# 1.0.0 - 16 May 2022
# 1.0.1 - 22 August 2022. Add check on null arrays during webappserver log reading due to rolled logs.
# 1.1.0 - 15 September 2022. Change to external cfg file for service definitions. Add search, input checking and validation functions. Code revisions to support cfg file, etc.
# 2.0.0 - 12 July 2023. Major revisions/rewrite. Merge with auto-setup start/stop script. Add supporting functions and parameters. Retain external cfg as optional support. Remove external cfg tester action.
# 2.1.0 - 29 May 2025. Added detailed audit logging
# 2.1.1 - 16 June 2026. Un-archive project. Merge v.2.1.0 / PR #4 audit logging contributions into main branch. Confirm operations on modern SAS 9.4 maintenance releases. Adjust default startup order to improve startup success of critical services (i.e. when some non-critical services are non-operational).
# 2.2.0 - 29 October 2026. Configurable daily audit log, per-service timing, run summary, and non-zero exit on failure. Click-to-run start/stop/status launchers.

### TODOS
# Implement "skip" function to permit a user to ignore the state/status/control-failure of a specific service

### GET USER INPUTS
# Get user-specified action as input
# $action = <start|stop|status> [required]
# $saslev = ....\SASConfig\LevN path. Used to verify WebAppServer startup. Script will attempt to determine this if not specified. Example: C:\SAS\Config\Lev1
# $cfg = Custom startup order configuration file. Default order is defined in this file and will be used if not specified.
# $LogDirectory = Folder for the daily audit log. Default is the folder that contains this script. File name: SAS-wsm_yyyyMMdd.log
param([Parameter(Mandatory=$true)]$action,$saslev,$cfg,$LogDirectory)

### AUDIT LOGGING SETUP
# One log file per day. -LogDirectory overrides the default (this script's folder).
$script:ScriptVersion = "2.2.0"
if (-not $LogDirectory) { $LogDirectory = $PSScriptRoot }
if (-not $LogDirectory) { $LogDirectory = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $script:LogDirectory -PathType Container)) {
	try {
		New-Item -ItemType Directory -Path $script:LogDirectory -Force -ErrorAction Stop | Out-Null
	}
	catch {
		Write-Host -ForegroundColor Red "ERROR: Unable to create log directory $($script:LogDirectory). $_"
		Exit 1
	}
}
$script:LogPath = Join-Path -Path $script:LogDirectory -ChildPath "SAS-wsm_$(Get-Date -Format 'yyyyMMdd').log"
$script:SessionId = [guid]::NewGuid().ToString().Substring(0,8)
$script:RunStarted = Get-Date
$script:ServicesChanged = 0
$script:ServicesSkipped = 0
$script:ServicesFailed = 0
$script:ServicesPlanned = 0
$script:RunFailed = $false

# Logging function
FUNCTION Write-AuditLog {
    param(
        [string]$Level = "INFO",
        [string]$Message,
        [string]$ServiceName = "",
        [string]$Action = "",
        [string]$Status = ""
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $hostname = $env:COMPUTERNAME
    
    # Build log entry
    $logEntry = "[$timestamp] [$Level] [Session:$script:SessionId] [User:$user] [Host:$hostname]"
    
    if ($ServiceName) { $logEntry += " [Service:$ServiceName]" }
    if ($Action) { $logEntry += " [Action:$Action]" }
    if ($Status) { $logEntry += " [Status:$Status]" }
    
    $logEntry += " $Message"
    
    # Write to log file. WARN and ERROR are also printed so a double-clicked launcher shows them.
    try {
        Add-Content -Path $script:LogPath -Value $logEntry -ErrorAction Stop
    }
    catch {
        Write-Host -ForegroundColor Red "LOGGING ERROR: $_"
    }
    if ($Level -eq "ERROR" -or $Level -eq "WARN") {
        $consoleMessage = "${Level}: $Message"
        if ($ServiceName) { $consoleMessage = "${Level}: [$ServiceName] $Message" }
        if ($Level -eq "ERROR") { Write-Host -ForegroundColor Red $consoleMessage }
        else { Write-Host -ForegroundColor Yellow $consoleMessage }
    }
}

# Close a run with one summary line. Failed runs exit 1 so launchers and schedulers can see it.
FUNCTION Complete-Run {
    param([string]$Result)
    $elapsed = (Get-Date) - $script:RunStarted
    $elapsedText = $elapsed.ToString("hh\:mm\:ss")
    $message = "SAS-wsm script ended result=$Result action=$action processed=$($script:ServicesPlanned) changed=$($script:ServicesChanged) skipped=$($script:ServicesSkipped) failed=$($script:ServicesFailed) duration=$elapsedText log=$($script:LogPath)"
    if ($Result -eq "failed") {
        Write-AuditLog -Level "ERROR" -Message $message -Action $action -Status $Result
    }
    else {
        Write-AuditLog -Level "INFO" -Message $message -Action $action -Status $Result
        Write-Host -ForegroundColor Green "SAS-wsm $action completed in $elapsedText. Audit log: $($script:LogPath)"
    }
}

# Log script startup
Write-Host "INFO: Audit log: $($script:LogPath)"
Write-AuditLog -Level "INFO" -Message "SAS-wsm script started version=$($script:ScriptVersion)" -Action $action
Write-AuditLog -Level "INFO" -Message "Parameters: action=$action, saslev=$saslev, cfg=$cfg, LogDirectory=$($script:LogDirectory)"


#  define main function used to stop / start.  (called at end of script). 
FUNCTION STOPSTART-SASSERVICE ($action,$service,$waitforstate){
	if ($null -eq $service) {
		$script:ServicesFailed++
		$script:RunFailed = $true
		Write-AuditLog -Level "ERROR" -Message "Service list contained an empty entry" -Action $action
		throw "ERROR: service list contained an empty entry."
	}
	$service.Refresh()
	$operationStarted = Get-Date
	Write-AuditLog -Level "INFO" -Message "Processing service" -ServiceName $service.DisplayName -Action $action -Status $service.status
	$timeoutSeconds=300 #5 minutes timeout
	$serviceWaitTimeout = New-Object Timespan 0,0,$timeoutSeconds #define object to reference max allowed wait time (in seconds) for Windows to recieve notification that service completed action. This normally takes only a few seconds.
    Write-Host "`n"
    Write-Output '-------------------------------------'
    Write-Host $service.DisplayName "is currently --  " $service.status
    Write-Output '-------------------------------------'
    If ($service.status -NE $waitforstate){
        Write-Host "attempting to $action --  " $service.DisplayName
        Write-Output '-------------------------------------'
        If ($action -eq "stop"){
            Write-AuditLog -Level "INFO" -Message "Attempting to stop service" -ServiceName $service.DisplayName -Action $action -Status $service.status
            Stop-Service -InputObject $service -WarningAction SilentlyContinue -ErrorAction Stop -NoWait #because -NoWait, will not hold here for Windows to report stopped. Check for actually stopped happens from $service.WaitForStatus
        }
        ElseIf ($action -eq "start"){
            Write-AuditLog -Level "INFO" -Message "Attempting to start service" -ServiceName $service.DisplayName -Action $action -Status $service.status
			Start-Service -InputObject $service -WarningAction SilentlyContinue -ErrorAction Stop #the -NoWait parameter is not available on START operation. If Windows hangs on starting the service, this will too. Can start as background job to avoid this but has major complexity in passing $service object.
        }        
        start-sleep -s 3
		Try {
			$service.WaitForStatus($waitforstate, $serviceWaitTimeout) #await service to report desired status $waitforstate (stop, if we are stopping), or time out after $serviceWaitTimeout timespan object is exceeded. This is equal to $timeoutSeconds seconds
			$elapsedSeconds = [math]::Round(((Get-Date) - $operationStarted).TotalSeconds, 1)
			Write-Host $service.DisplayName "status is:-- " $service.status
			Write-AuditLog -Level "INFO" -Message "Service action completed successfully in ${elapsedSeconds}s" -ServiceName $service.DisplayName -Action $action -Status $service.status
			$script:ServicesChanged++
			Write-Host "`n"
		}
		Catch {
			$elapsedSeconds = [math]::Round(((Get-Date) - $operationStarted).TotalSeconds, 1)
			$script:ServicesFailed++
			$script:RunFailed = $true
			Write-AuditLog -Level "ERROR" -Message "Service failed to reach $waitforstate within $timeoutSeconds seconds (elapsed ${elapsedSeconds}s)" -ServiceName $service.DisplayName -Action $action -Status $service.status
			throw "ERROR: $action terminated due to $($service.DisplayName) failed to report $waitforstate within $timeoutSeconds seconds."
		}
    }
    else {
        $elapsedSeconds = [math]::Round(((Get-Date) - $operationStarted).TotalSeconds, 1)
        Write-Host "skipping $action action because service is already $waitforstate"
        Write-AuditLog -Level "INFO" -Message "Skipping service - already in desired state (${elapsedSeconds}s)" -ServiceName $service.DisplayName -Action $action -Status $waitforstate
        $script:ServicesSkipped++
        Write-Output '-------------------------------------'
    }
    start-sleep -s 1
}

FUNCTION CHECK-WEBAPPSERVER-READY($servicename){
	# wait for webappservers to finish deploying webapps before considering them truly started
	If ($script:sasconfigpath.length -gt 0) {
		# Do not pipe the display name. PowerShell enumerates a string into characters.
		$webappsvrname = $null
		if ($servicename -match '\b(SASServer\d+_\d+)\b') {
			$webappsvrname = $Matches[1]
		}
		if (-not $webappsvrname) {
			Write-AuditLog -Level "WARN" -Message "Could not parse WebAppServer instance name; skipping deployment check" -ServiceName $servicename
			return
		}
		$serverLog = Join-Path $script:sasconfigpath "Web\WebAppServer\$webappsvrname\logs\server.log"
		if (-not (Test-Path -LiteralPath $serverLog -PathType Leaf)) {
			Write-AuditLog -Level "WARN" -Message "WebAppServer log not found; skipping deployment check: $serverLog" -ServiceName $servicename
			return
		}
		Write-AuditLog -Level "INFO" -Message "Checking WebAppServer deployment status in $serverLog" -ServiceName $servicename
		Write-Host ("INFO: Checking if Web Application Server $webappsvrname has finished deploying web applications... (this may take a while)")

		$startchecks=0;
		$finishedstart=0;
		Do {
			#pull a list of line numbers from the WebAppServer's server log, matching string indicating server stop operation, then keep only the last member of the list (the latest matching line number)
			$laststop = Select-String -Path $serverLog -Pattern 'Stopping service \[Catalina\]' | select-object -ExpandProperty LineNumber
			if ($null -eq $laststop) {
				#Enter here if we did not find any matches on the Pattern search, which can happen if the log file is new or rolled.
				#In this instance, just consider the last action as line 0 for logic. lastinit should always be line 1 in this case. This prevents assigning on null arrays.
				$laststop=0
			}
			else {
				$laststop = $laststop[-1]
			}

			#same as laststop but for initialization message (printed when the server starts loading its webapps)
			#message changes depending on hotfix level... old is 'Initialization processed' , new is 'Server initialization'
			#if lastinit never finds a match, probably still on old version and need to change the string after -Pattern below to use the old syntax as shown above
			$lastinit = Select-String -Path $serverLog -Pattern '(Server initialization)|(Initialization processed)' | select-object -ExpandProperty LineNumber
			if ($null -eq $lastinit) {
				$lastinit=0
			}
			else {
				$lastinit = $lastinit[-1]
			}

			#same as laststop but for startup message (printed when the server has finished loading all webapps)
			$laststart = Select-String -Path $serverLog -Pattern 'Server startup' | select-object -ExpandProperty LineNumber
			if ($null -eq $laststart) {
				$laststart=0
			}
			else {
				$laststart = $laststart[-1]
			}

			if ($laststop -gt $lastinit){
				#if newest thing in log is stop, there was a problem
				$script:ServicesFailed++
				$script:RunFailed = $true
				Write-AuditLog -Level "ERROR" -Message "Server initialization does not appear to have started. Log: $serverLog" -ServiceName $servicename
				write-host("ERROR: Server initialization does not appear to have started. Verify Web Application Server $webappsvrname is running.")
				Complete-Run -Result "failed"
				Exit 1
			}
			elseif($laststart -gt $lastinit){
				#if newest thing in log is startup complete, the webappserver is ready
			   write-host("INFO: $webappsvrname startup detected.")
			   Write-AuditLog -Level "INFO" -Message "WebAppServer startup completed. Log: $serverLog" -ServiceName $servicename
			   $finishedstart=1;
			   Continue
			}
			else {
				#wait a minute then check again
				Write-Host "Startup in progress. Checking again in 60 seconds..."
				Start-Sleep 60
				$startchecks++;
			}
		}
		while (($finishedstart -ne 1) -and ( $startchecks -le 30))
			if ($finishedstart -ne 1) {
					Write-AuditLog -Level "WARN" -Message "WebAppServer startup timeout after $($startchecks) checks - may still be deploying. Log: $serverLog" -ServiceName $servicename
					Write-Host ("WARN: Web Application Server $webappsvrname has still not completed startup operations. Some Web Applications may still be unavailable until the WebAppServer has fully completed startup.")
			}
	}
	Else {
		Write-AuditLog -Level "WARN" -Message "Skipped deployment check because the SAS configuration directory is not set. Web applications may still be loading. Pass -saslev to enable this check." -ServiceName $servicename
	}
}

FUNCTION DETERMINE-SASCONFIG-DIR ($potentialcfgsvc) {
	# Read properties of Windows Services that might reference the SASConfig path.
	# Attempt to determine this and set it so it can be used elsewhere in the script.
	# Enable user to manually specify in case they have nonstandard configuration or want to directly control locations used by other functions.
	
	$cfgfilter="Name='" + "$potentialcfgsvc" + "'" #build proper format for upcoming Get-CimInstance call
	#Write-Host "We built cfgfilter: $cfgfilter" #debug
	$cfgpathobj=(Get-CimInstance -ClassName win32_service -Filter "$cfgfilter").PathName #obtains the 'PathName' object on the passed Windows Service.
	
	If ($cfgpathobj -match '(?<=-config ").*?Lev\d') {
		#METADATA SERVER. Regex match that takes anything after literal `-config "` and ending on `Lev#`, where # is any single numerical digit. This should result in, for example, C:\SAS\Config\Lev1 , from where the sasv9.cfg is specified in command.
			$script:sasconfigpath=$cfgpathobj -match '(?<=-config ").*?Lev\d' | Foreach {$matches[0]}
			Write-Host "INFO: Successfully determined the SAS Configuration Directory path: $script:sasconfigpath"
			Write-AuditLog -Level "INFO" -Message "Determined SAS Configuration Directory: $script:sasconfigpath" -ServiceName $potentialcfgsvc
	}
	ElseIf ($cfgpathobj -match '\b.*?Lev\d') {
		#JMS BROKER AND/OR CACHE LOCATOR. Regex match that takes from beginning of word until `Lev#`. This match functions on both services, where the beginning of the PathName is the SASConfig dir. Note this actually returns multiple matches, take the first one (later ones have prepended junk)
			$script:sasconfigpath=$cfgpathobj -match '^\W*(.*?Lev\d)' | Foreach {$matches[1]}
			Write-Host "INFO: Successfully determined the SAS Configuration Directory path: $script:sasconfigpath"
			Write-AuditLog -Level "INFO" -Message "Determined SAS Configuration Directory: $script:sasconfigpath" -ServiceName $potentialcfgsvc
	}
	Else {
		Write-AuditLog -Level "WARN" -Message "Failed to determine SAS Configuration Directory. If this repeats for every service, pass -saslev. Example: -saslev C:\SAS\Config\Lev1" -ServiceName $potentialcfgsvc
	}
}

### MAIN START HERE
If ($saslev) {
	#user specified a SASConfig path using the -saslev parameter, so try to validate it
	If (Test-Path -Path $saslev\ConfigData\status.xml -PathType leaf) { #status.xml is used by other SAS deployment services and thus should always be in this relative path under sasconfig dir
		$script:sasconfigpath="$saslev" #set the user input to script-scope var used elsewhere
		Write-Host "INFO: Verified SAS Configuration Directory path, using $script:sasconfigpath for this run."
		Write-AuditLog -Level "INFO" -Message "User specified SAS Configuration Directory verified: $script:sasconfigpath"
	}
	Else {
		# If the status.xml file does not exist under provided sasconfigdir path, probably not actually a sasconfig dir
		Write-AuditLog -Level "ERROR" -Message "Invalid SAS Configuration Directory specified: $saslev"
		Write-Host "ERROR: Unable to determine if provided folder path contains a SAS Configuration Directory."
		Write-Host "ERROR: Verify that the provided path is correct and includes the LevN."
		Write-Host "ERROR: Example: C:\SAS\Config\Lev1"
		Write-Host "ERROR: Also verify the user running this script has read permissions to the location and subfolders."
		Write-Host "`n"
		Write-Host "ERROR: Alternatively you may leave the -saslev paramater unspecified and the script will attempt to determine it automatically from Windows Services on this host."
		Write-Host "`n"
		Complete-Run -Result "failed"
		Exit 1
	}
}
Else {
	#user did not specify a SASConfig path when calling script
	$script:sasconfigpath="" #init empty string to store sasconfig path, this will flag later processes to try and determine it using service properties
}

If ($cfg) {
	#user specified a custom startup configuration file using the -cfg parameter, so use that file to build service startup order
	If (Test-Path -Path $cfg -PathType leaf) { #make sure the file exists before trying to parse it
		$StaticStartOrder=@()
		[string[]]$StaticStartOrder = Get-Content -Path "$cfg" #inherent for loop; read each line of $cfg file and load into array $StaticStartOrder as string
		Write-Host "NOTE: Loaded custom startup order from file $cfg"
		Write-AuditLog -Level "INFO" -Message "Loaded custom startup order from file: $cfg"
		$script:UserOrder=1 #set flag to mark this run as using custom user-specified order file (affects matching logic to avoid user-specified file being forced to adhere to regex literal cleansing)
		$StaticStartOrder
	}
	Else {
		Write-AuditLog -Level "ERROR" -Message "Custom startup order file not found: $cfg"
		Write-Host "ERROR: A custom startup order file was set but the file could not be read. Verify path and permissions."
		Complete-Run -Result "failed"
		Exit 1
	}
}
Else {
	#user did not specify a startup configuration file. Use the "standard" startup order and regex to capture all known possiblities and all known SAS services. Default behavior.
	
	# define the order SAS services order in an array using regular experision. 
	# some experssions will match more than one service
	$StaticStartOrder=@()
	$StaticStartOrder = @(
		".*Metadata Server",  
		".*Web Infrastructure Platform Data Server",
		".*DataServer",
		".*Data Server",
		".*object spawner",
	   #".*Deployment Tester server", #typically not started unless testing your deployment
		".*JobRunner", #Distributed In-Process Scheduler Job Runner
		".*Launcher",
		".*Workload Orchestrator",
		".*JMS Broker",
		".*Cache Locator",
		".*Information Retrieval Studio",
		".*httpd-WebServer",
		".*httpd - WebServer",
	   #".*Remote Services", # Deprecated Functionality in SAS 9.4
		".*SASServer1_1", #SASServer1_1 must be before other remaining WebServers, Web Application Server
		".*WebAppServer", #Remaining Web Application Servers in any order
		".*Environment Manager(?!\s+Agent)", #server before the agent; the old (?!agent) only looked at the start of the name
		".*Environment Manager Agent", #now get the agent
		".*PC Files",
		".*Deployment Agent",
		".*LSF Process Manager",
		".*LSF LIM",
		".*LSF RES",
		".*LSF SBD",
		".*SHARE server",
		".*CONNECT spawner",
		".*OLAP Server"
		#,".*" #start everything -- will launch anything that $GetSASServices locates, even if not defined in this list. Also means things in this list but commented out will be launched. Can be useful for setup, but recommend defining actual names for regular use.
		)

	$script:UserOrder=0 #set flag to designate user did not specify custom startup order
}

# create  an object that holds all Windows Services with SAS in the name -  it is unordered 
# exclude services set to disabled starttype unless service is running
$GetSASServices = Get-Service | 
    where-object {$_.displayname -Match "^SAS|^IBM Spectrum"-and
    ($_.starttype -NE 'Disabled' -or 
     $_.status -EQ 'running') }
Write-AuditLog -Level "INFO" -Message "Found $($GetSASServices.Count) SAS services on this system"

# ---- add each service in $GetSASServices into order into $startorder ----
$startorder=@()
foreach($DefinedService in $StaticStartOrder) { #"outer loop" -> check each object defined in list $StaticStartOrder
	#Write-Host "StaticStartOrder value check: $DefinedService" #debug
	
	
    foreach($service in $GetSASServices){ #"inner loop" -> loop through each service matching SAS in the name (from where-object query that made $GetSASServices)
		#$debugsvcname = $service.DisplayName #debug
		#Write-Host "GetSASServices value check: $debugsvcname" #debug
		If ($script:UserOrder -eq 1) {
			#behavior to use if user provided custom startup order file. USES LITERAL MATCHING.
			if($service.DisplayName -eq "$DefinedService"){ #compare the current service (inner loop) to the current static service order (outer loop)
		
			if ($service -cnotin $StartOrder) { # if there is a match, and it does not already exist in the ordered-list-of-services $StartOrder
				#Write-Host "Literal name $DefinedService matched to service name $debugsvcname , so adding to start order!" #debug
				$StartOrder+=$service
				}
			else { # if there is a match, BUT it's already in the ordered-list-of-services $StartOrder.
				#Write-Host "Literal name $DefinedService matched to service name $debugsvcname , but already exists in StartOrder list. Skipping..." #debug\
				continue
				}
			
			}
		}
        Else {
			#default behavior to run when user did not provide custom startup order file. USES REGEX MATCHING.

			if($service.DisplayName -match "$DefinedService"){ #compare the current service (inner loop) to the current static service order (outer loop)
		
			if ($service -cnotin $StartOrder) { # if there is a match, and it does not already exist in the ordered-list-of-services $StartOrder
				#Write-Host "Regex name $DefinedService matched to service name $debugsvcname , so adding to start order!" #debug
				$StartOrder+=$service
				}
			else { # if there is a match, BUT it's already in the ordered-list-of-services $StartOrder.
				#Write-Host "Regex name $DefinedService matched to service name $debugsvcname , but already exists in StartOrder list. Skipping..." #debug\
				continue
				}
			
			}
		}
		#if here -> not a match, so do nothing... just go to the next service (inner loop)
    }
	
	# This function could use improvement for theoretical efficiency. It is currently highly inefficient.
	# This function in reality completes in a fraction of a second, so the objective effort of changing it is probably not worthwhile.
	#
	# The current function could best be described as a selection sort mixed with a gnome sort? There is no logic to ignore already selected/sorted values.
	# Whenever a match is found, it is checked against the current output (sorted list). If already in the sorted list, it is treated the same as if there was no match at all.
	# The result is you check everything against everything else, but only allow it into the sorted list once, so in the end you have a sorted list of unique values.
	# You just do a lot of unnecessary checks to get there.
	#
	# THE BASIC LOGIC OF THIS FUNCTION AS IT STANDS IS AS FOLLOWS:
	# 1. Get the static list value #1 from position 0 of the array $StaticStartOrder, which is either user-defined (-cfg flag) or from a 'standard' order defined in this file.
	# 		> The example outlined here will reference define values used when checking the SAS Metadata Server
	# 2. Compare to the first value in the located list of services that contain 'SAS' ($GetSASServices).
	#	a.	If the user specified their own startup order configuraton, perform a literal check. 
	#			> Is "Metadata Server" = "randomserviceSAS" ?
	#			> No
	#	b.  If no startup order configuration was specified, perform a regex-based matching check referencing default startup order defined within this file.
	#		Examples past this step use literal ( = ), but regex match is very similar logically.
	#			> Is ".*Metadata Server" a regex match to "randomserviceSAS" ?
	#			> No
	# 3. Is "Metadata Server" = "SAS [Config-Lev1] Connect Spawner" ?
	#		> No
	# 4. Is "Metadata Server" = "SAS [Config-Lev1] SASMeta - Metadata Server" ?
	#		> Yes
	#		> Add "SAS [Config-Lev1] SASMeta - Metadata Server" to position 0 of list/array $StartOrder
	# 5. Is "Metadata Server" = "SAS [Config-Lev1] OLAP Server" ?
	#		> No
	# 6. Continue until checked all values we located on the machine that contain 'SAS' ($GetSASServices)
	# 7. Change static list value to the next position of the static list ($StaticStartOrder position 1). This is "Web Infrastructure Platform Data Server"
	# 8. Is "Web Infrastructure Platform Data Server" = "SAS [Config-Lev1] SASMeta - Metadata Server" ?
	#		> No
	# 9. Is "Web Infrastructure Platform Data Server" = "SAS [Config-Lev1] Web Infrastructure Platform Data Server" ?
	#		> Yes
	#		> Add "SAS [Config-Lev1] Web Infrastructure Platform Data Server" to position 1 of list/array $StartOrder
	# 10. Basically step 6 again. This all continues (7, 8, 9...) until we have looped through the entirety of $StaticStartOrder.
	
	
}
$StartOrder = @($StartOrder)
$orderedNames = @($StartOrder | ForEach-Object { $_.DisplayName })
$script:ServicesPlanned = $orderedNames.Count
Write-AuditLog -Level "INFO" -Message "Service order ($($orderedNames.Count)): $($orderedNames -join '; ')" -Action $action
$candidateServices = @()
if ($null -ne $GetSASServices) { $candidateServices = @($GetSASServices) }
$unmatched = @($candidateServices | Where-Object { $orderedNames -notcontains $_.DisplayName })
if ($unmatched.Count -gt 0) {
	$unmatchedNames = @($unmatched | ForEach-Object { $_.DisplayName }) -join "; "
	Write-AuditLog -Level "WARN" -Message "Services present but not included in this run ($($unmatched.Count)): $unmatchedNames"
}
if ($script:ServicesPlanned -eq 0) {
	if ($action -eq "status") {
		Write-AuditLog -Level "WARN" -Message "No services matched the startup order." -Action $action
	}
	else {
		Write-AuditLog -Level "ERROR" -Message "No services matched the startup order. Nothing was $action." -Action $action
		Complete-Run -Result "failed"
		Exit 1
	}
}

# setup variables needed by custom function, "StopStart-SASService"  
If ($action -eq "stop"){
    $waitforstate='stopped'
    if ($StartOrder.Count -gt 0) {
        $services=$StartOrder[($StartOrder.Count - 1)..0]
    }
    else {
        $services=@()
    }
    $stopNames = @($services | ForEach-Object { $_.DisplayName }) -join "; "
    Write-AuditLog -Level "INFO" -Message "Preparing to stop services in reverse order: $stopNames"
    }
ElseIf ($action -eq "start"){
    $waitforstate='running'
    $services=$StartOrder
    Write-AuditLog -Level "INFO" -Message "Preparing to start services in defined order: $($orderedNames -join '; ')"
    }
ElseIf ($action -eq "status"){
	$services=$StartOrder
	Write-AuditLog -Level "INFO" -Message "Checking status of $($orderedNames.Count) services"
	}
Else {
    Write-AuditLog -Level "ERROR" -Message "Unknown action specified: $action. Valid actions: start, stop, status"
    Complete-Run -Result "failed"
    Exit 1
}

# --- Main Action in Script --- 
# Loop over the function for each service to stop or start 
Write-AuditLog -Level "INFO" -Message "Starting main action loop for $($script:ServicesPlanned) services" -Action $action
TRY
{
	If ($action -eq "status"){
		Write-Host "`n"
		Write-Host -ForegroundColor Green "Current Status of SAS services:"
		foreach ($service in @($services)) {
			if ($null -eq $service) { continue }
			try {
				$service.Refresh()
				Write-AuditLog -Level "INFO" -Message "Current status" -ServiceName $service.DisplayName -Action "status" -Status "$($service.Status)"
			}
			catch {
				$script:ServicesFailed++
				$script:RunFailed = $true
				Write-AuditLog -Level "ERROR" -Message "Unable to read service status: $($_.Exception.Message)" -ServiceName "$($service.DisplayName)" -Action "status"
			}
		}
		$services | Format-Table -Property Status, Displayname -AutoSize
		if ($script:RunFailed) {
			throw "ERROR: status could not be read for $($script:ServicesFailed) service(s)."
		}
		Write-AuditLog -Level "INFO" -Message "Status check completed for $($script:ServicesPlanned) services"
	}
	Else {
    Write-Output '-------------------------------------'
    $services | Format-Table -Property Status, Displayname -AutoSize
    Write-Output '-------------------------------------'
    Write-Host "change the state to $action for:"
    Foreach ($service in $services) {
        StopStart-SASService -action $action -service $service -waitforstate $waitforstate
		
		#catch webappservers and check if really started
		If ("$($service.DisplayName)" -match 'WebAppServer' -And $action -eq "start") {
			Check-WebAppServer-Ready -servicename "$($service.DisplayName)" #run webappserver startup validation
		}
		
		#catch various services that could tell us the sasconfig path, if match then check if we already set sasconfig path; attempt to set it if we have not
		If ("$($service.DisplayName)" -match 'Metadata Server' -Or "$($service.DisplayName)" -match 'JMS Broker' -Or "$($service.DisplayName)" -match 'Cache Locator') {
			Write-Host "INFO: Attempting to determine SAS Configuration Directory..."
			If ($script:sasconfigpath.length -gt 0) {
				Write-Host "INFO: SAS Configuration Directory is already set. Current value: $script:sasconfigpath"
			}
			ElseIf ("$($service.DisplayName)" -match 'Metadata Server') {
				Write-Host "Note: Attempting to automatically determine using Metadata Server..."
				Determine-SASConfig-Dir -potentialcfgsvc "$($service.DisplayName)"
			}
			ElseIf ("$($service.DisplayName)" -match 'JMS Broker') {
				Write-Host "INFO: Attempting to automatically determine using JMS Broker..."
				Determine-SASConfig-Dir -potentialcfgsvc "$($service.DisplayName)"
			}
			ElseIf ("$($service.DisplayName)" -match 'Cache Locator') {
				Write-Host "INFO: Attempting to automatically determine using Cache Locator..."
				Determine-SASConfig-Dir -potentialcfgsvc "$($service.DisplayName)"
			}
			Else {
				Write-Host "ERROR: Unexpected condition. Entered the sasconfig determination function but failed to match a service displayname that could potentially tell us the sasconfig."
			}
		}
		
    }
    Write-Host "`n"
    Write-Output '-------------------------------------'
    Write-Host -ForegroundColor Green " Script Finished - Current Status of SAS services in order they were $waitforstate :"
    Write-Output '-------------------------------------'
    $services | Format-Table -Property Status, Displayname -AutoSize
	}
	Complete-Run -Result "success"
}
CATCH
{
	if (-not $script:RunFailed) { $script:ServicesFailed++ }
	$script:RunFailed = $true
	Write-AuditLog -Level "ERROR" -Message "Script error: $($Error[0])" -Action $action
	Complete-Run -Result "failed"
	Exit 1
}